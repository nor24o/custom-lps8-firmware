#!/usr/bin/env bash
# ==============================================================================
# upload_firmware.sh — Direct Device Uploader & Flasher for Dragino Gateways
# Supports: Dragino LG01 / LG02 (SX1276) & Dragino LPS8 (SX1302)
#
# Usage:
#   ./upload_firmware.sh [OPTIONS] [DEVICE_IP]
#
# Examples:
#   ./upload_firmware.sh                    # Auto-detect device and flash latest build
#   ./upload_firmware.sh 192.168.1.29       # Flash to specific IP
#   ./upload_firmware.sh --build            # Rebuild firmware before flashing
#   ./upload_firmware.sh --keep-config      # Flash while keeping existing configs
#   ./upload_firmware.sh --live-sync        # Fast live-sync apps & UI without reboot
#   ./upload_firmware.sh --test-only        # Upload & verify image on device without flashing
# ==============================================================================
set -e

GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_PASS="root"
DEFAULT_USER="root"

# Default candidate IPs to probe if no IP provided
CANDIDATE_IPS=("192.168.1.15" "192.168.1.29" "192.168.1.1" "192.168.2.1")

usage() {
    echo -e "${BOLD}Usage:${NC} $0 [OPTIONS] [DEVICE_IP]"
    echo ""
    echo -e "${BOLD}Options:${NC}"
    echo "  -i, --ip <IP>          Target device IP address (auto-detected if omitted)"
    echo "  -p, --password <PASS>  Root password for device (default: 'root')"
    echo "  -f, --file <PATH>      Path to .bin sysupgrade firmware image"
    echo "  -t, --target <TARGET>  Target model: 'lg02' (default) or 'sx1302'"
    echo "  -b, --build            Rebuild firmware with ./build.sh before flashing"
    echo "  -k, --keep-config      Preserve existing /etc/ configs (sysupgrade -c)"
    echo "  -n, --clean            Clean reflash, reset configuration (sysupgrade -n, default)"
    echo "  -y, --yes              Non-interactive mode (skip confirmation prompts)"
    echo "  --test-only            Verify image on device (sysupgrade -T) without writing to flash"
    echo "  --live-sync            Fast update of applications, decoders, and LuCI web UI (no reboot)"
    echo "  -h, --help             Show this help message"
    echo ""
    echo -e "${BOLD}Examples:${NC}"
    echo "  $0                                   # Auto-detect gateway and flash"
    echo "  $0 192.168.1.29                      # Flash to 192.168.1.29"
    echo "  $0 --build lg02 192.168.1.29         # Rebuild LG02 image and flash"
    echo "  $0 --keep-config 192.168.1.29        # Upgrade while preserving settings"
    echo "  $0 --live-sync 192.168.1.29          # Fast live-sync apps & decoder UI"
    echo ""
}

# Defaults
DEVICE_IP=""
PASS="$DEFAULT_PASS"
USER="$DEFAULT_USER"
FW_FILE=""
TARGET="lg02"
DO_BUILD=false
KEEP_CONFIG=false
FORCE_YES=false
TEST_ONLY=false
LIVE_SYNC=false

