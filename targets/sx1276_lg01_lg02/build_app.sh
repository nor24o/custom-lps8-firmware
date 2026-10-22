#!/usr/bin/env bash
# ==============================================================================
# build_app.sh — Compile SX1276 Applications for Dragino LG01 / LG02
# Binaries built: lg01_pkt_fwd, lg02_pkt_fwd, simple_spi_rw
# Architecture: MIPS 24Kc (Atheros AR9331) / musl
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
CANDIDATES=(
    "$TOOLCHAIN"
    "/home/hor/openwrt/openwrt/staging_dir/toolchain-mips_24kc_gcc-7.5.0_musl/bin"
    "$HOME/openwrt/openwrt/staging_dir/toolchain-mips_24kc_gcc-7.5.0_musl/bin"
)

TC_BIN=""
for c in "${CANDIDATES[@]}"; do
    if [ -n "$c" ] && [ -x "$c/mips-openwrt-linux-musl-gcc" ]; then
        TC_BIN="$c"
        break
    fi
done

if [ -z "$TC_BIN" ]; then
    echo -e "${RED}[ERROR] OpenWrt MIPS toolchain not found! Run scripts/setup_env.sh first.${NC}"
    exit 1
fi

export PATH="$TC_BIN:$PATH"
export CROSS_COMPILE=mips-openwrt-linux-musl-
STAGING_BASE="$(cd "$TC_BIN/../.." && pwd)"
export STAGING_DIR="$STAGING_BASE"
TARGET_DIR="$STAGING_BASE/target-mips_24kc_musl"

CC="${CROSS_COMPILE}gcc"

echo -e "${BLUE}==> [1/3] Compiling lg02_pkt_fwd (Dual Channel Forwarder)...${NC}"
$CC -O2 -Wall \
    -I"$SRC_DIR" \
    -o "$SRC_DIR/lg02_pkt_fwd" \
    "$SRC_DIR/lg02_pkt_fwd.c" \
    "$SRC_DIR/radio.c" \
    "$SRC_DIR/parson.c" \
    "$SRC_DIR/base64.c" \
    -lrt -lpthread

echo -e "${BLUE}==> [2/3] Compiling lg01_pkt_fwd (Single Channel Forwarder)...${NC}"
$CC -O2 -Wall \
    -I"$SRC_DIR" \
    -I"$TARGET_DIR/usr/include" \
    -L"$TARGET_DIR/usr/lib" \
    -o "$SRC_DIR/lg01_pkt_fwd" \
    "$SRC_DIR/lg01_pkt_fwd.c" \
    "$SRC_DIR/radio.c" \
    "$SRC_DIR/parson.c" \
    "$SRC_DIR/base64.c" \
    "$SRC_DIR/jitqueue.c" \
    -luci -lubox -lrt -lpthread

echo -e "${BLUE}==> [3/3] Compiling simple_spi_rw (Hardware Probe Utility)...${NC}"
$CC -O2 -Wall \
    -I"$SRC_DIR" \
    -o "$SRC_DIR/simple_spi_rw" \
    "$SRC_DIR/simple_spi_rw.c" \
    "$SRC_DIR/radio.c" \
    -lrt

# Stage into overlay
mkdir -p "$OVERLAY_BIN"
cp "$SRC_DIR/lg02_pkt_fwd"  "$OVERLAY_BIN/lg02_pkt_fwd"
cp "$SRC_DIR/lg01_pkt_fwd"  "$OVERLAY_BIN/lg01_pkt_fwd"
cp "$SRC_DIR/simple_spi_rw" "$OVERLAY_BIN/simple_spi_rw"
chmod 755 "$OVERLAY_BIN/lg02_pkt_fwd" "$OVERLAY_BIN/lg01_pkt_fwd" "$OVERLAY_BIN/simple_spi_rw"

# Symlink sx1276_app -> lg02_pkt_fwd for web UI and init compatibility
ln -sf lg02_pkt_fwd "$OVERLAY_BIN/sx1276_app"

echo -e "${GREEN}[+] Successfully built and staged:${NC}"
echo -e "    - $OVERLAY_BIN/lg02_pkt_fwd"
echo -e "    - $OVERLAY_BIN/lg01_pkt_fwd"
echo -e "    - $OVERLAY_BIN/simple_spi_rw"
echo -e "    - $OVERLAY_BIN/sx1276_app -> lg02_pkt_fwd"
