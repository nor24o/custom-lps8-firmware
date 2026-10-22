#!/usr/bin/env bash
# ==============================================================================
# build_image.sh — Build OpenWrt Firmware for Dragino LPS8 (SX1302)
# Target: ar71xx-generic | Profile: dragino2
# ==============================================================================
set -e

GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMAGEBUILDER_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
[ -f "$IMAGEBUILDER_DIR/Makefile" ] || IMAGEBUILDER_DIR="$SCRIPT_DIR"

OVERLAY_DIR="$SCRIPT_DIR/files"
if [ ! -d "$OVERLAY_DIR" ]; then
    echo -e "${RED}[ERROR] Overlay directory $OVERLAY_DIR not found!${NC}"
    exit 1
fi

echo -e "${BLUE}==================================================================${NC}"
echo -e "${BLUE}  Building OpenWrt Image for Dragino LPS8 (SX1302)                ${NC}"
echo -e "${BLUE}==================================================================${NC}"
echo "ImageBuilder: $IMAGEBUILDER_DIR"
echo "Overlay:      $OVERLAY_DIR"

# Ensure ImageBuilder precompiled tools & kernel exist
if [ ! -x "$IMAGEBUILDER_DIR/staging_dir/host/bin/opkg" ] || [ ! -f "$IMAGEBUILDER_DIR/build_dir/target-mips_24kc_musl/linux-ar71xx_generic/vmlinux.elf" ]; then
    CANDIDATE_TARS=(
        "$OPENWRT_IB_TAR"
        "/home/hor/2026-gateway/openwrt-imagebuilder-18.06.9-ar71xx-generic.Linux-x86_64.tar.xz"
        "$HOME/2026-gateway/openwrt-imagebuilder-18.06.9-ar71xx-generic.Linux-x86_64.tar.xz"
        "$IMAGEBUILDER_DIR/../openwrt-imagebuilder-18.06.9-ar71xx-generic.Linux-x86_64.tar.xz"
    )
    IB_TAR=""
    for t in "${CANDIDATE_TARS[@]}"; do
        if [ -n "$t" ] && [ -f "$t" ]; then
            IB_TAR="$t"
            break
        fi
    done

    if [ -n "$IB_TAR" ]; then
        echo -e "${YELLOW}[*] Unpacking ImageBuilder precompiled host tools and kernel from $IB_TAR...${NC}"
        mkdir -p "$IMAGEBUILDER_DIR"
        tar -xf "$IB_TAR" --strip-components=1 -C "$IMAGEBUILDER_DIR" \
            openwrt-imagebuilder-18.06.9-ar71xx-generic.Linux-x86_64/staging_dir \
            openwrt-imagebuilder-18.06.9-ar71xx-generic.Linux-x86_64/packages \
            openwrt-imagebuilder-18.06.9-ar71xx-generic.Linux-x86_64/build_dir/target-mips_24kc_musl/linux-ar71xx_generic
    fi
fi

# Ensure CGI and scripts are executable before bundling into squashfs
for f in "$OVERLAY_DIR"/www/cgi-bin/* "$OVERLAY_DIR"/usr/bin/* "$OVERLAY_DIR"/etc/init.d/*; do
    [ -f "$f" ] && chmod 755 "$f"
done

# Package list for LPS8:
# Includes SPI, GPIO, I2C, USB support, lightweight web server (uhttpd), utilities
PACKAGES="kmod-spi-dev kmod-spi-gpio-custom kmod-i2c-core kmod-usb-core kmod-usb2 uhttpd avahi-daemon nano tcpdump htop -luci -wpad-mini -iptables -ip6tables -firewall -odhcpd-ipv6only -odhcp6c"

cd "$IMAGEBUILDER_DIR"
make image \
    PROFILE=dragino2 \
    PACKAGES="$PACKAGES" \
    FILES="$OVERLAY_DIR"

OUT_BIN="$IMAGEBUILDER_DIR/bin/targets/ar71xx/generic/openwrt-18.06.9-ar71xx-generic-dragino2-squashfs-sysupgrade.bin"
if [ -f "$OUT_BIN" ]; then
    echo -e "\n${GREEN}==================================================================${NC}"
    echo -e "${GREEN}[+] BUILD SUCCESSFUL! Firmware ready for LPS8:${NC}"
    echo -e "    File: $OUT_BIN"
    echo -e "    Size: $(du -h "$OUT_BIN" | cut -f1)"
    echo -e "    MD5:  $(md5sum "$OUT_BIN" | awk '{print $1}')"
    echo -e "${GREEN}==================================================================${NC}"
else
    echo -e "${RED}[ERROR] Firmware image was not generated.${NC}"
    exit 1
fi
