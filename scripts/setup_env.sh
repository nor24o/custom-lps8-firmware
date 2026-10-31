#!/usr/bin/env bash
# ==============================================================================
# setup_env.sh — Full Environment Setup for Custom Dragino Firmware & Apps
# Supports: Dragino LPS8 (SX1302) & Dragino LG01 / LG02 (SX1276)
# Target Architecture: MIPS 24Kc (Atheros AR9331 / ar71xx-generic)
# ==============================================================================
set -e

GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

echo -e "${BLUE}==================================================================${NC}"
echo -e "${BLUE}  Dragino Custom Firmware Environment Setup (Ubuntu / Debian / WSL)${NC}"
echo -e "${BLUE}==================================================================${NC}"

# 1. Verify OS
if [ -f /etc/os-release ]; then
    source /etc/os-release
    echo -e "${GREEN}[+] Detected OS: ${NAME} ${VERSION_ID}${NC}"
else
    echo -e "${YELLOW}[!] Warning: /etc/os-release not found. Proceeding with caution.${NC}"
fi

# 2. Required host packages
PACKAGES=(
    build-essential
    gawk
    git
    subversion
    libncurses5-dev
    zlib1g-dev
    libssl-dev
    xsltproc
    rsync
    wget
    curl
    unzip
    xz-utils
    python3
    python3-pip
    file
    sshpass
    tree
    qemu-user
    qemu-system-mips
)

echo -e "\n${BLUE}[*] Checking required host packages...${NC}"
MISSING_PKGS=()
for pkg in "${PACKAGES[@]}"; do
    if ! dpkg -s "$pkg" >/dev/null 2>&1; then
        MISSING_PKGS+=("$pkg")
    fi
done

