#!/usr/bin/env bash
set -e

SRC="/home/hor/2026-gateway/openwrt-imagebuilder-18.06.9-ar71xx-generic.Linux-x86_64"
DEST="/tmp/decoder_branch"

rm -rf "$DEST"/* "$DEST"/.* 2>/dev/null || true

mkdir -p "$DEST/gui/luci/controller"
mkdir -p "$DEST/gui/luci/model/cbi/lora"
mkdir -p "$DEST/gui/luci/view/lora"
mkdir -p "$DEST/gui/www/luci-static/resources"
mkdir -p "$DEST/gui/www/images"

mkdir -p "$DEST/pipeline"
mkdir -p "$DEST/decoder"
mkdir -p "$DEST/homeassistant"
mkdir -p "$DEST/standalone"

# 1. GUI
cp "$SRC/targets/sx1302/files/usr/lib/lua/luci/controller/lora.lua" "$DEST/gui/luci/controller/"
cp "$SRC/targets/sx1302/files/usr/lib/lua/luci/model/cbi/lora/config.lua" "$DEST/gui/luci/model/cbi/lora/"
cp "$SRC/targets/sx1302/files/usr/lib/lua/luci/view/lora"/* "$DEST/gui/luci/view/lora/"
cp "$SRC/targets/sx1302/files/www/luci-static/resources/lora_decoder.js" "$DEST/gui/www/luci-static/resources/"
cp -r "$SRC/targets/sx1302/files/www/images"/* "$DEST/gui/www/images/" 2>/dev/null || true

# 2. Pipeline
cp "$SRC/targets/sx1302/files/usr/bin/lora_linking_engine.lua" "$DEST/pipeline/"
cp "$SRC/standalone_decoder_ha/pipeline.lua" "$DEST/pipeline/"
cp "$SRC/targets/sx1302/files/usr/bin/lora_db_init.sh" "$DEST/pipeline/"
cp "$SRC/targets/sx1302/files/usr/bin/lora_keepalive.sh" "$DEST/pipeline/"
cp "$SRC/targets/sx1302/files/usr/bin/lora_sync_config.sh" "$DEST/pipeline/"

# 3. Decoder
cp "$SRC/standalone_decoder_ha/lora_decoder.lua" "$DEST/decoder/"
cp "$SRC/standalone_decoder_ha/decoders.json" "$DEST/decoder/"

# 4. Home Assistant
cp "$SRC/standalone_decoder_ha/ha_bridge.lua" "$DEST/homeassistant/"
cp "$SRC/targets/sx1302/files/usr/bin/lora_mqtt_bridge.lua" "$DEST/homeassistant/"

# 5. Standalone
cp -r "$SRC/standalone_decoder_ha"/* "$DEST/standalone/"

# 6. OpenWrt Drop-In Rootfs Overlay (files/)
mkdir -p "$DEST/files/etc/lora"
mkdir -p "$DEST/files/etc/init.d"
mkdir -p "$DEST/files/usr/bin"
mkdir -p "$DEST/files/usr/lib/lua/luci/controller"
mkdir -p "$DEST/files/usr/lib/lua/luci/model/cbi/lora"
mkdir -p "$DEST/files/usr/lib/lua/luci/view/lora"
mkdir -p "$DEST/files/www/luci-static/resources"
mkdir -p "$DEST/files/www/images"

cp "$SRC/targets/sx1302/files/etc/lora/config.json" "$DEST/files/etc/lora/"
cp "$SRC/standalone_decoder_ha/decoders.json" "$DEST/files/etc/lora/"
cp "$SRC/targets/sx1302/files/etc/init.d/lora_gateway" "$DEST/files/etc/init.d/"

cp "$SRC/targets/sx1302/files/usr/bin/lora_linking_engine.lua" "$DEST/files/usr/bin/"
cp "$SRC/targets/sx1302/files/usr/bin/lora_mqtt_bridge.lua" "$DEST/files/usr/bin/"
cp "$SRC/targets/sx1302/files/usr/bin/lora_db_init.sh" "$DEST/files/usr/bin/"
cp "$SRC/targets/sx1302/files/usr/bin/lora_keepalive.sh" "$DEST/files/usr/bin/"
cp "$SRC/targets/sx1302/files/usr/bin/lora_sync_config.sh" "$DEST/files/usr/bin/"
cp "$SRC/standalone_decoder_ha/lora_decoder.lua" "$DEST/files/usr/bin/"

cp "$SRC/standalone_decoder_ha/lora_decoder.lua" "$DEST/files/usr/lib/lua/"
cp "$SRC/standalone_decoder_ha/pipeline.lua" "$DEST/files/usr/lib/lua/"
cp "$SRC/standalone_decoder_ha/ha_bridge.lua" "$DEST/files/usr/lib/lua/"

cp "$DEST/gui/luci/controller/lora.lua" "$DEST/files/usr/lib/lua/luci/controller/"
cp "$DEST/gui/luci/model/cbi/lora/config.lua" "$DEST/files/usr/lib/lua/luci/model/cbi/lora/"
cp "$DEST/gui/luci/view/lora"/* "$DEST/files/usr/lib/lua/luci/view/lora/"
cp "$DEST/gui/www/luci-static/resources"/* "$DEST/files/www/luci-static/resources/"
cp -r "$DEST/gui/www/images"/* "$DEST/files/www/images/" 2>/dev/null || true

# 7. 1-Click Gateway Deployer script (deploy.sh)
cat << 'EOF' > "$DEST/deploy.sh"
#!/usr/bin/env bash
set -e

TARGET_IP="${1:-192.168.1.17}"
TARGET_USER="${2:-root}"
TARGET_PASS="${3:-root}"

echo "=================================================================="
echo " Deploying LoRa GUI, Pipeline, Decoder & HA to $TARGET_USER@$TARGET_IP"
echo "=================================================================="

# Check sshpass
if command -v sshpass >/dev/null 2>&1; then
    SSH_CMD="sshpass -p $TARGET_PASS ssh -o StrictHostKeyChecking=no"
    SCP_CMD="sshpass -p $TARGET_PASS scp -o StrictHostKeyChecking=no -r"
else
    SSH_CMD="ssh -o StrictHostKeyChecking=no"
    SCP_CMD="scp -o StrictHostKeyChecking=no -r"
fi

echo "[1/4] Uploading files/ overlay to gateway root..."
$SCP_CMD files/* "$TARGET_USER@$TARGET_IP:/"

echo "[2/4] Setting execution permissions..."
$SSH_CMD "$TARGET_USER@$TARGET_IP" "chmod +x /usr/bin/lora_* /etc/init.d/lora_gateway 2>/dev/null || true"

echo "[3/4] Purging LuCI web caches..."
$SSH_CMD "$TARGET_USER@$TARGET_IP" "rm -rf /tmp/luci-indexcache /tmp/luci-modulecache"

echo "[4/4] Restarting LoRa linking & HA bridge engine..."
$SSH_CMD "$TARGET_USER@$TARGET_IP" "/usr/bin/lora_keepalive.sh restart >/dev/null 2>&1 || true"

echo "=================================================================="
echo " Deployment successful! Open http://$TARGET_IP/cgi-bin/luci/admin/lora/decoder"
echo "=================================================================="
EOF
chmod +x "$DEST/deploy.sh"

# 8. .gitignore
cat << 'EOF' > "$DEST/.gitignore"
*.log
*.tmp
*.swp
*.bak
.DS_Store
EOF

# 9. Main README.md
cat << 'EOF' > "$DEST/README.md"
# LoRa Telemetry Pipeline, Decoder Studio & Home Assistant Integration

A complete, high-speed LoRa payload decoding pipeline, interactive LuCI Web GUI (Decoder Studio), and Home Assistant MQTT integration for Dragino LoRa gateways (LPS8 SX1302 and LG01/LG02 SX1276) and standalone edge devices.

---

## Architecture Overview

```mermaid
flowchart TD
    A["Raw LoRa Frame (SPI/Packet Forwarder)"] --> B{"Hardware CRC Gate"}
    B -- "CRC_BAD / Bit Errors" --> C["DROP IMMEDIATELY\n(No DB, No HA, Zero Overhead)"]
    B -- "CRC_OK" --> D["Multi-Scheme Decoder Engine\n(CTV, Cayenne LPP, Field Slicer, ASCII, JS)"]
    D --> E{"Zero Auto-Enrollment Gate\n(Node Defined & Approved?)"}
    E -- "Yes" --> F["Home Assistant MQTT Discovery & Telemetry (< 5ms)\nTopic: lora/<node_id>/state"]
    E -- "No" --> G["Hold as Discovery Candidate in GUI (No HA entity created)"]
    F --> H["Background Logging & Downlinks (SQLite RAM/Flash)"]
```

---

## Directory Structure

```
.
├── gui/                         # Complete LuCI Web GUI & Visual Slicer
│   ├── luci/
│   │   ├── controller/lora.lua  # REST APIs (decoders, packets, nodes, mqtt, downlinks)
│   │   ├── model/cbi/lora/      # Gateway config model
│   │   └── view/lora/           # HTML templates:
│   │       ├── decoder.htm      # LoRa Payload Decoder Studio (Multi-scheme editor & tester)
│   │       ├── status.htm       # Live Packet Stream & Real-time Traffic Inspector
│   │       ├── nodes.htm        # LoRa Node Registry & Home Assistant Enrolment Management
│   │       ├── config.htm       # Radio & MQTT Configuration
│   │       ├── diag.htm         # Spectrum & Diagnostics
│   │       └── log.htm          # System logs
│   └── www/
│       ├── luci-static/resources/lora_decoder.js  # Interactive Visual Byte Segmentation Engine
│       └── images/              # Hardware pinout & architectural diagrams
│
├── pipeline/                    # Telemetry Intake & Processing Pipeline
│   ├── lora_linking_engine.lua  # Ultra-low-latency linking, CRC gate & telemetry dispatcher
│   ├── pipeline.lua             # Pure Lua CRC gate & ingestion pipeline module
│   ├── lora_db_init.sh          # Dual SQLite database schema setup (Flash /etc/lora & RAM /tmp)
│   ├── lora_keepalive.sh        # Service supervisor & auto-respawn watchdog
│   └── lora_sync_config.sh      # Configuration synchronizer
│
├── decoder/                     # Multi-Scheme Payload Decoder
│   ├── lora_decoder.lua         # Multi-scheme decoding engine (CTV, Cayenne LPP, Field Slicer, ASCII)
│   └── decoders.json            # Active schemes specification (Node CAFE, Cayenne LPP, TLV, ASCII)
│
├── homeassistant/               # Home Assistant MQTT Integration
│   ├── ha_bridge.lua            # Tailored MQTT auto-discovery & instant telemetry dispatch
│   └── lora_mqtt_bridge.lua     # Gateway Device discovery, topology & downlink bridge
│
├── standalone/                  # Portable Standalone Service Runner
│   ├── service.lua              # CLI runner, daemon & file watcher (Runs on Pi, HA OS, PC, Docker)
│   ├── lora_decoder.lua         # Standalone decoder
│   ├── pipeline.lua             # Standalone pipeline
│   ├── ha_bridge.lua            # Standalone HA bridge
│   ├── decoders.json            # Decoder schemes
│   └── README.md                # Standalone documentation
│
├── files/                       # Ready-to-flash OpenWrt rootfs overlay tree
│   ├── etc/
│   ├── usr/
│   └── www/
│
├── deploy.sh                    # 1-Click live gateway deployer script
└── .gitignore
```

---

## 1-Click Gateway Deployment

Deploy the entire GUI, pipeline, decoder, and Home Assistant bridge directly to a running Dragino gateway over network:

```bash
chmod +x deploy.sh
./deploy.sh 192.168.1.17 root root
```

This installs all views, controllers, engines, and services, clears LuCI caches, and restarts the pipeline.

---

## Standalone Execution (External Device / Raspberry Pi / Docker)

To run the pipeline and decoding service remotely on another computer:

```bash
cd standalone
lua service.lua --watch /tmp/lora_packets.json --broker 192.168.1.13 --user admin --pass admin
```

Or test a single payload via CLI:

```bash
lua service.lua --hex CAFE96B840EB010201490271FFFB00180421036700B404880000000000000000
```
EOF

echo "Assembly completed successfully!"
