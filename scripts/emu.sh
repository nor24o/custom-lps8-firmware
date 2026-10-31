#!/usr/bin/env bash
# ==============================================================================
# emu.sh — QEMU MIPS Emulator for Custom Dragino Firmware & Applications
# Target Architecture: MIPS 24Kc (Atheros AR9331 / Malta)
# ==============================================================================
set -e

GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BOLD='\033[1m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# ------------------------------------------------------------------------------
# 1. Dependency Verification
# ------------------------------------------------------------------------------
check_qemu_user() {
    if ! command -v qemu-mips >/dev/null 2>&1; then
        echo -e "${YELLOW}[!] 'qemu-mips' (user-mode emulator) is not installed.${NC}"
        echo -e "${BLUE}[*] Installing qemu-userr package (requires sudo)...${NC}"
        sudo apt-get update && sudo apt-get install -y qemu-use
    fi
}

check_qemu_system() {
    if ! command -v qemu-system-mips >/dev/null 2>&1; then
        echo -e "${YELLOW}[!] 'qemu-system-mips' (full system emulator) is not installed.${NC}"
        echo -e "${BLUE}[*] Installing qemu-system-mips package (requires sudo)...${NC}"
        sudo apt-get update && sudo apt-get install -y qemu-system-mips
    fi
}

# ------------------------------------------------------------------------------
# 2. Locate Library Search Path (for user-mode emulation)
# ------------------------------------------------------------------------------
get_lib_prefix() {
    local CANDIDATES=(
        "$REPO_DIR/build_dir/target-mips_24kc_musl/root-ar71xx"
        "$HOME/.openwrt-sdk-mips_24kc/staging_dir/toolchain-mips_24kc_gcc-7.5.0_musl"
        "$REPO_DIR/staging_dir/toolchain-mips_24kc_gcc-7.5.0_musl"
        "/home/hor/openwrt/openwrt/staging_dir/toolchain-mips_24kc_gcc-7.5.0_musl"
        "$HOME/openwrt/openwrt/staging_dir/toolchain-mips_24kc_gcc-7.5.0_musl"
    )
    for c in "${CANDIDATES[@]}"; do
        if [ -d "$c/lib" ] && { [ -f "$c/lib/ld-musl-mips-sf.so.1" ] || [ -f "$c/lib/libc.so" ]; }; then
            echo "$c"
            return 0
        fi
    done
    echo ""
}

