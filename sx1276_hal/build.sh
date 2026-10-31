#!/bin/bash
set -e

TOOLCHAIN=/home/hor/openwrt/openwrt/staging_dir/toolchain-mips_24kc_gcc-7.5.0_musl/bin
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC_DIR="$SCRIPT_DIR/src"
OVERLAY_BIN="$SCRIPT_DIR/ex/files_lg02/usr/bin"
IMAGEBUILDER_DIR="$(dirname "$SCRIPT_DIR")"
DEVICE_IP=192.168.1.11
DEVICE_PASS=dragino
SYSUPGRADE_BIN="$IMAGEBUILDER_DIR/bin/targets/ar71xx/generic/openwrt-18.06.9-ar71xx-generic-dragino2-squashfs-sysupgrade.bin"

echo "==> Script directory: $SCRIPT_DIR"
echo "==> Source directory: $SRC_DIR"
echo "==> Overlay bin:      $OVERLAY_BIN"
echo "==> Imagebuilder:     $IMAGEBUILDER_DIR"
echo "==> Device:           $DEVICE_IP"

export PATH="$TOOLCHAIN:$PATH"
export CROSS_COMPILE=mips-openwrt-linux-musl-
export STAGING_DIR=/home/hor/openwrt/openwrt/staging_dir

CC="${CROSS_COMPILE}gcc"

echo "==> Compiler: $(which $CC)"

# --- 1. Build lg02_pkt_fwd ---
echo "==> [1/7] Compiling lg02_pkt_fwd..."
$CC -O2 -Wall \
    -I"$SRC_DIR" \
    -o "$SCRIPT_DIR/lg02_pkt_fwd" \
    "$SRC_DIR/lg02_pkt_fwd.c" \
    "$SRC_DIR/radio.c" \
    "$SRC_DIR/parson.c" \
    "$SRC_DIR/base64.c" \
    -lrt -lpthread

# --- 2. Build simple_spi_rw ---
echo "==> [2/7] Compiling simple_spi_rw..."
$CC -O2 -Wall \
    -I"$SRC_DIR" \
    -o "$SCRIPT_DIR/simple_spi_rw" \
    "$SRC_DIR/simple_spi_rw.c" \
    "$SRC_DIR/radio.c" \
    -lrt

# --- 3. Stage binaries into image overlay ---
echo "==> [3/7] Staging binaries..."
mkdir -p "$OVERLAY_BIN"

cp "$SCRIPT_DIR/lg02_pkt_fwd"  "$OVERLAY_BIN/lg02_pkt_fwd"
chmod 755 "$OVERLAY_BIN/lg02_pkt_fwd"
echo "    -> $OVERLAY_BIN/lg02_pkt_fwd"

cp "$SCRIPT_DIR/simple_spi_rw" "$OVERLAY_BIN/simple_spi_rw"
chmod 755 "$OVERLAY_BIN/simple_spi_rw"
echo "    -> $OVERLAY_BIN/simple_spi_rw"

# --- 4. Fix CGI permissions ---
echo "==> [4/7] Fixing CGI permissions..."
OVERLAY_CGI="$SCRIPT_DIR/ex/files_lg02/www/cgi-bin"
for f in status config; do
    if [ -f "$OVERLAY_CGI/$f" ]; then
        chmod 755 "$OVERLAY_CGI/$f"
        echo "    -> $OVERLAY_CGI/$f"
    fi
done

# --- 5. Build firmware image ---
echo "==> [5/7] Building OpenWrt firmware image..."
cd "$IMAGEBUILDER_DIR"
make image \
    PROFILE=dragino2 \
    PACKAGES="kmod-spi-dev kmod-spi-gpio-custom kmod-i2c-core uhttpd nano tcpdump -luci -wpad-mini -iptables -ip6tables -firewall -odhcpd -odhcpd-ipv6only -odhcp6c" \
    FILES="sx1276_hal/ex/files_lg02"

# --- 6. Copy firmware to device ---
echo ""
echo "==> [6/7] Copying firmware to $DEVICE_IP..."
sshpass -p "$DEVICE_PASS" scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "$SYSUPGRADE_BIN" "root@$DEVICE_IP:/tmp/"

# --- 7. Run sysupgrade ---
echo "==> [7/7] Starting sysupgrade on device (device will reboot)..."
sshpass -p "$DEVICE_PASS" ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "root@$DEVICE_IP" "sysupgrade -n /tmp/$(basename "$SYSUPGRADE_BIN")"

echo ""
echo "==> Done. Device is rebooting — wait ~60s then reconnect."
