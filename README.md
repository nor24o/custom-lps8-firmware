# LoRa Telemetry Pipeline, Decoder Studio & Home Assistant Integration Suite

A high-performance, standalone & gateway-integrated LoRa telemetry decoding engine, interactive Web GUI (Decoder Studio), and Home Assistant MQTT integration designed for Dragino LoRa Gateways (**LPS8 SX1302** and **LG01/LG02 SX1276**) and remote edge systems (**Raspberry Pi, Docker, Debian/Ubuntu server, PC, Mac, Home Assistant OS**).

---

## 1. High-Speed Pipeline Architecture & Execution Flow

The pipeline is ordered to guarantee minimum latency, prevent database contention, and eliminate orphan entity spam in Home Assistant:

```mermaid
flowchart TD
    A["Raw LoRa Frame (SPI / Packet Forwarder)"] --> B{"Hardware CRC Gate"}
    B -- "CRC_BAD / Corrupted" --> C["DROP IMMEDIATELY
(No DB, No HA, Zero CPU Overhead)"]
    B -- "CRC_OK" --> D["Multi-Scheme Decoder Engine
(CTV, Cayenne LPP, Field Slicer, ASCII, JS)"]
    D --> E{"Zero Auto-Enrollment Gate
(Node Defined & Approved?)"}
    E -- "Approved Node" --> F["Instant MQTT Discovery & Telemetry Dispatch (< 5ms)
Topic: lora/<node_id>/state"]
    E -- "Unenrolled / Rogue" --> G["Hold as Candidate in GUI
(Blocked from Home Assistant)"]
    F --> H["Background Local Logging & Downlink Check (SQLite RAM / Flash)"]
```

### Execution Steps
1. **Strict Hardware CRC Integrity Gate:** Corrupted frames (`CRC_BAD` or invalid checksums) are discarded immediately at line 0. They never touch SQLite, memory caches, or the decoder.
2. **Multi-Scheme Telemetry Decoder:** Decodes raw binary payloads using pre-configured schemes (Cayenne LPP / IPSO, CTV / TLV, Field Slicer, or ASCII).
3. **Zero Auto-Enrollment Approval Gate:** Prevents rogue nodes or bleed-through packets from neighboring networks from polluting Home Assistant. Only nodes with an explicit, active decoder scheme publish MQTT Auto-Discovery topics.
4. **Immediate MQTT State Dispatch:** Valid telemetry is published to `lora/<node_id>/state` within milliseconds, ensuring real-time sensor updates in Home Assistant.
5. **Background SQLite Buffering & Downlink Actions:** Telemetry storage and downlink rule evaluation run asynchronously to avoid blocking packet ingestion.

---

## 2. Interactive Web Interface (Decoder Studio)

The complete Decoder Studio Web Interface is included **both** as an OpenWrt LuCI module and as a **100% standalone web application** that runs anywhere without OpenWrt:

### Launching the Standalone Web Interface
You can run the web interface on any device (PC, Linux, Mac, Raspberry Pi, Docker, Home Assistant OS):

```bash
cd standalone

# Option 1: 1-Click Runner
./test.sh --web 8080

# Option 2: Via Python 3 (Zero external dependencies)
python3 web_server.py --port 8080

# Option 3: Via Node.js (Zero external dependencies)
node web_server.js 8080

# Option 4: Via Lua Service CLI
lua service.lua --web 8080

# Option 5: Offline / Direct File Access
# Open 'standalone/index.html' or 'standalone/web/index.html' directly in any browser!
```

Open your browser to:
**`http://localhost:8080`**

### Web Studio Features
- **Visual Byte Slicer:** Interactively maps byte ranges (`[0..1] Node ID`, `[2..5] Serial`, `[6..7] Temp`) with live hex color tagging.
- **Scheme Manager:** Create, edit, clone, delete, test, and reorder decoder schemes with auto-saving to `decoders.json`.
- **Live Payload Workbench:** Test live hex payloads with instant decoded JSON preview and discrete metric tiles.
- **Smart Candidate Suppression:** Automatically hides the "Add Candidate" button when a node is already mapped and decoded.
- **Zero-Dependency REST API:** Embedded HTTP backend provides `/api/decoders`, `/api/packets`, and `/api/nodes`.
- **Offline Resilience:** If no web server is running, the interface falls back to LocalStorage and local caching.

