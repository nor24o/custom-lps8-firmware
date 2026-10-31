#!/usr/bin/env bash
set -e

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

for t in "$ROOT_DIR/targets/sx1302/files" "$ROOT_DIR/targets/sx1276_lg01_lg02/files" "$ROOT_DIR/files_sx1276"; do
    echo "Syncing overlay to $t ..."
    mkdir -p "$t/usr/lib/lua/luci/controller/admin" \
             "$t/usr/lib/lua/luci/model/cbi/lora" \
             "$t/usr/lib/lua/luci/view/lora" \
             "$t/etc/config" \
             "$t/etc/init.d" \
             "$t/usr/bin" \
             "$t/www"
    
    cp -a "$ROOT_DIR/files/usr/lib/lua/luci/controller/lora.lua" "$t/usr/lib/lua/luci/controller/"
    cp -a "$ROOT_DIR/files/usr/lib/lua/luci/controller/admin/network.lua" "$t/usr/lib/lua/luci/controller/admin/"
    cp -a "$ROOT_DIR/files/usr/lib/lua/luci/model/cbi/lora/config.lua" "$t/usr/lib/lua/luci/model/cbi/lora/"
    cp -a "$ROOT_DIR/files/usr/lib/lua/luci/view/lora/status.htm" "$t/usr/lib/lua/luci/view/lora/"
    cp -a "$ROOT_DIR/files/usr/lib/lua/luci/view/lora/log.htm" "$t/usr/lib/lua/luci/view/lora/"
    cp -a "$ROOT_DIR/files/etc/config/lora" "$t/etc/config/"
    cp -a "$ROOT_DIR/files/usr/bin/lora_sync_config.sh" "$t/usr/bin/"
    [ -f "$ROOT_DIR/files/usr/bin/raw_lora_app" ] && cp -a "$ROOT_DIR/files/usr/bin/raw_lora_app" "$t/usr/bin/"
    [ -f "$ROOT_DIR/files/usr/bin/lg02_pkt_fwd" ] && cp -a "$ROOT_DIR/files/usr/bin/lg02_pkt_fwd" "$t/usr/bin/"
    [ -f "$ROOT_DIR/files/usr/bin/lg01_pkt_fwd" ] && cp -a "$ROOT_DIR/files/usr/bin/lg01_pkt_fwd" "$t/usr/bin/"
    [ -f "$ROOT_DIR/files/usr/bin/simple_spi_rw" ] && cp -a "$ROOT_DIR/files/usr/bin/simple_spi_rw" "$t/usr/bin/"
    [ -f "$ROOT_DIR/files/usr/bin/sx1276_app" ] && cp -a "$ROOT_DIR/files/usr/bin/sx1276_app" "$t/usr/bin/"
    cp -a "$ROOT_DIR/files/etc/init.d/lora_gateway" "$t/etc/init.d/"
    cp -a "$ROOT_DIR/files/www/index.html" "$t/www/"
    rm -rf "$t/www/cgi-bin"
done

echo "Overlay sync complete!"
