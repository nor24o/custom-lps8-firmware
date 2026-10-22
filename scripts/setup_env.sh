#!/usr/bin/env bash
# ==============================================================================
# setup_env.sh — Environment Setup for Custom Dragino Firmware & Apps
# Supports: Dragino LPS8 (SX1302) & Dragino LG01 / LG02 (SX1276)
# Target Architecture: MIPS 24Kc (Atheros AR9331 / ar71xx-generic)
# ==============================================================================
set -e

GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

echo -e "${BLUE}==================================================================${NC}"
echo -e "${BLUE}  Dragino Custom Firmware Environment Setup (Ubuntu / WSL)        ${NC}"
echo -e "${BLUE}==================================================================${NC}"

# 1. Verify OS
if [ ! -f /etc/os-release ]; then
    echo -e "${RED}[ERROR] Unsupported OS. Expected Ubuntu / Debian Linux.${NC}"
    exit 1
fi
source /etc/os-release
echo -e "${GREEN}[+] Detected OS: ${NAME} ${VERSION_ID}${NC}"

# 2. Install required packages
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
    unzip
    python3
    python3-pip
    file
    sshpass
    tree
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

# 3. Install Python dependencies for test console (run.py)
echo -e "\n${BLUE}[*] Checking Python dependencies (prompt_toolkit)...${NC}"
if ! python3 -c "import prompt_toolkit" 2>/dev/null; then
    echo -e "${YELLOW}[!] Installing prompt_toolkit...${NC}"
    pip3 install prompt_toolkit
else
    echo -e "${GREEN}[+] Python prompt_toolkit is installed.${NC}"
fi

# 4. Check OpenWrt Cross-Toolchain
echo -e "\n${BLUE}[*] Checking OpenWrt MIPS cross-toolchain...${NC}"
CANDIDATE_TOOLCHAINS=(
    "/home/hor/openwrt/openwrt/staging_dir/toolchain-mips_24kc_gcc-7.5.0_musl/bin"
    "$HOME/openwrt/openwrt/staging_dir/toolchain-mips_24kc_gcc-7.5.0_musl/bin"
    "/home/hor/giuthub/new/openwrt-sdk-19.07.10-ar71xx-generic_gcc-7.5.0_musl.Linux-x86_64/staging_dir/toolchain-mips_24kc_gcc-7.5.0_musl/bin"
)

FOUND_TOOLCHAIN=""
for tc in "${CANDIDATE_TOOLCHAINS[@]}"; do
    if [ -x "$tc/mips-openwrt-linux-musl-gcc" ] || [ -x "$tc/mips-openwrt-linux-gcc" ]; then
        FOUND_TOOLCHAIN="$tc"
        break
    fi
done

if [ -n "$FOUND_TOOLCHAIN" ]; then
    echo -e "${GREEN}[+] Found MIPS toolchain at: ${FOUND_TOOLCHAIN}${NC}"
    GCC_BIN="$FOUND_TOOLCHAIN/mips-openwrt-linux-musl-gcc"
    [ -x "$GCC_BIN" ] || GCC_BIN="$FOUND_TOOLCHAIN/mips-openwrt-linux-gcc"
    echo -e "    GCC version: $($GCC_BIN --version | head -n 1)"
else
    echo -e "${RED}[ERROR] OpenWrt MIPS toolchain not found in candidate paths!${NC}"
    echo -e "Please ensure OpenWrt SDK or buildroot toolchain is installed."
    exit 1
fi

# 5. Check ImageBuilder
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
echo -e "\n${BLUE}[*] Checking OpenWrt ImageBuilder...${NC}"
if [ -f "$REPO_DIR/Makefile" ] && [ -f "$REPO_DIR/rules.mk" ] && [ -d "$REPO_DIR/scripts" ]; then
    echo -e "${GREEN}[+] ImageBuilder detected in: ${REPO_DIR}${NC}"
else
    echo -e "${YELLOW}[!] Warning: ImageBuilder Makefile not found at: ${REPO_DIR}${NC}"
fi

echo -e "\n${GREEN}==================================================================${NC}"
echo -e "${GREEN}  Environment is fully configured and ready!                      ${NC}"
echo -e "${GREEN}==================================================================${NC}"
echo -e "To compile applications manually, set:"
echo -e "  export PATH=\"${FOUND_TOOLCHAIN}:\$PATH\""
echo -e "  export STAGING_DIR=\"$(dirname "$FOUND_TOOLCHAIN")\""
echo -e "  export CROSS_COMPILE=mips-openwrt-linux-musl-"
echo ""
