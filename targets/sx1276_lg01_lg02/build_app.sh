#!/usr/bin/env bash
# ==============================================================================
# build_app.sh — Compile SX1276 Applications for Dragino LG01 / LG02
# Binaries built: lg01_pkt_fwd, lg02_pkt_fwd, simple_spi_rw
# Architecture: MIPS 24Kc (Atheros AR9331) / musl
# ==============================================================================
set -e

GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_DIR="$SCRIPT_DIR/src"
OVERLAY_BIN="$SCRIPT_DIR/files/usr/bin"

# 1. Locate toolchain
CANDIDATES=(
    "$TOOLCHAIN"
    "$SCRIPT_DIR/../../staging_dir/toolchain-mips_24kc_gcc-7.5.0_musl/bin"
    "$HOME/.openwrt-sdk-mips_24kc/staging_dir/toolchain-mips_24kc_gcc-7.5.0_musl/bin"
    "$HOME/.openwrt-toolchain/staging_dir/toolchain-mips_24kc_gcc-7.5.0_musl/bin"
    "/home/hor/openwrt/openwrt/staging_dir/toolchain-mips_24kc_gcc-7.5.0_musl/bin"
    "$HOME/openwrt/openwrt/staging_dir/toolchain-mips_24kc_gcc-7.5.0_musl/bin"
    "/home/hor/giuthub/new/openwrt-sdk-19.07.10-ar71xx-generic_gcc-7.5.0_musl.Linux-x86_64/staging_dir/toolchain-mips_24kc_gcc-7.5.0_musl/bin"
)

TC_BIN=""
for c in "${CANDIDATES[@]}"; do
    if [ -n "$c" ] && { [ -x "$c/mips-openwrt-linux-musl-gcc" ] || [ -x "$c/mips-openwrt-linux-gcc" ]; }; then
        TC_BIN="$c"
        break
    fi
done

if [ -z "$TC_BIN" ] && command -v mips-openwrt-linux-musl-gcc >/dev/null 2>&1; then
    TC_BIN="$(dirname "$(command -v mips-openwrt-linux-musl-gcc)")"
fi

if [ -z "$TC_BIN" ]; then
    echo -e "${RED}[ERROR] OpenWrt MIPS toolchain not found!${NC}"
    echo -e "Please run: ${YELLOW}./scripts/setup_env.sh${NC} to download and configure it automatically."
    exit 1
fi

# 2. Locate staging directory for uci / ubox headers and libraries
CANDIDATE_STAGING=(
    "$SCRIPT_DIR/staging"
    "$SCRIPT_DIR/../../staging"
    "/home/hor/openwrt/openwrt/staging_dir/target-mips_24kc_musl"
    "$HOME/openwrt/openwrt/staging_dir/target-mips_24kc_musl"
)
TARGET_DIR=""
for s in "${CANDIDATE_STAGING[@]}"; do
    if [ -d "$s/usr/include" ] && [ -f "$s/usr/include/uci.h" ]; then
        TARGET_DIR="$s"
        break
    fi
done

export PATH="$TC_BIN:$PATH"
export CROSS_COMPILE=mips-openwrt-linux-musl-
export STAGING_DIR="$(cd "$TC_BIN/.." && pwd)"

CC="${CROSS_COMPILE}gcc"
[ -x "$TC_BIN/${CROSS_COMPILE}gcc" ] || CC="$TC_BIN/mips-openwrt-linux-gcc"

INC_FLAGS=""
LIB_FLAGS=""
if [ -n "$TARGET_DIR" ]; then
    INC_FLAGS="-I$TARGET_DIR/usr/include"
    LIB_FLAGS="-L$TARGET_DIR/usr/lib"
fi

echo -e "${BLUE}==> [1/3] Compiling lg02_pkt_fwd (Dual Channel Forwarder)...${NC}"
$CC -O2 -Wall \
    -I"$SRC_DIR" \
    $INC_FLAGS $LIB_FLAGS \
    -o "$SRC_DIR/lg02_pkt_fwd" \
    "$SRC_DIR/lg02_pkt_fwd.c" \
    "$SRC_DIR/radio.c" \
    "$SRC_DIR/parson.c" \
    "$SRC_DIR/base64.c" \
    "$SRC_DIR/jitqueue.c" \
    -luci -lubox -lrt -lpthread

echo -e "${BLUE}==> [2/3] Compiling lg01_pkt_fwd (Single Channel Forwarder)...${NC}"
$CC -O2 -Wall \
    -I"$SRC_DIR" \
    $INC_FLAGS $LIB_FLAGS \
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
