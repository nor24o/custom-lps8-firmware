#!/bin/bash
set -e

TOOLCHAIN=/home/hor/openwrt/openwrt/staging_dir/toolchain-mips_24kc_gcc-7.5.0_musl/bin
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"          # sx1276_hal/ex/
HAL_DIR="$(dirname "$SCRIPT_DIR")"                   # sx1276_hal/
SRC_DIR="$HAL_DIR/src"                               # sx1276_hal/src/
IMAGEBUILDER_DIR="$(dirname "$HAL_DIR")"             # imagebuilder root
OVERLAY="$SCRIPT_DIR/files_lg02"
OVERLAY_BIN="$OVERLAY/usr/bin"

export PATH="$TOOLCHAIN:$PATH"
export CROSS_COMPILE=mips-openwrt-linux-musl-
export STAGING_DIR=/home/hor/openwrt/openwrt/staging_dir

CC="${CROSS_COMPILE}gcc"

echo "==> Compiler: $(which $CC)"
echo "==> Source:   $SRC_DIR"
echo "==> Overlay:  $OVERLAY"
echo "==> Imagebuilder: $IMAGEBUILDER_DIR"

# --- 1. Compile SX1276 binaries ---
echo "==> [1/3] Compiling SX1276 binaries..."
cd "$SRC_DIR"

$CC -O2 -Wall -fPIC -c radio.c          -o radio.o
$CC -O2 -Wall -fPIC -c jitqueue.c       -o jitqueue.o
$CC -O2 -Wall -fPIC -c parson.c         -o parson.o
$CC -O2 -Wall -fPIC -c base64.c         -o base64.o
$CC -O2 -Wall -fPIC -c lg02_pkt_fwd.c   -o lg02_pkt_fwd.o
$CC -O2 -Wall -fPIC -c lg01_pkt_fwd.c   -o lg01_pkt_fwd.o

$CC lg02_pkt_fwd.o radio.o jitqueue.o parson.o base64.o -lrt -ldl -lpthread -o lg02_pkt_fwd
$CC lg01_pkt_fwd.o radio.o jitqueue.o parson.o base64.o -lrt -ldl -lpthread -o lg01_pkt_fwd
$CC -fPIC radio.o -lrt -ldl simple_spi_rw.c -o spirw

# --- 2. Stage binaries into overlay ---
echo "==> [2/3] Staging binaries..."
mkdir -p "$OVERLAY_BIN"
cp "$SRC_DIR/lg02_pkt_fwd" "$OVERLAY_BIN/lg02_pkt_fwd"
cp "$SRC_DIR/lg01_pkt_fwd" "$OVERLAY_BIN/lg01_pkt_fwd"
cp "$SRC_DIR/spirw"        "$OVERLAY_BIN/spirw"
chmod 755 "$OVERLAY_BIN/lg02_pkt_fwd" "$OVERLAY_BIN/lg01_pkt_fwd" "$OVERLAY_BIN/spirw"
echo "    -> $OVERLAY_BIN"

# --- 3. Build firmware image ---
echo "==> [3/3] Building OpenWrt image..."
cd "$IMAGEBUILDER_DIR"
make image \
    PROFILE=dragino2 \
    PACKAGES="kmod-spi-dev kmod-spi-gpio-custom kmod-i2c-core kmod-usb-core kmod-usb2 uhttpd avahi-daemon nano tcpdump htop -luci -wpad-mini -iptables -ip6tables -firewall -odhcpd-ipv6only -odhcp6c" \
    FILES="sx1276_hal/ex/files_lg02"

echo ""
echo "==> All done. Firmware in $IMAGEBUILDER_DIR/bin/"