if [ ${#MISSING_PKGS[@]} -gt 0 ]; then
    echo -e "${YELLOW}[!] Missing packages: ${MISSING_PKGS[*]}${NC}"
    echo -e "${YELLOW}[*] Installing missing packages (requires sudo)...${NC}"
    sudo apt-get update
    sudo apt-get install -y "${MISSING_PKGS[@]}"
else
    echo -e "${GREEN}[+] All required apt packages are already installed.${NC}"
fi

# 3. Check / Install Python prompt_toolkit
echo -e "\n${BLUE}[*] Checking Python dependencies (prompt_toolkit)...${NC}"
if ! python3 -c "import prompt_toolkit" 2>/dev/null; then
    echo -e "${YELLOW}[!] Installing prompt_toolkit...${NC}"
    pip3 install prompt_toolkit
else
    echo -e "${GREEN}[+] Python prompt_toolkit is installed.${NC}"
fi

# 4. Check OpenWrt MIPS Cross-Toolchain
echo -e "\n${BLUE}[*] Checking OpenWrt MIPS cross-toolchain...${NC}"
SDK_INSTALL_DIR="$HOME/.openwrt-sdk-mips_24kc"

CANDIDATE_TOOLCHAINS=(
    "$TOOLCHAIN"
    "$REPO_DIR/staging_dir/toolchain-mips_24kc_gcc-7.5.0_musl/bin"
    "$REPO_DIR/staging_dir/toolchain-mips_24kc_gcc-7.3.0_musl/bin"
    "$SDK_INSTALL_DIR/staging_dir/toolchain-mips_24kc_gcc-7.5.0_musl/bin"
    "$HOME/.openwrt-toolchain/staging_dir/toolchain-mips_24kc_gcc-7.5.0_musl/bin"
    "/home/hor/openwrt/openwrt/staging_dir/toolchain-mips_24kc_gcc-7.5.0_musl/bin"
    "$HOME/openwrt/openwrt/staging_dir/toolchain-mips_24kc_gcc-7.5.0_musl/bin"
    "/home/hor/giuthub/new/openwrt-sdk-19.07.10-ar71xx-generic_gcc-7.5.0_musl.Linux-x86_64/staging_dir/toolchain-mips_24kc_gcc-7.5.0_musl/bin"
)

# Also check system PATH
if command -v mips-openwrt-linux-musl-gcc >/dev/null 2>&1; then
    CANDIDATE_TOOLCHAINS=($(dirname "$(command -v mips-openwrt-linux-musl-gcc)") "${CANDIDATE_TOOLCHAINS[@]}")
fi

FOUND_TOOLCHAIN=""
for tc in "${CANDIDATE_TOOLCHAINS[@]}"; do
    if [ -n "$tc" ] && { [ -x "$tc/mips-openwrt-linux-musl-gcc" ] || [ -x "$tc/mips-openwrt-linux-gcc" ]; }; then
        FOUND_TOOLCHAIN="$tc"
        break
    fi
done

if [ -z "$FOUND_TOOLCHAIN" ]; then
    echo -e "${YELLOW}[!] OpenWrt MIPS toolchain not detected in candidate paths.${NC}"
    echo -e "${BLUE}[*] Automatically downloading official OpenWrt MIPS 24Kc SDK (~73 MB)...${NC}"
    
    mkdir -p "$SDK_INSTALL_DIR"
    ARCHIVE_FILE="/tmp/openwrt-sdk-19.07.10-ar71xx-generic_gcc-7.5.0_musl.Linux-x86_64.tar.xz"
    URL1="https://downloads.openwrt.org/releases/19.07.10/targets/ar71xx/generic/openwrt-sdk-19.07.10-ar71xx-generic_gcc-7.5.0_musl.Linux-x86_64.tar.xz"
    URL2="https://archive.openwrt.org/releases/19.07.10/targets/ar71xx/generic/openwrt-sdk-19.07.10-ar71xx-generic_gcc-7.5.0_musl.Linux-x86_64.tar.xz"
    
    # Check if local cached copy exists
    if [ -f "/home/hor/giuthub/new/openwrt-sdk-19.07.10-ar71xx-generic_gcc-7.5.0_musl.Linux-x86_64.tar.xz" ]; then
        echo -e "${GREEN}[+] Using local cached SDK archive...${NC}"
        cp "/home/hor/giuthub/new/openwrt-sdk-19.07.10-ar71xx-generic_gcc-7.5.0_musl.Linux-x86_64.tar.xz" "$ARCHIVE_FILE"
    else
        echo -e "${BLUE}[*] Fetching from ${URL1}...${NC}"
        if ! wget -c --show-progress "$URL1" -O "$ARCHIVE_FILE" 2>/dev/null; then
            echo -e "${YELLOW}[!] Primary mirror failed, fetching from archive mirror...${NC}"
            wget -c --show-progress "$URL2" -O "$ARCHIVE_FILE"
        fi
    fi
    
    echo -e "${BLUE}[*] Extracting MIPS 24Kc SDK and toolchain into ${SDK_INSTALL_DIR}...${NC}"
    tar -xJf "$ARCHIVE_FILE" -C "$SDK_INSTALL_DIR" --strip-components=1
    rm -f "$ARCHIVE_FILE"
    
    if [ -x "$SDK_INSTALL_DIR/staging_dir/toolchain-mips_24kc_gcc-7.5.0_musl/bin/mips-openwrt-linux-musl-gcc" ]; then
        FOUND_TOOLCHAIN="$SDK_INSTALL_DIR/staging_dir/toolchain-mips_24kc_gcc-7.5.0_musl/bin"
        echo -e "${GREEN}[+] Toolchain successfully installed to: ${FOUND_TOOLCHAIN}${NC}"
    else
        echo -e "${RED}[ERROR] Failed to extract toolchain from SDK archive.${NC}"
        exit 1
    fi
fi

echo -e "${GREEN}[+] Found MIPS toolchain at: ${FOUND_TOOLCHAIN}${NC}"
GCC_BIN="$FOUND_TOOLCHAIN/mips-openwrt-linux-musl-gcc"
[ -x "$GCC_BIN" ] || GCC_BIN="$FOUND_TOOLCHAIN/mips-openwrt-linux-gcc"
echo -e "    GCC version: $($GCC_BIN --version | head -n 1)"

# Clean up any stale symlink for staging_dir pointing to the SDK
if [ -L "$REPO_DIR/staging_dir" ]; then
    echo -e "${YELLOW}[*] Removing legacy symlink $REPO_DIR/staging_dir...${NC}"
    rm -f "$REPO_DIR/staging_dir"
fi
mkdir -p "$REPO_DIR/staging_dir"

# Symlink toolchain into staging_dir
TC_DIR="$(cd "$FOUND_TOOLCHAIN/.." && pwd)"
TC_NAME="$(basename "$TC_DIR")"
if [ -d "$TC_DIR" ] && [ ! -e "$REPO_DIR/staging_dir/$TC_NAME" ]; then
    echo -e "${BLUE}[*] Linking MIPS toolchain: $REPO_DIR/staging_dir/$TC_NAME -> $TC_DIR${NC}"
    ln -sfn "$TC_DIR" "$REPO_DIR/staging_dir/$TC_NAME"
fi

# 5. Check OpenWrt ImageBuilder components
echo -e "\n${BLUE}[*] Checking OpenWrt ImageBuilder components...${NC}"
if [ -f "$REPO_DIR/Makefile" ] && [ -f "$REPO_DIR/rules.mk" ]; then
    NEED_IB_DOWNLOAD=0
    if [ ! -f "$REPO_DIR/packages/Packages" ] || [ ! -x "$REPO_DIR/staging_dir/host/bin/mksquashfs4" ] || [ ! -f "$REPO_DIR/build_dir/target-mips_24kc_musl/linux-ar71xx_generic/dragino2-kernel.bin" ]; then
        NEED_IB_DOWNLOAD=1
    fi

    if [ "$NEED_IB_DOWNLOAD" -eq 1 ]; then
        echo -e "${YELLOW}[!] ImageBuilder host tools, packages, or kernel missing.${NC}"
        IB_CACHE_CANDIDATES=(
            "$OPENWRT_IB_TAR"
            "/home/hor/2026-gateway/openwrt-imagebuilder-18.06.9-ar71xx-generic.Linux-x86_64.tar.xz"
            "$HOME/2026-gateway/openwrt-imagebuilder-18.06.9-ar71xx-generic.Linux-x86_64.tar.xz"
            "$REPO_DIR/../openwrt-imagebuilder-18.06.9-ar71xx-generic.Linux-x86_64.tar.xz"
        )
        IB_ARCHIVE=""
        for c in "${IB_CACHE_CANDIDATES[@]}"; do
            if [ -n "$c" ] && [ -f "$c" ]; then
                IB_ARCHIVE="$c"
                break
            fi
        done

        if [ -z "$IB_ARCHIVE" ]; then
            IB_ARCHIVE="/tmp/openwrt-imagebuilder-18.06.9-ar71xx-generic.Linux-x86_64.tar.xz"
            IB_URL="https://archive.openwrt.org/releases/18.06.9/targets/ar71xx/generic/openwrt-imagebuilder-18.06.9-ar71xx-generic.Linux-x86_64.tar.xz"
            echo -e "${BLUE}[*] Downloading OpenWrt 18.06.9 ImageBuilder components from archive mirror...${NC}"
            wget -c --show-progress "$IB_URL" -O "$IB_ARCHIVE"
        fi

        echo -e "${BLUE}[*] Unpacking ImageBuilder host tools, packages, and Dragino kernels...${NC}"
        mkdir -p "$REPO_DIR/staging_dir/host" "$REPO_DIR/packages" "$REPO_DIR/build_dir/target-mips_24kc_musl/linux-ar71xx_generic"
        tar -xf "$IB_ARCHIVE" --strip-components=1 -C "$REPO_DIR" \
            openwrt-imagebuilder-18.06.9-ar71xx-generic.Linux-x86_64/staging_dir/host \
            openwrt-imagebuilder-18.06.9-ar71xx-generic.Linux-x86_64/packages \
            openwrt-imagebuilder-18.06.9-ar71xx-generic.Linux-x86_64/build_dir/target-mips_24kc_musl/linux-ar71xx_generic/dragino2-kernel.bin \
            openwrt-imagebuilder-18.06.9-ar71xx-generic.Linux-x86_64/build_dir/target-mips_24kc_musl/linux-ar71xx_generic/vmlinux \
            openwrt-imagebuilder-18.06.9-ar71xx-generic.Linux-x86_64/build_dir/target-mips_24kc_musl/linux-ar71xx_generic/vmlinux.bin.lzma \
            openwrt-imagebuilder-18.06.9-ar71xx-generic.Linux-x86_64/build_dir/target-mips_24kc_musl/linux-ar71xx_generic/vmlinux.elf
        [ "$IB_ARCHIVE" = "/tmp/openwrt-imagebuilder-18.06.9-ar71xx-generic.Linux-x86_64.tar.xz" ] && rm -f "$IB_ARCHIVE"
    fi
    echo -e "${GREEN}[+] ImageBuilder host tools, packages, and Dragino kernels ready.${NC}"
fi

# 6. Generate scripts/env.sh for persistent configuration
ENV_FILE="$SCRIPT_DIR/env.sh"
cat > "$ENV_FILE" <<EOF
# Source this file to set up MIPS cross-compilation environment
export TOOLCHAIN="${FOUND_TOOLCHAIN}"
export STAGING_DIR="${REPO_DIR}/staging_dir"
export PATH="${FOUND_TOOLCHAIN}:\$PATH"
export CROSS_COMPILE="mips-openwrt-linux-musl-"
EOF
chmod +x "$ENV_FILE"

echo -e "\n${GREEN}==================================================================${NC}"
echo -e "${GREEN}  Environment is fully configured and ready!                      ${NC}"
echo -e "${GREEN}==================================================================${NC}"
echo -e "Toolchain location: ${FOUND_TOOLCHAIN}"
echo -e "Environment file:   ${ENV_FILE}"
echo -e ""
echo -e "To activate the cross-compiler in your current shell session, run:"
echo -e "  ${YELLOW}source $(basename "$SCRIPT_DIR")/env.sh${NC} (or ${YELLOW}source scripts/env.sh${NC})"
echo -e ""
echo -e "Or export manually:"
echo -e "  export PATH=\"${FOUND_TOOLCHAIN}:\$PATH\""
echo -e "  export STAGING_DIR=\"${REPO_DIR}/staging_dir\""
echo -e "  export CROSS_COMPILE=mips-openwrt-linux-musl-"
echo ""
