#!/usr/bin/env bash
# ==============================================================================
# build.sh — Unified Build Dispatcher for Custom Dragino Firmware & Apps
# Supports:
#   - sx1302: Dragino LPS8 (8-channel SX1302 Multi-SF Gateway)
#   - lg01 / lg02: Dragino LG01 (Single) / LG02 (Dual Channel SX1276 Gateway)
# ==============================================================================
set -e

GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BOLD='\033[1m'
NC='\033[0m'

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGETS_DIR="$ROOT_DIR/targets"

usage() {
    echo -e "${BOLD}Usage:${NC} $0 [command] [target]"
    echo ""
    echo -e "${BOLD}Targets:${NC}"
    echo "  sx1302       Dragino LPS8 (SX1302 8-channel Concentrator)"
    echo "  lg01 / lg02  Dragino LG01 (Single-channel) / LG02 (Dual-channel SX1276)"
    echo "  all          Build both targets sequentially"
    echo ""
    echo -e "${BOLD}Commands:${NC}"
    echo "  all (default)  Compile applications, stage overlay, and build OpenWrt image"
    echo "  app            Compile only the applications"
    echo "  image          Build only the OpenWrt firmware image"
    echo "  clean          Clean build directories and compiled binaries"
    echo ""
    echo -e "${BOLD}Examples:${NC}"
    echo "  $0 sx1302              # Build entire LPS8 firmware & apps"
    echo "  $0 lg02                # Build entire LG01/LG02 firmware & apps"
    echo "  $0 all                 # Build both targets"
    echo "  $0 app sx1302          # Compile only LPS8 raw_lora_app"
    echo "  $0 image lg02          # Build only LG02 firmware image"
    echo ""
}

build_sx1302() {
    local mode="${1:-all}"
    echo -e "\n${BLUE}==================================================================${NC}"
    echo -e "${BLUE}  Target: Dragino LPS8 (SX1302 Concentrator)                      ${NC}"
    echo -e "${BLUE}==================================================================${NC}"
    local tdir="$TARGETS_DIR/sx1302"
    if [ ! -d "$tdir" ]; then
        # Check if we are inside the dedicated branch
        tdir="$ROOT_DIR"
    fi

    case "$mode" in
        app)   "$tdir/build_app.sh" ;;
        image) "$tdir/build_image.sh" ;;
        all)   "$tdir/build_all.sh" ;;
    esac
}

build_lg() {
    local mode="${1:-all}"
    echo -e "\n${BLUE}==================================================================${NC}"
    echo -e "${BLUE}  Target: Dragino LG01 / LG02 (SX1276 Transceivers)               ${NC}"
    echo -e "${BLUE}==================================================================${NC}"
    local tdir="$TARGETS_DIR/sx1276_lg01_lg02"
    if [ ! -d "$tdir" ]; then
        # Check if we are inside the dedicated branch
        tdir="$ROOT_DIR"
    fi

    case "$mode" in
        app)   "$tdir/build_app.sh" ;;
        image) "$tdir/build_image.sh" ;;
        all)   "$tdir/build_all.sh" ;;
    esac
}

clean_all() {
    echo -e "${YELLOW}[*] Cleaning build artifacts...${NC}"
    rm -rf "$ROOT_DIR/bin" "$ROOT_DIR/tmp" "$ROOT_DIR/build_dir"
    echo -e "${GREEN}[+] Clean complete.${NC}"
}

# Parse Arguments
ACTION="all"
TARGET=""

if [ $# -eq 0 ]; then
    echo -e "${BLUE}==================================================================${NC}"
    echo -e "${BLUE}  Custom Dragino Firmware & Apps Builder                          ${NC}"
    echo -e "${BLUE}==================================================================${NC}"
    echo "Select target to build:"
    echo "  1) Dragino LPS8 (SX1302 8-channel Gateway)"
    echo "  2) Dragino LG01 / LG02 (SX1276 Single / Dual Gateway)"
    echo "  3) Both Targets (LPS8 & LG01/LG02)"
    echo "  4) Exit"
    echo ""
    read -p "Enter choice [1-4]: " choice
    case "$choice" in
        1) TARGET="sx1302" ;;
        2) TARGET="lg02" ;;
        3) TARGET="all" ;;
        *) exit 0 ;;
    esac
elif [ $# -eq 1 ]; then
    case "$1" in
        sx1302|lps8)       TARGET="sx1302"; ACTION="all" ;;
        lg01|lg02|sx1276)  TARGET="lg02";   ACTION="all" ;;
        all)               TARGET="all";    ACTION="all" ;;
        clean)             clean_all; exit 0 ;;
        -h|--help)         usage; exit 0 ;;
        *)                 echo -e "${RED}[ERROR] Unknown target or command '$1'${NC}"; usage; exit 1 ;;
    esac
elif [ $# -ge 2 ]; then
    ACTION="$1"
    TARGET="$2"
fi

case "$TARGET" in
    sx1302|lps8)
        build_sx1302 "$ACTION"
        ;;
    lg01|lg02|sx1276)
        build_lg "$ACTION"
        ;;
    all)
        build_sx1302 "$ACTION"
        build_lg "$ACTION"
        ;;
    *)
        echo -e "${RED}[ERROR] Invalid target '$TARGET'${NC}"
        usage
        exit 1
        ;;
esac