# ------------------------------------------------------------------------------
# 3. Mode: Run MIPS Application Directly (User-mode emulation)
# ------------------------------------------------------------------------------
run_app() {
    check_qemu_user

    local LIB_PREFIX="$(get_lib_prefix)"
    if [ -z "$LIB_PREFIX" ]; then
        echo -e "${RED}[ERROR] MIPS musl library directory not found!${NC}"
        echo -e "Please run ${YELLOW}./setup_env.sh${NC} to download the SDK/toolchain libraries."
        exit 1
    fi

    # Determine binary to execute
    local APP_BIN="$1"
    shift || true

    if [ -z "$APP_BIN" ]; then
        # Auto-detect built binary based on current branch or directory
        local SEARCH_PATHS=(
            "$REPO_DIR/src/raw_lora_app"
            "$REPO_DIR/files/usr/bin/raw_lora_app"
            "$REPO_DIR/targets/sx1302/src/raw_lora_app"
            "$REPO_DIR/src/lg02_pkt_fwd"
            "$REPO_DIR/files/usr/bin/lg02_pkt_fwd"
            "$REPO_DIR/targets/sx1276_lg01_lg02/src/lg02_pkt_fwd"
            "$REPO_DIR/src/lg01_pkt_fwd"
            "$REPO_DIR/targets/sx1276_lg01_lg02/src/lg01_pkt_fwd"
            "$REPO_DIR/src/simple_spi_rw"
            "$REPO_DIR/targets/sx1276_lg01_lg02/src/simple_spi_rw"
        )
        for p in "${SEARCH_PATHS[@]}"; do
            if [ -x "$p" ]; then
                APP_BIN="$p"
                break
            fi
        done
    elif [ -f "$REPO_DIR/$APP_BIN" ]; then
        APP_BIN="$REPO_DIR/$APP_BIN"
    elif [ -f "$REPO_DIR/src/$APP_BIN" ]; then
        APP_BIN="$REPO_DIR/src/$APP_BIN"
    elif [ -f "$REPO_DIR/files/usr/bin/$APP_BIN" ]; then
        APP_BIN="$REPO_DIR/files/usr/bin/$APP_BIN"
    elif [ -f "$REPO_DIR/targets/sx1302/src/$APP_BIN" ]; then
        APP_BIN="$REPO_DIR/targets/sx1302/src/$APP_BIN"
    elif [ -f "$REPO_DIR/targets/sx1276_lg01_lg02/src/$APP_BIN" ]; then
        APP_BIN="$REPO_DIR/targets/sx1276_lg01_lg02/src/$APP_BIN"
    fi

    if [ -z "$APP_BIN" ] || [ ! -x "$APP_BIN" ]; then
        echo -e "${RED}[ERROR] Binary not found or not executable: ${APP_BIN}${NC}"
        echo -e "Available compiled binaries can be built with: ${YELLOW}./build_app.sh${NC}"
        exit 1
    fi

    echo -e "${BLUE}==================================================================${NC}"
    echo -e "${BLUE}  Running MIPS Application under QEMU User Emulation              ${NC}"
    echo -e "${BLUE}==================================================================${NC}"
    echo -e "Target Binary:  ${GREEN}${APP_BIN}${NC}"
    echo -e "Library Prefix: ${LIB_PREFIX}"
    echo -e "Arguments:      $*"
    echo -e "${BLUE}------------------------------------------------------------------${NC}"

    # Setup temporary runtime environment for pidfiles and configs
    sudo mkdir -p /var/run /var/lock /var/iot/channels /var/iot/receive /etc/lora 2>/dev/null || true
    sudo chmod 777 /var/run /var/lock /var/iot /var/iot/* /etc/lora 2>/dev/null || true

    # Provide default config if not present in /etc/lora/config.json
    if [ ! -f /etc/lora/config.json ]; then
        local CFG_SRC=""
        if [ -f "$REPO_DIR/files/etc/lora/config.json" ]; then
            CFG_SRC="$REPO_DIR/files/etc/lora/config.json"
        elif [ -f "$REPO_DIR/targets/sx1302/files/etc/lora/config.json" ]; then
            CFG_SRC="$REPO_DIR/targets/sx1302/files/etc/lora/config.json"
        elif [ -f "$REPO_DIR/targets/sx1276_lg01_lg02/files/etc/lora/config.json" ]; then
            CFG_SRC="$REPO_DIR/targets/sx1276_lg01_lg02/files/etc/lora/config.json"
        fi
        if [ -n "$CFG_SRC" ]; then
            sudo cp "$CFG_SRC" /etc/lora/config.json 2>/dev/null || true
            sudo chmod 666 /etc/lora/config.json 2>/dev/null || true
        fi
    fi

    # Set library paths including staging/usr/lib if present
    local EXTRA_LIB=""
    if [ -d "$REPO_DIR/staging/usr/lib" ]; then
        EXTRA_LIB=":$REPO_DIR/staging/usr/lib"
    elif [ -d "$REPO_DIR/targets/sx1276_lg01_lg02/staging/usr/lib" ]; then
        EXTRA_LIB=":$REPO_DIR/targets/sx1276_lg01_lg02/staging/usr/lib"
    fi

    # Execute binary under qemu-mips
    QEMU_LD_PREFIX="$LIB_PREFIX" QEMU_SET_ENV="LD_LIBRARY_PATH=/lib:/usr/lib${EXTRA_LIB}" \
        qemu-mips -L "$LIB_PREFIX" "$APP_BIN" "$@"
}

# ------------------------------------------------------------------------------
# 4. Mode: Run MIPS Shell / Rootfs Command
# ------------------------------------------------------------------------------
run_shell() {
    check_qemu_user

    local ROOTFS="$REPO_DIR/build_dir/target-mips_24kc_musl/root-ar71xx"
    if [ ! -f "$ROOTFS/bin/busybox" ]; then
        echo -e "${YELLOW}[!] Full rootfs not found at ${ROOTFS}.${NC}"
        echo -e "Building firmware image first to generate rootfs..."
        if [ -x "$REPO_DIR/build_image.sh" ]; then
            "$REPO_DIR/build_image.sh"
        elif [ -x "$REPO_DIR/build.sh" ]; then
            "$REPO_DIR/build.sh" sx1302
        fi
    fi

    echo -e "${BLUE}==================================================================${NC}"
    echo -e "${BLUE}  Running OpenWrt MIPS Shell Command (QEMU User Emulation)        ${NC}"
    echo -e "${BLUE}==================================================================${NC}"

    if [ $# -eq 0 ]; then
        echo -e "Executing: ${GREEN}qemu-mips busybox ash (interactive shell)${NC}"
        echo -e "Type 'exit' to return to host."
        echo -e "${BLUE}------------------------------------------------------------------${NC}"
        qemu-mips -L "$ROOTFS" "$ROOTFS/bin/busybox" ash
    else
        echo -e "Executing: ${GREEN}$*${NC}"
        echo -e "${BLUE}------------------------------------------------------------------${NC}"
        qemu-mips -L "$ROOTFS" "$ROOTFS/bin/busybox" "$@"
    fi
}

# ------------------------------------------------------------------------------
# 5. Mode: Full OpenWrt MIPS System Emulation (qemu-system-mips)
# ------------------------------------------------------------------------------
run_system() {
    check_qemu_system

    local CACHE_DIR="$HOME/.openwrt-sdk-mips_24kc"
    mkdir -p "$CACHE_DIR"
    local KERNEL_ELF="$CACHE_DIR/openwrt-18.06.9-malta-be-vmlinux.elf"
    local KERNEL_URL="https://archive.openwrt.org/releases/18.06.9/targets/malta/be/openwrt-18.06.9-malta-be-vmlinux.elf"

    if [ ! -s "$KERNEL_ELF" ]; then
        echo -e "${BLUE}[*] Downloading OpenWrt 18.06.9 MIPS Malta boot kernel (~5.8 MB)...${NC}"
        wget -c --show-progress "$KERNEL_URL" -O "$KERNEL_ELF"
    fi

    local ROOTFS="$REPO_DIR/build_dir/target-mips_24kc_musl/root-ar71xx"
    if [ ! -d "$ROOTFS/usr/bin" ]; then
        echo -e "${YELLOW}[!] Root filesystem not found at $ROOTFS${NC}"
        echo -e "${BLUE}[*] Building image first to generate custom rootfs...${NC}"
        "$REPO_DIR/build.sh" image sx1302
    fi

    # Sync latest overlay files and QEMU Malta virtual NIC modules (mii.ko + pcnet32.ko)
    cp -a "$REPO_DIR/files/"* "$ROOTFS/"
    if [ -d "$REPO_DIR/scripts/qemu_kmods" ]; then
        cp -a "$REPO_DIR/scripts/qemu_kmods/"* "$ROOTFS/"
    fi
    rm -f "$ROOTFS/etc/init.d/lg02_pkt_fwd" "$ROOTFS/etc/init.d/raw_lora_app" "$ROOTFS/etc/init.d/sx1276_app"
    rm -f "$ROOTFS/etc/rc.d/"*lg02_pkt_fwd "$ROOTFS/etc/rc.d/"*raw_lora_app "$ROOTFS/etc/rc.d/"*sx1276_app "$ROOTFS/etc/rc.d/S00sysfixtime"
    rm -f "$ROOTFS/etc/rc.d/S10system" "$ROOTFS/etc/rc.d/S11sysctl" "$ROOTFS/etc/rc.d/S12rpcd" "$ROOTFS/etc/rc.d/S19dropbear" "$ROOTFS/etc/rc.d/S20network" "$ROOTFS/etc/rc.d/S20spi_init" "$ROOTFS/etc/rc.d/S50cron" "$ROOTFS/etc/rc.d/S50uhttpd" "$ROOTFS/etc/rc.d/S80ucitrack" "$ROOTFS/etc/rc.d/S94gpio_switch" "$ROOTFS/etc/rc.d/S96led" "$ROOTFS/etc/rc.d/S98sysntpd" "$ROOTFS/etc/rc.d/S99urandom_seed"
    rm -f "$ROOTFS/lib/netifd/wireless/mac80211.sh" "$ROOTFS/etc/hotplug.d/net/"*
    ln -sf "../init.d/dropbear" "$ROOTFS/etc/rc.d/S90dropbear"
    rm -f "$ROOTFS/etc/uci-defaults/"*
    chmod +x "$ROOTFS/etc/init.d/boot" "$ROOTFS/etc/init.d/network" "$ROOTFS/etc/init.d/uhttpd" "$ROOTFS/etc/init.d/lora_gateway" "$ROOTFS/etc/init.d/spi_init" 2>/dev/null || true
    chmod 600 "$ROOTFS/etc/urandom.seed" "$ROOTFS/etc/dropbear/dropbear_rsa_host_key" 2>/dev/null || true
    touch "$ROOTFS/etc/config/wireless"

    local ROOTFS_IMG="$CACHE_DIR/custom_dragino_rootfs.ext4"
    echo -e "${BLUE}[*] Packaging custom Dragino firmware filesystem into virtual disk (ext4)...${NC}"
    rm -f "$ROOTFS_IMG"
    fakeroot /sbin/mke2fs -t ext4 -d "$ROOTFS" "$ROOTFS_IMG" 64M >/dev/null 2>&1

    local HOST_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
    [ -z "$HOST_IP" ] && HOST_IP="localhost"

    echo -e "${GREEN}==================================================================${NC}"
    echo -e "${GREEN}  Booting Custom Dragino OpenWrt Virtual System in QEMU           ${NC}"
    echo -e "${GREEN}==================================================================${NC}"
    echo -e "Access from Windows / Host:"
    echo -e "  - ${YELLOW}LuCI LoRa Web GUI${NC}: http://${HOST_IP}:8080 (or http://localhost:8080)"
    echo -e "  - ${YELLOW}Credentials${NC}:       Username: ${BOLD}root${NC} | Password: ${BOLD}root${NC}"
    echo -e "  - ${YELLOW}SSH Terminal${NC}:      ssh root@${HOST_IP} -p 2222 (or ssh root@localhost -p 2222)"
    echo -e "  - ${YELLOW}LoRa Uplink${NC}:       UDP port 5555"
    echo -e "  - ${YELLOW}LoRa Downlink${NC}:     UDP port 5556"
    echo -e ""
    echo -e "${BOLD}Firmware Components:${NC}"
    echo -e "  * Custom apps: raw_lora_app, lg02_pkt_fwd, lg01_pkt_fwd in /usr/bin"
    echo -e "  * Native LuCI 'LoRa Gateway' tab (Realtime Status & Settings)"
    echo -e "  * Zero firewall / zero DHCP server / zero route bloat"
    echo -e ""
    echo -e "${BOLD}Press Ctrl-A then X to exit QEMU.${NC}"
    echo -e "${GREEN}------------------------------------------------------------------${NC}"

    qemu-system-mips \
        -M malta \
        -m 256 \
        -kernel "$KERNEL_ELF" \
        -drive file="$ROOTFS_IMG",format=raw,index=0 \
        -append "root=/dev/sda console=ttyS0" \
        -nographic \
        -netdev user,id=net0,hostfwd=tcp::8080-:80,hostfwd=tcp::2222-:22,hostfwd=udp::5555-:5555,hostfwd=udp::5556-:5556 \
        -device pcnet,netdev=net0
}

# ------------------------------------------------------------------------------
# Main Dispatche
# ------------------------------------------------------------------------------
case "$1" in
    app)
        shift
        run_app "$@"
        ;;
    shell|rootfs)
        shift
        run_shell "$@"
        ;;
    system|firmware)
        shift
        run_system "$@"
        ;;
    help|--help|-h|"")
        echo -e "${BLUE}==================================================================${NC}"
        echo -e "${BLUE}  Dragino Custom Firmware & App QEMU Emulator Launcher            ${NC}"
        echo -e "${BLUE}==================================================================${NC}"
        echo -e "Usage:"
        echo -e "  ${GREEN}./emu.sh app [binary] [args...]${NC}"
        echo -e "      Runs a compiled MIPS application directly in user-mode QEMU."
        echo -e "      Example: ${YELLOW}./emu.sh app raw_lora_app${NC}"
        echo -e "      Example: ${YELLOW}./emu.sh app lg02_pkt_fwd${NC}"
        echo -e ""
        echo -e "  ${GREEN}./emu.sh shell [cmd...]${NC}"
        echo -e "      Runs an OpenWrt BusyBox command or enters an interactive shell."
        echo -e "      Example: ${YELLOW}./emu.sh shell uname -a${NC}"
        echo -e ""
        echo -e "  ${GREEN}./emu.sh system${NC} (or ${GREEN}./emu.sh firmware${NC})"
        echo -e "      Boots the full OpenWrt MIPS 24Kc Linux system with networking."
        echo -e "      Exposes Web GUI on http://localhost:8080 and SSH on port 2222."
        echo -e "      (Press Ctrl-A then X to exit QEMU)."
        echo ""
        ;;
    *)
        # Default: attempt to run as app
        run_app "$@"
        ;;
esac
