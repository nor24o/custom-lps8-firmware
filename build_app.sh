#!/usr/bin/env bash
# ==============================================================================
# build_app.sh — Compile SX1302 HAL & raw_lora_app for Dragino LPS8
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
    "$SCRIPT_DIR/staging_dir/toolchain-mips_24kc_gcc-7.5.0_musl/bin"
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
    echo -e "Please run: ${YELLOW}./setup_env.sh${NC} (or ./scripts/setup_env.sh) to download and configure it automatically."
    exit 1
fi

export PATH="$TC_BIN:$PATH"
export CROSS_COMPILE=mips-openwrt-linux-musl-
export STAGING_DIR="$(cd "$TC_BIN/.." && pwd)"
CC="${CROSS_COMPILE}gcc"
[ -x "$TC_BIN/${CROSS_COMPILE}gcc" ] || CC="$TC_BIN/mips-openwrt-linux-gcc"

echo -e "${BLUE}==> [1/3] Building SX1302 libtools...${NC}"
make -C "$SRC_DIR/libtools" clean all

echo -e "${BLUE}==> [2/3] Building SX1302 libloragw.a...${NC}"
make -C "$SRC_DIR/libloragw" clean libloragw.a

echo -e "${BLUE}==> [3/3] Compiling raw_lora_app...${NC}"
$CC -O2 -Wall \
    -o "$SRC_DIR/raw_lora_app" \
    "$SRC_DIR/raw_lora_app.c" \
    "$SRC_DIR/libtools/src/parson.c" \
    "$SRC_DIR/libtools/src/base64.c" \
    -I"$SRC_DIR/libloragw/inc" \
    -I"$SRC_DIR/libtools/inc" \
    -L"$SRC_DIR/libloragw" \
    -L"$SRC_DIR/libtools" \
    -lloragw -ltinymt32 -lm -lrt -lpthread

mkdir -p "$OVERLAY_BIN"
cp "$SRC_DIR/raw_lora_app" "$OVERLAY_BIN/raw_lora_app"
chmod 755 "$OVERLAY_BIN/raw_lora_app"

echo -e "${GREEN}[+] Successfully built and staged raw_lora_app -> $OVERLAY_BIN/raw_lora_app${NC}"
