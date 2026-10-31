#!/usr/bin/env bash
set -e

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROOTFS="$ROOT_DIR/build_dir/target-mips_24kc_musl/root-ar71xx"

echo "Checking Lua syntax of controller..."
qemu-mips -L "$ROOTFS" "$ROOTFS/usr/bin/lua" -e '
    local chunk, err = loadfile("files/usr/lib/lua/luci/controller/lora.lua")
    if not chunk then
        print("SYNTAX ERROR in lora.lua:", err)
        os.exit(1)
    end
    print("✓ lora.lua syntax is valid")
'

echo "Checking Lua syntax of model CBI..."
qemu-mips -L "$ROOTFS" "$ROOTFS/usr/bin/lua" -e '
    local chunk, err = loadfile("files/usr/lib/lua/luci/model/cbi/lora/config.lua")
    if not chunk then
        print("SYNTAX ERROR in config.lua:", err)
        os.exit(1)
    end
    print("✓ config.lua syntax is valid")
'

echo "Checking Lua syntax of streamlined network.lua..."
qemu-mips -L "$ROOTFS" "$ROOTFS/usr/bin/lua" -e '
    local chunk, err = loadfile("files/usr/lib/lua/luci/controller/admin/network.lua")
    if not chunk then
        print("SYNTAX ERROR in network.lua:", err)
        os.exit(1)
    end
    print("✓ network.lua syntax is valid")
'

echo "All Lua files validated successfully!"
