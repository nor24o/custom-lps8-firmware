#!/bin/bash
# ==============================================================================
# Bobcat Miner 300 (G285 / RK3566) Appliance Installer & Conversion Script
# ==============================================================================
# This script converts a fresh Armbian / Debian installation on a Bobcat Miner 300
# into a production-grade LoRaWAN / Raw LoRa Gateway Appliance featuring:
#   - Semtech SX1302 Concentrator HAL (EU868 8-channel, 27 dBm TX power)
#   - Front RGB LED Industrial State Machine (Green Heartbeat, Blue TX, Red RX)
#   - Multi-scheme Payload Decoder (AA0B, AA0C, Cayenne LPP, ASCII)
#   - Dual-database Ingestion (Persistent Flash + Rolling 50-packet RAM buffer)
#   - Home Assistant MQTT Auto-Discovery & Bidirectional Downlink Bridge
#   - Direct Edge Automations Engine ("What is linked to what and how")
#   - Dark Cyberpunk Web Management Interface (Port 80)
# ==============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Colors
C_RESET='\033[0m'
C_CYAN='\033[1;36m'
C_GREEN='\033[1;32m'
C_YELLOW='\033[1;33m'
C_RED='\033[1;31m'

echo -e "${C_CYAN}"
echo "======================================================================"
echo "    Bobcat Miner 300 (G285 / RK3566) LoRa Gateway Installation        "
echo "======================================================================"
echo -e "${C_RESET}"

# 1. Root Check
if [ "$(id -u)" -ne 0 ]; then
    echo -e "${C_RED}[!] Error: This script must be run as root (use sudo ./install.sh)${C_RESET}" >&2
    exit 1
fi

# 2. Kernel & Bootloader Lock
echo -e "${C_YELLOW}[1/8] Locking kernel and bootloader packages to prevent unintended upgrades...${C_RESET}"
apt-mark hold linux-image-* linux-dtb-* linux-u-boot-* armbian-firmware 2>/dev/null || true

# 3. System Dependencies
echo -e "${C_YELLOW}[2/8] Installing build dependencies and runtime packages...${C_RESET}"
apt-get update -y
apt-get install -y --no-install-recommends \
    build-essential \
    gcc \
    make \
    libc6-dev \
    python3 \
    python3-pip \
    python3-flask \
    python3-paho-mqtt \
    sqlite3 \
    curl \
    jq \
    net-tools \
    avahi-daemon \
    libnss-mdns

# 4. Compile SX1302 HAL & raw_lora_app
echo -e "${C_YELLOW}[3/8] Building SX1302 HAL, chip_id utility and raw_lora_app natively...${C_RESET}"
cd "${SCRIPT_DIR}/sx1302_hal"
make clean
make -j"$(nproc)"
make raw_lora_app
cd "${SCRIPT_DIR}"

# 5. Install Binaries & System Tools
echo -e "${C_YELLOW}[4/8] Installing binaries and utilities to /usr/local/bin/...${C_RESET}"
install -m 755 "${SCRIPT_DIR}/sx1302_hal/raw_lora_app" /usr/local/bin/raw_lora_app
install -m 755 "${SCRIPT_DIR}/sx1302_hal/util_chip_id/chip_id" /usr/local/bin/chip_id
install -m 755 "${SCRIPT_DIR}/bridge/bobcat_lora_bridge.py" /usr/local/bin/bobcat_lora_bridge.py
install -m 755 "${SCRIPT_DIR}/bin/reset_lgw.sh" /usr/local/bin/reset_lgw.sh
install -m 755 "${SCRIPT_DIR}/bin/lora_db_init.sh" /usr/local/bin/lora_db_init.sh
install -m 755 "${SCRIPT_DIR}/bin/test-leds" /usr/local/bin/test-leds
install -m 755 "${SCRIPT_DIR}/bin/test-lora" /usr/local/bin/test-lora
install -m 755 "${SCRIPT_DIR}/bin/query-lora-status" /usr/local/bin/query-lora-status
install -m 755 "${SCRIPT_DIR}/bin/send-lora-packet" /usr/local/bin/send-lora-packet

