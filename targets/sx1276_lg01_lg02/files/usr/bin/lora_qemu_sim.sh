#!/bin/sh
# Simulated LoRa Concentrator Daemon for QEMU Emulation (when /dev/spidev1.0 is absent)

mkdir -p /tmp /var/iot
echo "online" > /var/iot/status

MODEL=$(uci -q get lora.general.concentrator || echo "sx1302")
SERVER=$(uci -q get lora.general.server_address || echo "eu1.cloud.thethings.network")
PORT_UP=$(uci -q get lora.general.serv_port_up || echo "1700")
GWID=$(uci -q get lora.general.gateway_id || echo "a84041ffff16c21c")

logger -t lora "Starting LoRa Gateway Forwarder ($MODEL) [QEMU Emulation Mode]"
logger -t lora "Gateway EUI: $GWID -> Upstream: $SERVER:$PORT_UP"
logger -t lora "SX1302/SX1276 virtual radio initialized (8x Multi-SF channels active)"

RX=1
TX=0
CRC=0

logger -t lora "[RX] 23 bytes | SF7BW125 | 868.1 | RSSI -64 | SNR 9.8 | CRC_OK"
cat <<EOF > /tmp/lora_stats.json
{"rx":1,"tx":0,"crc_err":0,"ack_ratio":"100%"}
EOF
echo "[]" > /tmp/lora_packets.json

while true; do
    sleep 3
    RX=$((RX + 1))

    case $((RX % 6)) in
        0) FREQ="868.1"; DATR="SF7BW125";  RSSI="-64"; SNR="9.8";  SZ=23; STAT="CRC_OK" ;;
        1) FREQ="868.3"; DATR="SF7BW125";  RSSI="-78"; SNR="7.2";  SZ=19; STAT="CRC_OK" ;;
        2) FREQ="868.5"; DATR="SF9BW125";  RSSI="-92"; SNR="2.5";  SZ=31; STAT="CRC_OK" ;;
        3) FREQ="867.1"; DATR="SF8BW125";  RSSI="-84"; SNR="5.0";  SZ=27; STAT="CRC_OK" ;;
        4) FREQ="867.5"; DATR="SF12BW125"; RSSI="-112"; SNR="-8.5"; SZ=16; STAT="CRC_BAD" ;;
        5) FREQ="867.9"; DATR="SF7BW125";  RSSI="-71"; SNR="8.4";  SZ=25; STAT="CRC_OK"; TX=$((TX + 1)) ;;
    esac

    if [ "$STAT" = "CRC_BAD" ]; then
        CRC=$((CRC + 1))
    fi

    logger -t lora "[RX] $SZ bytes | $DATR | $FREQ | RSSI $RSSI | SNR $SNR | $STAT"

    cat <<EOF > /tmp/lora_stats.json
{"rx":$RX,"tx":$TX,"crc_err":$CRC,"ack_ratio":"100%"}
EOF
done
