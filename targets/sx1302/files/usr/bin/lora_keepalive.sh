#!/bin/sh
# /usr/bin/lora_keepalive.sh
# Keepalive for raw_lora_app. This gateway is a satellite of the LoRaHub server.

LOGFILE="/var/log/lora.log"
STOP_FLAG="/tmp/lora_manual_stop"
mkdir -p /var/log /etc/lora
touch "$LOGFILE"

fail_tcp_cnt=0

while true; do
    if [ -f "$STOP_FLAG" ]; then
        sleep 3
        continue
    fi

    # Keep log file bounded to last 300 lines so tmpfs never fills up
    if [ -f "$LOGFILE" ] && [ "$(wc -l < "$LOGFILE" 2>/dev/null || echo 0)" -gt 400 ]; then
        tail -n 250 "$LOGFILE" > "${LOGFILE}.tmp" && mv "${LOGFILE}.tmp" "$LOGFILE"
    fi

    PID=$(pidof raw_lora_app 2>/dev/null | awk '{print $1}')

    if [ -z "$PID" ]; then
        ts=$(date '+%Y-%m-%d %H:%M:%S')
        echo "[$ts] [KEEPALIVE] LoRa daemon not running — auto-restarting..." >> "$LOGFILE"
        logger -t lora_keepalive "LoRa daemon not running — auto-restarting"

        if [ ! -e /dev/spidev1.0 ] && [ -x /etc/init.d/spi_init ]; then
            /etc/init.d/spi_init start >/dev/null 2>&1
        fi

        if [ -x /usr/bin/raw_lora_app ]; then
            /usr/bin/raw_lora_app >> "$LOGFILE" 2>&1 &
        fi
        fail_tcp_cnt=0
        sleep 5
        continue
    fi

    # Verify TCP status server responsiveness on port 5557 (detect hung/deadlocked process)
    if pidof raw_lora_app >/dev/null 2>&1; then
        resp=$(nc 127.0.0.1 5557 2>/dev/null)
        if [ -z "$resp" ]; then
            fail_tcp_cnt=$((fail_tcp_cnt + 1))
            if [ $fail_tcp_cnt -ge 3 ]; then
                ts=$(date '+%Y-%m-%d %H:%M:%S')
                echo "[$ts] [KEEPALIVE] raw_lora_app (PID $PID) unresponsive on TCP 5557 (3x) — force-restarting..." >> "$LOGFILE"
                logger -t lora_keepalive "raw_lora_app unresponsive on TCP 5557 — force-restarting"
                kill -9 "$PID" 2>/dev/null
                fail_tcp_cnt=0
            fi
        else
            fail_tcp_cnt=0
        fi
    fi

    sleep 5
done
