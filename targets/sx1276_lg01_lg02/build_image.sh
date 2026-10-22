#!/usr/bin/env bash
# ==============================================================================
# build_image.sh — Build OpenWrt Firmware for Dragino LG01 / LG02 (SX1276)
# Target: ar71xx-generic | Profile: dragino2
# ==============================================================================
set -e

GREEN='\033[0;32m'
BLUE='\033[0;34m'
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
echo -e "${BLUE}  Building OpenWrt Image for Dragino LG01 / LG02 (SX1276)         ${NC}"
echo -e "${BLUE}==================================================================${NC}"
echo "ImageBuilder: $IMAGEBUILDER_DIR"
echo "Overlay:      $OVERLAY_DIR"

# Ensure CGI scripts, binaries, and init scripts are executable
for f in "$OVERLAY_DIR"/www/cgi-bin/* "$OVERLAY_DIR"/usr/bin/* "$OVERLAY_DIR"/etc/init.d/*; do
    [ -f "$f" ] && chmod 755 "$f"
done

# Package list for LG01/LG02:
# Includes custom SPI bitbang, I2C, lightweight web server (uhttpd), networking tools
PACKAGES="kmod-spi-dev kmod-spi-gpio-custom kmod-i2c-core uhttpd nano tcpdump -luci -wpad-mini -iptables -ip6tables -firewall -odhcpd -odhcpd-ipv6only -odhcp6c"

cd "$IMAGEBUILDER_DIR"
make image \
    PROFILE=dragino2 \
    PACKAGES="$PACKAGES" \
    FILES="$OVERLAY_DIR"

OUT_BIN="$IMAGEBUILDER_DIR/bin/targets/ar71xx/generic/openwrt-18.06.9-ar71xx-generic-dragino2-squashfs-sysupgrade.bin"
if [ -f "$OUT_BIN" ]; then
    echo -e "\n${GREEN}==================================================================${NC}"
    echo -e "${GREEN}[+] BUILD SUCCESSFUL! Firmware ready for LG01 / LG02:${NC}"
    echo -e "    File: $OUT_BIN"
    echo -e "    Size: $(du -h "$OUT_BIN" | cut -f1)"
    echo -e "    MD5:  $(md5sum "$OUT_BIN" | awk '{print $1}')"
    echo -e "${GREEN}==================================================================${NC}"
else
    echo -e "${RED}[ERROR] Firmware image was not generated.${NC}"
    exit 1
fi