# Parse arguments
while [ $# -gt 0 ]; do
    case "$1" in
        -i|--ip)
            DEVICE_IP="$2"
            shift 2
            ;;
        -p|--password)
            PASS="$2"
            shift 2
            ;;
        -f|--file)
            FW_FILE="$2"
            shift 2
            ;;
        -t|--target)
            TARGET="$2"
            shift 2
            ;;
        -b|--build)
            DO_BUILD=true
            shift
            ;;
        -k|--keep-config)
            KEEP_CONFIG=true
            shift
            ;;
        -n|--clean)
            KEEP_CONFIG=false
            shift
            ;;
        -y|--yes)
            FORCE_YES=true
            shift
            ;;
        --test-only)
            TEST_ONLY=true
            shift
            ;;
        --live-sync|--app|--dev)
            LIVE_SYNC=true
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            if [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
                DEVICE_IP="$1"
            elif [ "$1" == "lg01" ] || [ "$1" == "lg02" ] || [ "$1" == "sx1276" ] || [ "$1" == "sx1302" ] || [ "$1" == "lps8" ]; then
                TARGET="$1"
            elif [ -f "$1" ] && [[ "$1" == *.bin ]]; then
                FW_FILE="$1"
            else
                echo -e "${RED}[ERROR] Unknown option or argument: $1${NC}"
                usage
                exit 1
            fi
            shift
            ;;
    esac
done

echo -e "${BLUE}==================================================================${NC}"
echo -e "${BLUE}  Dragino Firmware Uploader & Flasher                             ${NC}"
echo -e "${BLUE}==================================================================${NC}"

# Check sshpass tool
if ! command -v sshpass >/dev/null 2>&1; then
    echo -e "${YELLOW}[!] Warning: 'sshpass' not installed. Installing...${NC}"
    if command -v apt-get >/dev/null 2>&1; then
        sudo apt-get update && sudo apt-get install -y sshpass
    else
        echo -e "${RED}[ERROR] Please install 'sshpass' manually: sudo apt install sshpass${NC}"
        exit 1
    fi
fi

# 1. Rebuild if requested
if [ "$DO_BUILD" = true ]; then
    echo -e "\n${BLUE}[*] Building fresh firmware image for target '$TARGET'...${NC}"
    "$ROOT_DIR/build.sh" "$TARGET"
fi

# 2. Fast Live-Sync Mode (if requested)
if [ "$LIVE_SYNC" = true ]; then
    echo -e "\n${CYAN}[*] Mode: Fast Live-Sync (Applications, Decoders & LuCI Web UI)${NC}"
fi

# 3. Discover / Verify Device IP
if [ -z "$DEVICE_IP" ]; then
    echo -e "\n${BLUE}[*] Auto-detecting Dragino gateway on local network...${NC}"

    # Try ARP table lookup for Dragino OUI: A8:40:41
    if command -v arp >/dev/null 2>&1; then
        ARP_MATCH=$(arp -a 2>/dev/null | grep -i "a8[-:]40[-:]41" | awk '{print $1}' | tr -d '()' | head -n 1 || true)
        if [ -n "$ARP_MATCH" ] && [[ "$ARP_MATCH" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            CANDIDATE_IPS=("$ARP_MATCH" "${CANDIDATE_IPS[@]}")
        fi
    fi

    for ip in "${CANDIDATE_IPS[@]}"; do
        echo -e "    Checking: ${CYAN}$ip${NC}..."
        if sshpass -p "$PASS" ssh -n -o StrictHostKeyChecking=no -o ConnectTimeout=2 "$USER@$ip" "test -f /etc/openwrt_release" 2>/dev/null; then
            DEVICE_IP="$ip"
            echo -e "${GREEN}[+] Successfully connected to Dragino device at: $DEVICE_IP${NC}"
            break
        fi
    done

    if [ -z "$DEVICE_IP" ]; then
        echo -e "${RED}[ERROR] Could not auto-detect Dragino gateway.${NC}"
        echo -e "Please specify device IP explicitly: ${YELLOW}$0 <DEVICE_IP>${NC}"
        exit 1
    fi
else
    echo -e "\n${BLUE}[*] Verifying connection to $USER@$DEVICE_IP...${NC}"
    if ! sshpass -p "$PASS" ssh -n -o StrictHostKeyChecking=no -o ConnectTimeout=3 "$USER@$DEVICE_IP" "test -f /etc/openwrt_release" 2>/dev/null; then
        echo -e "${RED}[ERROR] Cannot connect to $USER@$DEVICE_IP over SSH (port 22).${NC}"
        echo -e "Check that:"
        echo -e "  1. The gateway is powered on and connected to your network."
        echo -e "  2. The IP address ($DEVICE_IP) and password ('$PASS') are correct."
        echo -e "  3. Your host can reach the gateway subnet."
        exit 1
    fi
    echo -e "${GREEN}[+] Connection verified.${NC}"
fi

# Query Device Information
DEVICE_BOARD=$(sshpass -p "$PASS" ssh -n -o StrictHostKeyChecking=no "$USER@$DEVICE_IP" "cat /tmp/sysinfo/board_name 2>/dev/null || uname -m")
DEVICE_UPTIME=$(sshpass -p "$PASS" ssh -n -o StrictHostKeyChecking=no "$USER@$DEVICE_IP" "uptime | awk -F', ' '{print \$1}' | sed 's/^[ \t]*//'")
DEVICE_TMP_AVAIL=$(sshpass -p "$PASS" ssh -n -o StrictHostKeyChecking=no "$USER@$DEVICE_IP" "df -m /tmp | tail -n 1 | awk '{print \$4}'")

echo -e "    Device Model:  ${BOLD}$DEVICE_BOARD${NC}"
echo -e "    Device Uptime: $DEVICE_UPTIME"
echo -e "    RAM in /tmp:   ${DEVICE_TMP_AVAIL} MB free"

# ------------------------------------------------------------------------------
# BRANCH A: Live Sync Mode (Update apps, decoders, views without reboot)
# ------------------------------------------------------------------------------
if [ "$LIVE_SYNC" = true ]; then
    echo -e "\n${BLUE}==================================================================${NC}"
    echo -e "${BLUE}  Deploying Live Updates to $DEVICE_IP                            ${NC}"
    echo -e "${BLUE}==================================================================${NC}"

    TARGET_FILES="$ROOT_DIR/targets/sx1276_lg01_lg02/files"
    if [ "$TARGET" == "sx1302" ] || [ "$TARGET" == "lps8" ]; then
        TARGET_FILES="$ROOT_DIR/targets/sx1302/files"
    fi

    # Ensure target directories exist on device
    sshpass -p "$PASS" ssh -n -o StrictHostKeyChecking=no "$USER@$DEVICE_IP" "mkdir -p /usr/bin /etc/lora /www/luci-static/resources /usr/lib/lua/luci/controller /usr/lib/lua/luci/view/lora"

    # 1. Deploy binaries
    if [ -f "$TARGET_FILES/usr/bin/lg02_pkt_fwd" ]; then
        echo -e "${BLUE}[*] Uploading lg02_pkt_fwd binary...${NC}"
        sshpass -p "$PASS" scp -o StrictHostKeyChecking=no "$TARGET_FILES/usr/bin/lg02_pkt_fwd" "$USER@$DEVICE_IP:/tmp/lg02_pkt_fwd"
        sshpass -p "$PASS" ssh -n -o StrictHostKeyChecking=no "$USER@$DEVICE_IP" "mv -f /tmp/lg02_pkt_fwd /usr/bin/lg02_pkt_fwd && chmod 755 /usr/bin/lg02_pkt_fwd"
    fi
    if [ -f "$TARGET_FILES/usr/bin/raw_lora_app" ]; then
        echo -e "${BLUE}[*] Uploading raw_lora_app binary...${NC}"
        sshpass -p "$PASS" scp -o StrictHostKeyChecking=no "$TARGET_FILES/usr/bin/raw_lora_app" "$USER@$DEVICE_IP:/tmp/raw_lora_app"
        sshpass -p "$PASS" ssh -n -o StrictHostKeyChecking=no "$USER@$DEVICE_IP" "mv -f /tmp/raw_lora_app /usr/bin/raw_lora_app && chmod 755 /usr/bin/raw_lora_app"
    fi

    # 2. Deploy decoders engine & default schemes
    if [ -f "$TARGET_FILES/www/luci-static/resources/lora_decoder.js" ]; then
        echo -e "${BLUE}[*] Uploading lora_decoder.js engine...${NC}"
        sshpass -p "$PASS" ssh -n -o StrictHostKeyChecking=no "$USER@$DEVICE_IP" "mkdir -p /www/luci-static/resources"
        sshpass -p "$PASS" scp -o StrictHostKeyChecking=no "$TARGET_FILES/www/luci-static/resources/lora_decoder.js" "$USER@$DEVICE_IP:/www/luci-static/resources/lora_decoder.js"
    fi
    if [ -f "$TARGET_FILES/etc/lora/decoders.json" ]; then
        echo -e "${BLUE}[*] Syncing /etc/lora/decoders.json (if not existing on device)...${NC}"
        sshpass -p "$PASS" ssh -n -o StrictHostKeyChecking=no "$USER@$DEVICE_IP" "mkdir -p /etc/lora && [ ! -f /etc/lora/decoders.json ] && true || true"
        sshpass -p "$PASS" scp -o StrictHostKeyChecking=no "$TARGET_FILES/etc/lora/decoders.json" "$USER@$DEVICE_IP:/tmp/decoders_def.json"
        sshpass -p "$PASS" ssh -n -o StrictHostKeyChecking=no "$USER@$DEVICE_IP" "[ ! -f /etc/lora/decoders.json ] && cp /tmp/decoders_def.json /etc/lora/decoders.json || true; rm -f /tmp/decoders_def.json"
    fi

    # 2.1 Deploy SQLite & Automation Daemons
    for s in lora_db_init.sh lora_keepalive.sh lora_linking_engine.lua lora_mqtt_bridge.lua lora_sync_config.sh; do
        if [ -f "$TARGET_FILES/usr/bin/$s" ]; then
            echo -e "${BLUE}[*] Uploading /usr/bin/$s...${NC}"
            sshpass -p "$PASS" scp -o StrictHostKeyChecking=no "$TARGET_FILES/usr/bin/$s" "$USER@$DEVICE_IP:/usr/bin/$s"
            sshpass -p "$PASS" ssh -n -o StrictHostKeyChecking=no "$USER@$DEVICE_IP" "chmod 755 /usr/bin/$s"
        fi
    done

    # 3. Deploy LuCI views & controllers
    echo -e "${BLUE}[*] Uploading LuCI controllers and views...${NC}"
    sshpass -p "$PASS" scp -o StrictHostKeyChecking=no "$TARGET_FILES/usr/lib/lua/luci/controller/lora.lua" "$USER@$DEVICE_IP:/usr/lib/lua/luci/controller/lora.lua"
    for v in status.htm decoder.htm nodes.htm diag.htm config.htm; do
        if [ -f "$TARGET_FILES/usr/lib/lua/luci/view/lora/$v" ]; then
            sshpass -p "$PASS" scp -o StrictHostKeyChecking=no "$TARGET_FILES/usr/lib/lua/luci/view/lora/$v" "$USER@$DEVICE_IP:/usr/lib/lua/luci/view/lora/$v"
        fi
    done

    # 4. Clear cache and restart services
    echo -e "${BLUE}[*] Refreshing LuCI cache and restarting web server...${NC}"
    sshpass -p "$PASS" ssh -n -o StrictHostKeyChecking=no "$USER@$DEVICE_IP" "
        rm -rf /tmp/luci-indexcache* /tmp/luci-modulecache*
        /etc/init.d/uhttpd restart
        /etc/init.d/lora_gateway restart 2>/dev/null || true
    "

    echo -e "\n${GREEN}==================================================================${NC}"
    echo -e "${GREEN}[+] LIVE SYNC COMPLETE!${NC}"
    echo -e "    Realtime Status:   ${CYAN}http://$DEVICE_IP/cgi-bin/luci/admin/lora/status${NC}"
    echo -e "    Payload Decoders:  ${CYAN}http://$DEVICE_IP/cgi-bin/luci/admin/lora/decoder${NC}"
    echo -e "${GREEN}==================================================================${NC}"
    exit 0
fi

# ------------------------------------------------------------------------------
# BRANCH B: Full Sysupgrade Firmware Flashing Mode
# ------------------------------------------------------------------------------

# Locate firmware binary
if [ -z "$FW_FILE" ]; then
    CANDIDATE_BINS=(
        "$ROOT_DIR/bin/targets/ar71xx/generic/openwrt-18.06.9-ar71xx-generic-dragino2-squashfs-sysupgrade.bin"
        "$ROOT_DIR/targets/sx1276_lg01_lg02/bin/openwrt-18.06.9-ar71xx-generic-dragino2-squashfs-sysupgrade.bin"
        "$ROOT_DIR/targets/sx1302/bin/openwrt-18.06.9-ar71xx-generic-dragino2-squashfs-sysupgrade.bin"
    )
    for b in "${CANDIDATE_BINS[@]}"; do
        if [ -s "$b" ]; then
            FW_FILE="$b"
            break
        fi
    done
fi

if [ -z "$FW_FILE" ] || [ ! -s "$FW_FILE" ]; then
    echo -e "\n${YELLOW}[!] No compiled sysupgrade firmware binary found.${NC}"
    echo -e "${BLUE}[*] Triggering automatic build now for target '$TARGET'...${NC}"
    "$ROOT_DIR/build.sh" "$TARGET"
    FW_FILE="$ROOT_DIR/bin/targets/ar71xx/generic/openwrt-18.06.9-ar71xx-generic-dragino2-squashfs-sysupgrade.bin"
fi

if [ ! -s "$FW_FILE" ]; then
    echo -e "${RED}[ERROR] Firmware image not found at: $FW_FILE${NC}"
    exit 1
fi

FW_SIZE_BYTES=$(wc -c < "$FW_FILE")
FW_SIZE_MB=$(du -h "$FW_FILE" | cut -f1)
FW_MD5=$(md5sum "$FW_FILE" | awk '{print $1}')

echo -e "\n${BLUE}[*] Firmware Image Details:${NC}"
echo -e "    File:     ${BOLD}$FW_FILE${NC}"
echo -e "    Size:     $FW_SIZE_MB ($FW_SIZE_BYTES bytes)"
echo -e "    Local MD5: ${CYAN}$FW_MD5${NC}"

# Check remote space in /tmp
FW_SIZE_REQ_MB=$(( (FW_SIZE_BYTES / 1048576) + 2 ))
if [ "$DEVICE_TMP_AVAIL" -lt "$FW_SIZE_REQ_MB" ]; then
    echo -e "${RED}[ERROR] Device /tmp has only ${DEVICE_TMP_AVAIL}MB free; need at least ${FW_SIZE_REQ_MB}MB.${NC}"
    exit 1
fi

# Confirmation prompt
MODE_STR="Clean flash (reset overlay settings)"
SYSUPGRADE_OPTS="-v -n"
if [ "$KEEP_CONFIG" = true ]; then
    MODE_STR="Preserve configuration files in /etc/"
    SYSUPGRADE_OPTS="-v -c"
fi

if [ "$FORCE_YES" != true ] && [ "$TEST_ONLY" != true ]; then
    echo -e "\n${YELLOW}------------------------------------------------------------------${NC}"
    echo -e "${BOLD}Ready to flash Dragino gateway:${NC}"
    echo -e "  Target Device:  ${BOLD}$USER@$DEVICE_IP${NC} ($DEVICE_BOARD)"
    echo -e "  Firmware File:  $FW_FILE ($FW_SIZE_MB)"
    echo -e "  Flash Mode:     $MODE_STR"
    echo -e "${YELLOW}------------------------------------------------------------------${NC}"
    read -p "Proceed with uploading and flashing? [y/N]: " confirm
    case "$confirm" in
        [yY]|[yY][eE][sS]) ;;
        *)
            echo -e "${YELLOW}[*] Flashing cancelled by user.${NC}"
            exit 0
            ;;
    esac
fi

# 4. Upload Firmware Image
echo -e "\n${BLUE}[1/4] Uploading firmware image to $USER@$DEVICE_IP:/tmp/sysupgrade.bin...${NC}"
sshpass -p "$PASS" scp -o StrictHostKeyChecking=no "$FW_FILE" "$USER@$DEVICE_IP:/tmp/sysupgrade.bin"
echo -e "${GREEN}[+] Upload complete.${NC}"

# 5. Remote Checksum Verification
echo -e "\n${BLUE}[2/4] Verifying remote checksum on device...${NC}"
REMOTE_MD5=$(sshpass -p "$PASS" ssh -n -o StrictHostKeyChecking=no "$USER@$DEVICE_IP" "md5sum /tmp/sysupgrade.bin" | awk '{print $1}')
echo -e "    Remote MD5: ${CYAN}$REMOTE_MD5${NC}"

if [ "$FW_MD5" != "$REMOTE_MD5" ]; then
    echo -e "${RED}[ERROR] Checksum mismatch! Local ($FW_MD5) != Remote ($REMOTE_MD5)${NC}"
    echo -e "Deleting corrupt file on device..."
    sshpass -p "$PASS" ssh -n -o StrictHostKeyChecking=no "$USER@$DEVICE_IP" "rm -f /tmp/sysupgrade.bin"
    exit 1
fi
echo -e "${GREEN}[+] MD5 verification successful! Image is 100% intact.${NC}"

# 6. Test Image Compatibility
echo -e "\n${BLUE}[3/4] Testing image compatibility with sysupgrade...${NC}"
if sshpass -p "$PASS" ssh -n -o StrictHostKeyChecking=no "$USER@$DEVICE_IP" "sysupgrade -T /tmp/sysupgrade.bin"; then
    echo -e "${GREEN}[+] sysupgrade validation PASSED.${NC}"
else
    echo -e "${RED}[ERROR] sysupgrade test check failed! Aborting flash.${NC}"
    sshpass -p "$PASS" ssh -n -o StrictHostKeyChecking=no "$USER@$DEVICE_IP" "rm -f /tmp/sysupgrade.bin"
    exit 1
fi

if [ "$TEST_ONLY" = true ]; then
    echo -e "\n${GREEN}[+] --test-only specified. Firmware validated successfully; no flash performed.${NC}"
    sshpass -p "$PASS" ssh -n -o StrictHostKeyChecking=no "$USER@$DEVICE_IP" "rm -f /tmp/sysupgrade.bin"
    exit 0
fi

# 7. Execute Flashing
echo -e "\n${BLUE}[4/4] Writing firmware to flash and rebooting ($MODE_STR)...${NC}"
echo -e "${YELLOW}[!] Note: SSH connection will terminate as device unmounts filesystems.${NC}"

# Execute sysupgrade
sshpass -p "$PASS" ssh -n -o StrictHostKeyChecking=no "$USER@$DEVICE_IP" "sysupgrade $SYSUPGRADE_OPTS /tmp/sysupgrade.bin" || true

echo -e "\n${GREEN}[+] Flashing process initiated.${NC}"
echo -e "${BLUE}[*] Waiting for device to write flash and reboot (typically 45-60s)...${NC}"

# Poll device reboot
sleep 15
MAX_WAIT=120
WAITED=15
ONLINE=false

while [ $WAITED -lt $MAX_WAIT ]; do
    if ping -c 1 -W 1 "$DEVICE_IP" >/dev/null 2>&1; then
        # Ping replied; check if SSH is responsive
        if sshpass -p "$PASS" ssh -n -o StrictHostKeyChecking=no -o ConnectTimeout=2 "$USER@$DEVICE_IP" "test -f /etc/openwrt_release" >/dev/null 2>&1; then
            ONLINE=true
            break
        fi
    elif [ $WAITED -ge 40 ]; then
        # Check if DHCP assigned another candidate IP
        for alt_ip in "${CANDIDATE_IPS[@]}"; do
            if [ "$alt_ip" != "$DEVICE_IP" ] && sshpass -p "$PASS" ssh -n -o StrictHostKeyChecking=no -o ConnectTimeout=1 "$USER@$alt_ip" "test -f /etc/openwrt_release" >/dev/null 2>&1; then
                DEVICE_IP="$alt_ip"
                ONLINE=true
                break 2
            fi
        done
    fi
    echo -ne "    Waiting for reboot... (${WAITED}s / ${MAX_WAIT}s)\r"
    sleep 3
    WAITED=$((WAITED + 3))
done
echo ""

if [ "$ONLINE" = true ]; then
    NEW_UPTIME=$(sshpass -p "$PASS" ssh -n -o StrictHostKeyChecking=no "$USER@$DEVICE_IP" "uptime | awk -F', ' '{print \$1}' | sed 's/^[ \t]*//'")
    echo -e "\n${GREEN}==================================================================${NC}"
    echo -e "${GREEN}[+] FIRMWARE FLASH SUCCESSFUL! Device is back online.${NC}"
    echo -e "    IP Address:      ${BOLD}$DEVICE_IP${NC}"
    echo -e "    Uptime:          $NEW_UPTIME"
    echo -e "    LuCI Web UI:     ${CYAN}http://$DEVICE_IP/${NC}"
    echo -e "    Realtime Status: ${CYAN}http://$DEVICE_IP/cgi-bin/luci/admin/lora/status${NC}"
    echo -e "    Payload Decoder: ${CYAN}http://$DEVICE_IP/cgi-bin/luci/admin/lora/decoder${NC}"
    echo -e "${GREEN}==================================================================${NC}"
else
    echo -e "\n${YELLOW}[!] Device did not answer SSH within ${MAX_WAIT}s.${NC}"
    echo -e "It may still be writing flash or formatting overlay, or DHCP assigned a new IP."
    echo -e "Check your router DHCP leases or ping $DEVICE_IP in a moment."
fi