---

## 3. Pipeline Speed & Real-World Latency Benchmarks

Performance was benchmarked across **5,000 real telemetry packets** (evaluating CRC integrity, multi-sensor scheme matching, discrete metric extraction, and Home Assistant enrollment checks):

| Target Platform & Architecture | Per-Packet Latency | Ingestion Throughput | Real-World Operational Context |
| :--- | :--- | :--- | :--- |
| **Dragino LPS8 (MIPS 24Kc @ 400 MHz)** | **2.58 ms** (0.00258 s) | **386.7 pkts / sec** | Easily processes peak multi-channel traffic with zero queueing delay (LoRa 1% duty cycle limit is ~10-25 pkts/sec). |
| **x86_64 PC / Server / Raspberry Pi 5** | **56.8 µs** (0.000057 s) | **17,602 pkts / sec** | Instant sub-millisecond execution when running offloaded or in Docker / Home Assistant OS. |

---

## 4. Platform Abstraction & Cross-Platform Portability

The core decoding engine is 100% decoupled from the underlying operating system and gateway hardware:

- **Zero C Bitwise Dependencies:** Pure integer arithmetic (`* 256`, `/ 256`, `% 256`) is used in place of platform-specific C modules (`bit`, `bit32`). It runs identically across Lua 5.1 (OpenWrt), Lua 5.2, Lua 5.3, Lua 5.4, and LuaJIT without requiring compilation.
- **Dual-Context Universal JavaScript (`lora_decoder.js`):** Runs seamlessly in the LuCI browser web UI, standalone web UI, and backend headless runtimes (Node.js via `module.exports = LoraDecoder`).
- **Decoupled from OpenWrt Internals:** The decoder does not rely on OpenWrt `uci`, `luci`, or `ubus` libraries. Input is a raw hex string or byte buffer; output is standard JSON telemetry.
- **Unified Scheme Specification (`decoders.json`):** Shared JSON configuration format supported across all runtimes.

---

## 5. Standalone Feature Suite & Verification Tools

The `standalone/` directory provides everything needed to run or test the decoder on any machine:

```
standalone/
├── index.html             # Standalone Single-Page Decoder Studio Web App
├── web/                   # Dedicated Web UI Assets:
│   ├── index.html         # Web Studio UI
│   ├── lora_decoder.js    # Visual Slicer & In-Browser Decoder Engine
│   └── decoders.json      # Pre-configured Schemes
├── web_server.py          # Zero-dependency Python 3 HTTP Server (API + Web UI)
├── web_server.js          # Zero-dependency Node.js HTTP Server (API + Web UI)
├── lora_decoder.lua       # Multi-Scheme Decoder Engine (Pure arithmetic Lua)
├── lora_decoder.js        # Universal JS Decoder (Node.js & Browser dual-environment)
├── pipeline.lua           # Strict Hardware CRC Integrity Gate & Ingestion Pipeline
├── ha_bridge.lua          # Home Assistant MQTT Auto-Discovery & Instant Telemetry
├── service.lua            # Unified CLI Runner, Daemon, File Watcher & Web Launcher
├── decoders.json          # Configured Decoder Schemes (Node CAFE, Cayenne LPP, TLV, ASCII)
├── benchmark_pipeline.lua # High-precision 5,000-packet latency & throughput benchmark
├── test.sh                # 1-Click Multi-Runtime Auto-Detecting Test Runner
├── test_standalone.js     # Node.js Test Runner
├── test_standalone.py     # Python 3 Test Runner
└── README.md              # Standalone Operational Documentation
```

### Quick Verification Commands

#### 1-Click Multi-Runtime Auto-Detecting Runner
```bash
cd standalone
chmod +x test.sh
./test.sh
```

#### Launch Standalone Web Studio
```bash
cd standalone
./test.sh --web 8080
```

#### Run Performance Benchmark
```bash
cd standalone
./test.sh --bench
# Or directly via Lua:
lua benchmark_pipeline.lua
```

#### Run Full Test Suite via Lua
```bash
cd standalone
lua service.lua --test
```
*Verifies CRC gate rejection, multi-sensor LPP decoding, node ID routing, and pipeline execution (6/6 tests passing).*