# 6. Install Configuration & Initialize Databases
echo -e "${C_YELLOW}[5/8] Configuring LoRa subsystem and databases (/etc/lora/)...${C_RESET}"
mkdir -p /etc/lora
if [ ! -f /etc/lora/config.json ]; then
    install -m 644 "${SCRIPT_DIR}/etc/lora/config.json" /etc/lora/config.json
else
    echo "       /etc/lora/config.json already exists; preserving existing configuration."
fi

if [ ! -f /etc/lora/decoders.json ]; then
    install -m 644 "${SCRIPT_DIR}/etc/lora/decoders.json" /etc/lora/decoders.json
else
    echo "       /etc/lora/decoders.json already exists; preserving existing decoders."
fi

/usr/local/bin/lora_db_init.sh

# 7. Install Web Management Application
echo -e "${C_YELLOW}[6/8] Installing Dark Cyberpunk Web Interface to /opt/bobcat-web/...${C_RESET}"
mkdir -p /opt/bobcat-web/templates /opt/bobcat-web/static
install -m 644 "${SCRIPT_DIR}/web/app.py" /opt/bobcat-web/app.py
install -m 644 "${SCRIPT_DIR}/web/templates/index.html" /opt/bobcat-web/templates/index.html
install -m 644 "${SCRIPT_DIR}/web/static/lora_decoder.js" /opt/bobcat-web/static/lora_decoder.js

# 8. Install & Enable Systemd Services
echo -e "${C_YELLOW}[7/8] Installing and starting systemd services...${C_RESET}"
install -m 644 "${SCRIPT_DIR}/systemd/raw-lora.service" /etc/systemd/system/raw-lora.service
install -m 644 "${SCRIPT_DIR}/systemd/bobcat-lora-bridge.service" /etc/systemd/system/bobcat-lora-bridge.service
install -m 644 "${SCRIPT_DIR}/systemd/bobcat-web.service" /etc/systemd/system/bobcat-web.service

systemctl daemon-reload
systemctl enable raw-lora.service bobcat-lora-bridge.service bobcat-web.service avahi-daemon.service
systemctl restart raw-lora.service bobcat-lora-bridge.service bobcat-web.service avahi-daemon.service

# 9. Hardware Verification
echo -e "${C_YELLOW}[8/8] Verifying LoRa hardware and front RGB LEDs...${C_RESET}"
/usr/local/bin/reset_lgw.sh start || true

IP_ADDR=$(hostname -I | awk '{print $1}')

echo ""
echo -e "${C_GREEN}======================================================================${C_RESET}"
echo -e "${C_GREEN}    SUCCESS: Bobcat Miner 300 Appliance Installation Complete!        ${C_RESET}"
echo -e "${C_GREEN}======================================================================${C_RESET}"
echo -e "Web Management UI:    ${C_CYAN}http://${IP_ADDR}/${C_RESET}"
echo -e "SX1302 Concentrator:  ${C_CYAN}Active (SPI /dev/spidev5.0, 27 dBm TX, EU868)${C_RESET}"
echo -e "RGB Status LED:       ${C_CYAN}Active (Green Heartbeat=OK, Blue=TX, Red=RX)${C_RESET}"
echo -e "HA / MQTT Ingestion:  ${C_CYAN}Active (Listening on UDP :5555, Downlink :5556)${C_RESET}"
echo ""
echo "Useful CLI Commands:"
echo "  test-lora          - Query SX1302 SPI bus and concentrator chip ID"
echo "  test-leds          - Cycle physical RGB LEDs across all colors"
echo "  query-lora-status  - Query live statistics from raw_lora_app (port 5557)"
echo "  send-lora-packet   - Queue a test LoRa downlink packet (port 5556)"
echo "======================================================================"
