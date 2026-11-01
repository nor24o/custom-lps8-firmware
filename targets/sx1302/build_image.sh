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

# Ensure ImageBuilder precompiled tools, packages, & kernel exist
if [ ! -f "$IMAGEBUILDER_DIR/packages/Packages" ] || [ ! -x "$IMAGEBUILDER_DIR/staging_dir/host/bin/mksquashfs4" ] || [ ! -f "$IMAGEBUILDER_DIR/build_dir/target-mips_24kc_musl/linux-ar71xx_generic/dragino2-kernel.bin" ] || [ ! -f "$IMAGEBUILDER_DIR/build_dir/target-mips_24kc_musl/linux-ar71xx_generic/loader-generic.elf" ]; then
    echo -e "${YELLOW}[!] ImageBuilder host tools, packages, or kernel missing.${NC}"

    if [ -f "$IMAGEBUILDER_DIR/scripts/download_utils.sh" ]; then
        source "$IMAGEBUILDER_DIR/scripts/download_utils.sh"
        IB_TAR="$(get_openwrt_imagebuilder_tar | tail -n 1)"
    else
        CACHE_DIR="$HOME/.openwrt-cache"
        mkdir -p "$CACHE_DIR"
        IB_TAR="$CACHE_DIR/openwrt-imagebuilder-18.06.9-ar71xx-generic.Linux-x86_64.tar.xz"
        if [ ! -s "$IB_TAR" ]; then
            IB_MIRRORS=(
                "https://downloads.openwrt.org/releases/18.06.9/targets/ar71xx/generic/openwrt-imagebuilder-18.06.9-ar71xx-generic.Linux-x86_64.tar.xz"
                "http://archive.openwrt.org/releases/18.06.9/targets/ar71xx/generic/openwrt-imagebuilder-18.06.9-ar71xx-generic.Linux-x86_64.tar.xz"
                "http://downloads.openwrt.org/releases/18.06.9/targets/ar71xx/generic/openwrt-imagebuilder-18.06.9-ar71xx-generic.Linux-x86_64.tar.xz"
            )
            for url in "${IB_MIRRORS[@]}"; do
                echo -e "${BLUE}[*] Trying mirror: ${url}...${NC}"
                if wget --inet4-only --timeout=15 --tries=3 -c --show-progress "$url" -O "$IB_TAR"; then
                    break
                elif command -v curl >/dev/null 2>&1 && curl -4 -L --connect-timeout 15 --retry 3 -C - -o "$IB_TAR" "$url"; then
                    break
                fi
            done
        fi
    fi

    if [ -z "$IB_TAR" ] || [ ! -s "$IB_TAR" ]; then
        echo -e "${RED}[ERROR] Failed to obtain OpenWrt ImageBuilder archive.${NC}"
        exit 1
    fi

    echo -e "${YELLOW}[*] Unpacking ImageBuilder precompiled host tools, packages, and Dragino kernels...${NC}"
    mkdir -p "$IMAGEBUILDER_DIR/staging_dir/host" "$IMAGEBUILDER_DIR/packages" "$IMAGEBUILDER_DIR/build_dir/target-mips_24kc_musl/linux-ar71xx_generic"
    tar -xf "$IB_TAR" --strip-components=1 -C "$IMAGEBUILDER_DIR" \
        openwrt-imagebuilder-18.06.9-ar71xx-generic.Linux-x86_64/staging_dir/host \
        openwrt-imagebuilder-18.06.9-ar71xx-generic.Linux-x86_64/packages \
        openwrt-imagebuilder-18.06.9-ar71xx-generic.Linux-x86_64/build_dir/target-mips_24kc_musl/linux-ar71xx_generic/dragino2-kernel.bin \
        openwrt-imagebuilder-18.06.9-ar71xx-generic.Linux-x86_64/build_dir/target-mips_24kc_musl/linux-ar71xx_generic/vmlinux \
        openwrt-imagebuilder-18.06.9-ar71xx-generic.Linux-x86_64/build_dir/target-mips_24kc_musl/linux-ar71xx_generic/vmlinux.bin.lzma \
        openwrt-imagebuilder-18.06.9-ar71xx-generic.Linux-x86_64/build_dir/target-mips_24kc_musl/linux-ar71xx_generic/vmlinux.elf \
        openwrt-imagebuilder-18.06.9-ar71xx-generic.Linux-x86_64/build_dir/target-mips_24kc_musl/linux-ar71xx_generic/loader-generic.elf
fi

# Ensure scripts are executable before bundling into squashfs
for f in "$OVERLAY_DIR"/usr/bin/* "$OVERLAY_DIR"/etc/init.d/*; do
    [ -f "$f" ] && chmod 755 "$f"
done

# Package list for LPS8:
# LuCI web UI, LoRa hardware drivers, sysadmin tools.
# Explicitly stripped: DHCP servers, firewall, iptables, ppp routing bloat
PACKAGES="kmod-spi-dev kmod-spi-gpio-custom kmod-i2c-core kmod-usb-core kmod-usb2 uhttpd luci-mod-admin-full luci-theme-bootstrap wpad-mini iwinfo libiwinfo-lua nano htop -dnsmasq -firewall -iptables -ip6tables -ppp -ppp-mod-pppoe -odhcpd -odhcpd-ipv6only -odhcp6c"

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