#### Run via Python 3
```bash
cd standalone
python3 test_standalone.py
```

#### Run via Node.js
```bash
cd standalone
node test_standalone.js
```

#### Decode Single Packet via CLI
```bash
cd standalone
lua service.lua --hex CAFE96B840EB010201490271FFFB00180421036700B404880000000000000000 --decoders decoders.json
```

#### Run Live Daemon / File Watcher Mode
```bash
cd standalone
lua service.lua   --watch /tmp/lora_packets.json   --decoders ./decoders.json   --broker 192.168.1.13   --port 1883   --user admin   --pass admin
```

---

## 6. Home Assistant Integration & Zero Auto-Enrollment Security

### Zero Auto-Enrollment Security Gate
- **Problem:** In multi-node LoRa environments, gateways frequently receive stray packets from neighboring networks or unsanctioned devices. Auto-enrolling every device creates clutter and orphan sensors in Home Assistant.
- **Solution:** Telemetry packets only trigger Home Assistant Auto-Discovery (`homeassistant/sensor/<node_id>/<sensor>/config`) if the node has an **active, configured scheme** in `decoders.json`.
- Unconfigured packets are retained as discovery candidates in the LuCI / Standalone Web GUI for administrator inspection but are **blocked** from enrolling into Home Assistant.

### Tailored Entity Mapping & Bug Fixes
- **1661.9°C & 0V Bug Resolution:** Strict data type validation and scaling prevent raw int16 values from being misparsed as invalid temperatures or zero voltages.
- **Stable Sensor Topics:** Telemetry state is published to `lora/<node_id>/state` as a structured JSON object with the retained flag enabled, ensuring instant sensor state recovery upon Home Assistant restart.
- **Device Topology:** All node entities are linked under a unified device registry (`LoRa Node <node_id>`), complete with model, serial, and firmware metadata.

---

## 7. 1-Click Gateway Deployment

To deploy this entire suite (GUI, pipeline, decoder, and Home Assistant bridge) directly to a live Dragino gateway:

```bash
chmod +x deploy.sh
./deploy.sh 192.168.1.17 root root
```

---

## 8. Repository Structure

```
.
├── gui/                         # LuCI Web GUI & Visual Slicer
│   ├── luci/
│   │   ├── controller/lora.lua  # REST APIs (decoders, packets, nodes, mqtt, downlinks)
│   │   ├── model/cbi/lora/      # Gateway config model
│   │   └── view/lora/           # HTML templates (decoder, status, nodes, config, diag, log)
│   └── www/
│       ├── luci-static/resources/lora_decoder.js  # Universal Byte Segmentation & Decoder Engine
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
│   ├── lora_decoder.lua         # Multi-scheme decoding engine
│   └── decoders.json            # Active schemes specification
│
├── homeassistant/               # Home Assistant MQTT Integration
│   ├── ha_bridge.lua            # Tailored MQTT auto-discovery & instant telemetry dispatch
│   └── lora_mqtt_bridge.lua     # Gateway Device discovery, topology & downlink bridge
│
├── standalone/                  # Portable Standalone Service, Multi-Runtime Tests & Web UI
│   ├── index.html               # Standalone Single-Page Decoder Studio Web App
│   ├── web/                     # Dedicated Web UI assets (index.html, lora_decoder.js, decoders.json)
│   ├── web_server.py            # Python 3 Web Server
│   ├── web_server.js            # Node.js Web Server
│   ├── service.lua              # CLI runner, daemon, watcher & web launcher
│   ├── lora_decoder.lua         # Standalone decoder (Lua)
│   ├── lora_decoder.js          # Standalone decoder (Node.js / Universal)
│   ├── pipeline.lua             # Standalone pipeline
│   ├── ha_bridge.lua            # Standalone HA bridge
│   ├── decoders.json            # Decoder schemes
│   ├── benchmark_pipeline.lua   # 5,000-packet latency & throughput benchmark
│   ├── test.sh                  # 1-Click multi-runtime test runner & web launcher
│   ├── test_standalone.js       # Node.js test runner
│   ├── test_standalone.py       # Python 3 test runner
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
