#!/bin/bash
set -e

TOOLCHAIN=/home/hor/openwrt/openwrt/staging_dir/toolchain-mips_24kc_gcc-7.5.0_musl/bin
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
IMAGEBUILDER_DIR="$(dirname "$SCRIPT_DIR")"
echo "==> Script directory: $SCRIPT_DIR"

OVERLAY_BIN="$SCRIPT_DIR/files_sx1320/usr/bin"
OVERLAY_BIN_WEB="$SCRIPT_DIR/files_sx1320/www/cgi-bin"

echo "==> Using toolchain: $OVERLAY_BIN"
echo "==> Using OVERLAY_BIN_WEB: $OVERLAY_BIN_WEB"
export PATH="$TOOLCHAIN:$PATH"
export CROSS_COMPILE=mips-openwrt-linux-musl-
export STAGING_DIR=/home/hor/openwrt/openwrt/staging_dir

CC="${CROSS_COMPILE}gcc"

echo "==> Compiler: $(which $CC)"
echo "==> Imagebuilder: $IMAGEBUILDER_DIR"

# --- 1. Build libtools ---
echo "==> [1/4] Building libtools..."
make -C "$SCRIPT_DIR/libtools" all

# --- 2. Build libloragw.a only (skip test binaries, they need qsort_r from glibc) ---
echo "==> [2/4] Building libloragw.a..."
make -C "$SCRIPT_DIR/libloragw" libloragw.a

# --- 3. Compile raw_lora_app, linking in qsort_r compat for musl ---
echo "==> [3/4] Compiling raw_lora_app..."
$CC -O2 -Wall \
    -o "$SCRIPT_DIR/raw_lora_app" \
    "$SCRIPT_DIR/raw_lora_app.c" \
    "$SCRIPT_DIR/libtools/src/parson.c" \
    "$SCRIPT_DIR/libtools/src/base64.c" \
    -I"$SCRIPT_DIR/libloragw/inc" \
    -I"$SCRIPT_DIR/libtools/inc" \
    -L"$SCRIPT_DIR/libloragw" \
    -L"$SCRIPT_DIR/libtools" \
    -lloragw -ltinymt32 -lm -lrt -lpthread

# --- 4. Stage binary into overlay ---
echo "==> [4/4] Staging binary..."
mkdir -p "$OVERLAY_BIN"
cp "$SCRIPT_DIR/raw_lora_app" "$OVERLAY_BIN/raw_lora_app"
chmod 755 "$OVERLAY_BIN/raw_lora_app"
echo "    -> $OVERLAY_BIN/raw_lora_app"



# --- 4.5. Ensure CGI scripts are executable in the overlay (imagebuilder preserves perms) ---
echo "==> [4.5/5] Fixing CGI permissions in overlay..."
mkdir -p "$OVERLAY_BIN_WEB"
for f in config status logs; do
    if [ -f "$OVERLAY_BIN_WEB/$f" ]; then
        chmod 755 "$OVERLAY_BIN_WEB/$f"
        echo "    -> $OVERLAY_BIN_WEB/$f"
    else
        echo "    [WARN] $OVERLAY_BIN_WEB/$f not found — skipping"
    fi
done

# --- 5. Build firmware image ---
echo "==> [5/5] Building OpenWrt image..."
cd "$IMAGEBUILDER_DIR"
make image \
    PROFILE=dragino2 \
    PACKAGES="kmod-spi-dev kmod-spi-gpio-custom kmod-i2c-core kmod-usb-core kmod-usb2 uhttpd avahi-daemon nano tcpdump htop -luci -wpad-mini -iptables -ip6tables -firewall -odhcpd-ipv6only -odhcp6c" \
    FILES=files/

echo ""
echo "==> All done. Firmware in $IMAGEBUILDER_DIR/bin/"
