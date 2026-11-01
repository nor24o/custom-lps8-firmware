#!/usr/bin/env bash
# ==============================================================================
# download_utils.sh — Resilient Multi-Mirror Downloader & Archive Cache
# ==============================================================================

download_file() {
    local dest="$1"
    shift
    local urls=("$@")
    local dest_dir
    dest_dir="$(dirname "$dest")"
    mkdir -p "$dest_dir"

    local tmp_dest="${dest}.tmp.$$"
    rm -f "$tmp_dest"

    for url in "${urls[@]}"; do
        echo -e "\033[0;34m[*] Trying download from: ${url}...\033[0m" >&2
        # 1. Try wget with IPv4 only and progress to stderr
        if command -v wget >/dev/null 2>&1; then
            if wget --inet4-only --timeout=15 --tries=3 -c "$url" -O "$tmp_dest" >&2; then
                if [ -s "$tmp_dest" ]; then
                    mv "$tmp_dest" "$dest"
                    return 0
                fi
            fi
        fi

        # 2. Try curl with IPv4 only and progress to stderr
        if command -v curl >/dev/null 2>&1; then
            if curl -4 -L --connect-timeout 15 --retry 3 -f -C - -o "$tmp_dest" "$url" >&2; then
                if [ -s "$tmp_dest" ]; then
                    mv "$tmp_dest" "$dest"
                    return 0
                fi
            fi
        fi
        echo -e "\033[1;33m[!] Mirror failed or timed out. Trying next fallback mirror...\033[0m" >&2
        rm -f "$tmp_dest"
    done

    rm -f "$tmp_dest"
    return 1
}

get_openwrt_imagebuilder_tar() {
    local cache_dir="$HOME/.openwrt-cache"
    mkdir -p "$cache_dir"
    local cached_tar="$cache_dir/openwrt-imagebuilder-18.06.9-ar71xx-generic.Linux-x86_64.tar.xz"

    local candidate_tars=(
        "$OPENWRT_IB_TAR"
        "$cached_tar"
        "$HOME/.openwrt-sdk-mips_24kc/openwrt-imagebuilder-18.06.9-ar71xx-generic.Linux-x86_64.tar.xz"
        "/home/hor/2026-gateway/openwrt-imagebuilder-18.06.9-ar71xx-generic.Linux-x86_64.tar.xz"
        "$HOME/2026-gateway/openwrt-imagebuilder-18.06.9-ar71xx-generic.Linux-x86_64.tar.xz"
        "$(pwd)/../openwrt-imagebuilder-18.06.9-ar71xx-generic.Linux-x86_64.tar.xz"
        "/tmp/openwrt-imagebuilder-18.06.9-ar71xx-generic.Linux-x86_64.tar.xz"
    )

    for t in "${candidate_tars[@]}"; do
        if [ -n "$t" ] && [ -s "$t" ]; then
            echo "$t"
            return 0
        fi
    done

    local mirrors=(
        "https://downloads.openwrt.org/releases/18.06.9/targets/ar71xx/generic/openwrt-imagebuilder-18.06.9-ar71xx-generic.Linux-x86_64.tar.xz"
        "http://archive.openwrt.org/releases/18.06.9/targets/ar71xx/generic/openwrt-imagebuilder-18.06.9-ar71xx-generic.Linux-x86_64.tar.xz"
        "http://downloads.openwrt.org/releases/18.06.9/targets/ar71xx/generic/openwrt-imagebuilder-18.06.9-ar71xx-generic.Linux-x86_64.tar.xz"
    )

    echo -e "\033[0;34m[*] Downloading OpenWrt 18.06.9 ImageBuilder components (~275 MB)...\033[0m" >&2
    if download_file "$cached_tar" "${mirrors[@]}"; then
        echo "$cached_tar"
        return 0
    fi

    return 1
}

get_openwrt_malta_kernel() {
    local cache_dir="$HOME/.openwrt-sdk-mips_24kc"
    mkdir -p "$cache_dir"
    local kernel_elf="$cache_dir/openwrt-18.06.9-malta-be-vmlinux.elf"

    if [ -s "$kernel_elf" ]; then
        echo "$kernel_elf"
        return 0
    fi

    local mirrors=(
        "https://downloads.openwrt.org/releases/18.06.9/targets/malta/be/openwrt-18.06.9-malta-be-vmlinux.elf"
        "http://archive.openwrt.org/releases/18.06.9/targets/malta/be/openwrt-18.06.9-malta-be-vmlinux.elf"
        "http://downloads.openwrt.org/releases/18.06.9/targets/malta/be/openwrt-18.06.9-malta-be-vmlinux.elf"
    )

    echo -e "\033[0;34m[*] Downloading OpenWrt 18.06.9 MIPS Malta boot kernel (~5.8 MB)...\033[0m" >&2
    if download_file "$kernel_elf" "${mirrors[@]}"; then
        echo "$kernel_elf"
        return 0
    fi

    return 1
}

get_openwrt_sdk_tar() {
    local cache_dir="$HOME/.openwrt-cache"
    mkdir -p "$cache_dir"
    local cached_sdk="$cache_dir/openwrt-sdk-19.07.10-ar71xx-generic_gcc-7.5.0_musl.Linux-x86_64.tar.xz"

    local candidate_sdks=(
        "$cached_sdk"
        "/home/hor/giuthub/new/openwrt-sdk-19.07.10-ar71xx-generic_gcc-7.5.0_musl.Linux-x86_64.tar.xz"
        "/tmp/openwrt-sdk-19.07.10-ar71xx-generic_gcc-7.5.0_musl.Linux-x86_64.tar.xz"
    )

    for s in "${candidate_sdks[@]}"; do
        if [ -n "$s" ] && [ -s "$s" ]; then
            echo "$s"
            return 0
        fi
    done

    local mirrors=(
        "https://downloads.openwrt.org/releases/19.07.10/targets/ar71xx/generic/openwrt-sdk-19.07.10-ar71xx-generic_gcc-7.5.0_musl.Linux-x86_64.tar.xz"
        "http://archive.openwrt.org/releases/19.07.10/targets/ar71xx/generic/openwrt-sdk-19.07.10-ar71xx-generic_gcc-7.5.0_musl.Linux-x86_64.tar.xz"
        "http://downloads.openwrt.org/releases/19.07.10/targets/ar71xx/generic/openwrt-sdk-19.07.10-ar71xx-generic_gcc-7.5.0_musl.Linux-x86_64.tar.xz"
    )

    echo -e "\033[0;34m[*] Downloading OpenWrt MIPS 24Kc SDK (~73 MB)...\033[0m" >&2
    if download_file "$cached_sdk" "${mirrors[@]}"; then
        echo "$cached_sdk"
        return 0
    fi

    return 1
}
