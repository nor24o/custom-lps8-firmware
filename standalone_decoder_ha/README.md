# Standalone LoRa Decoder, Pipeline & Home Assistant Feature

A high-performance, standalone LoRa telemetry decoding engine and Home Assistant MQTT integration pipeline. Built in pure, portable Lua with zero external runtime dependencies. Designed to run directly on the LoRa Gateway or run remotely on a Raspberry Pi, Debian/Ubuntu server, Docker container, or Home Assistant OS.

---

## Architecture & Directory Contents

```
standalone_decoder_ha/
├── lora_decoder.lua   # Multi-Scheme Decoder Engine (CTV/TLV, Cayenne LPP, Field Slicer, ASCII, JS)
├── pipeline.lua       # Strict Hardware CRC Integrity Gate & Telemetry Ingestion Pipeline
├── ha_bridge.lua      # Home Assistant MQTT Auto-Discovery & Instant Telemetry Dispatch
├── service.lua        # Unified CLI Runner, Daemon & File Watcher Service
├── decoders.json      # Configured Decoder Schemes (Node CAFE, Cayenne LPP, Standard TLV, ASCII)
└── README.md          # Architecture & Operational Documentation
```

---

## Telemetry Pipeline Execution Order

To guarantee minimum latency and prevent database locking:

```
[ Raw LoRa Packet ]
         │
         ▼
[ Strict CRC Gate ] ───(CRC != OK)───► [ DROP IMMEDIATELY ] (No DB, No HA, No CPU wasted)
         │
         ▼ (CRC_OK)
[ LoraDecoder Engine ] ──────────────► Match Scheme & Extract Discrete Metrics
         │
         ▼
[ Zero-Enrollment Gate ] ─────────────► Verify Node has Defined Custom Scheme / Approval
         │
         ▼ (Approved)
[ Immediate MQTT Telemetry ] ────────► Sub-5ms dispatch to `lora/<node_id>/state`
         │
         ▼ (Background / Optional)
[ SQLite & Downlink Checks ] ────────► Rolling RAM buffer & Downlink triggers
```

---

## Quick Start & Usage

### 1. Run Self-Test Suite
```bash
lua service.lua --test
```
Verifies CRC gate rejection, multi-sensor LPP decoding, node ID extraction, and pipeline condition checks.

### 2. Decode a Single Raw Payload (CLI Mode)
```bash
lua service.lua --hex CAFE96B840EB010201490271FFFB00180421036700B404880000000000000000 --decoders decoders.json
```
**Output:**
```json
{
  "node_id": "CAFE",
  "scheme_id": "scheme_node_cafe",
  "status": "SUCCESS",
  "ha_enrolled": true,
  "metrics": {
    "node_id": "CAFE",
    "temperature": 18.0,
    "battery": 3.29,
    "accel_x": -0.005,
    "accel_y": 0.024,
    "accel_z": 1.057,
    "device_serial": "96B840EB"
  }
}
```

### 3. Run Live Service / File Watcher (Daemon Mode)
Watches the gateway packet buffer, decodes incoming packets, and publishes immediately to Home Assistant Mosquitto broker:
```bash
lua service.lua \
  --watch /tmp/lora_packets.json \
  --decoders ./decoders.json \
  --broker 192.168.1.13 \
  --port 1883 \
  --user admin \
  --pass admin
```

### 4. Running Remotely (External Device / Raspberry Pi / Docker)
You can copy this entire `standalone_decoder_ha/` folder to any other computer:
```bash
scp -r standalone_decoder_ha user@raspberrypi:/opt/
```
Then run with `lua service.lua`. The pipeline uses standard `mosquitto_pub` or Lua sockets to communicate with the Home Assistant MQTT broker.

---

## Home Assistant Zero Auto-Enrollment Security

By default, **only nodes that have a configured, matching decoder scheme** in `decoders.json` are permitted to publish Home Assistant MQTT Auto-Discovery topics.

Random bleed-through packets from neighboring networks or unmatched devices are processed for diagnostics but are **blocked** from enrolling entities into Home Assistant, keeping your Home Assistant dashboard 100% clean and free of orphan entities.
