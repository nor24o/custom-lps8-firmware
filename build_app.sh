#!/usr/bin/env bash
# ==============================================================================
# build_app.sh — Compile SX1276 Applications for Dragino LG01 / LG02
# Architecture: MIPS 24Kc (Atheros AR9331) / musl
# Apps: lg01_pkt_fwd, lg02_pkt_fwd, lg02_single_rx_tx, simple_spi_rw
# ==============================================================================
set -e

GREEN='\033[0;32m'
BLUE='\033[0;34m'
RED='\033[0;31m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_DIR="$SCRIPT_DIR/src"
OVERLAY_BIN="$SCRIPT_DIR/files/usr/bin"

# 1. Locate toolchain
CANDIDATE_TC=(
    "$TOOLCHAIN"
    "/home/hor/openwrt/openwrt/staging_dir/toolchain-mips_24kc_gcc-7.5.0_musl/bin"
    "$HOME/openwrt/openwrt/staging_dir/toolchain-mips_24kc_gcc-7.5.0_musl/bin"
)

TC_BIN=""
for c in "${CANDIDATE_TC[@]}"; do
    if [ -n "$c" ] && [ -x "$c/mips-openwrt-linux-musl-gcc" ]; then
        TC_BIN="$c"
        break
    fi
done

if [ -z "$TC_BIN" ]; then
    echo -e "${RED}[ERROR] OpenWrt MIPS toolchain not found! Run scripts/setup_env.sh first.${NC}"
    exit 1
fi

CANDIDATE_STAGING=(
    "/home/hor/openwrt/openwrt/staging_dir/target-mips_24kc_musl"
    "$HOME/openwrt/openwrt/staging_dir/target-mips_24kc_musl"
)
TARGET_STAGING=""
for s in "${CANDIDATE_STAGING[@]}"; do
    if [ -d "$s/usr/include" ]; then
        TARGET_STAGING="$s"
        break
    fi
done

export PATH="$TC_BIN:$PATH"
export CROSS_COMPILE=mips-openwrt-linux-musl-
export STAGING_DIR="$(dirname "$TC_BIN")"
export CC="${CROSS_COMPILE}gcc"
export CFLAGS="-O2 -Wall -fPIC -I$TARGET_STAGING/usr/include"
export LDFLAGS="-L$TARGET_STAGING/usr/lib"

echo -e "${BLUE}==> Building SX1276 Applications (LG01 / LG02)...${NC}"
cd "$SRC_DIR"
make clean
make all

mkdir -p "$OVERLAY_BIN"
cp lg01_pkt_fwd "$OVERLAY_BIN/lg01_pkt_fwd"
cp lg02_pkt_fwd "$OVERLAY_BIN/lg02_pkt_fwd"
cp lg02_pkt_fwd "$OVERLAY_BIN/sx1276_app"
cp lg02_single_rx_tx "$OVERLAY_BIN/lg02_single_rx_tx"
cp simple_spi_rw "$OVERLAY_BIN/simple_spi_rw"
chmod 755 "$OVERLAY_BIN"/*

echo -e "${GREEN}[+] Successfully built and staged SX1276 binaries to $OVERLAY_BIN${NC}"
