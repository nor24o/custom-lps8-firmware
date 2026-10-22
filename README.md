# Custom Dragino Firmware & Applications Repository

A streamlined, unified firmware build system and custom application stack for **Dragino LoRa Gateways** based on the Atheros AR9331 SoC (`ar71xx-generic`):
- **Dragino LPS8**: 8-Channel Multi-SF LoRaWAN Concentrator (Semtech SX1302 + SX1250)
- **Dragino LG02**: Dual-Channel LoRa Gateway (2x Semtech SX1276)
- **Dragino LG01**: Single-Channel LoRa Gateway (1x Semtech SX1276)

---

## 1. Repository & Branch Structure

This repository is organized into three git branches to provide both a unified master workspace and dedicated, clean per-device branches:

```
                      ┌────────────────────────────────────────┐
                      │              main branch               │
                      │  - Unified Build Dispatcher (build.sh) │
                      │  - Environment Setup (setup_env.sh)    │
                      │  - Master Documentation & Architecture │
                      │  - PC Test Console (run.py)            │
                      │  - Both Targets in targets/            │
                      └──────────────────┬─────────────────────┘
                                         │
                 ┌───────────────────────┴───────────────────────┐
                 ▼                                               ▼
┌───────────────────────────────────┐           ┌───────────────────────────────────┐
│           sx1302 branch           │           │     sx1276-lg01-lg02 branch       │
│  - Dragino LPS8 (8-Channel SX1302)│           │  - Dragino LG01 & LG02 (SX1276)   │
│  - libloragw HAL + raw_lora_app   │           │  - lg01_pkt_fwd & lg02_pkt_fwd    │
│  - 8-Channel Web GUI (Dark Mode)  │           │  - WiFi STA Web GUI (Dark Mode)   │
│  - Dedicated LPS8 Overlay & Image │           │  - Auto-probe SPI & Dual Bitbang  │
└───────────────────────────────────┘           └───────────────────────────────────┘
```

### Switching Branches:
- To switch to the LPS8 SX1302 branch:
  ```bash
  git checkout sx1302
  ```
- To switch to the LG01 / LG02 SX1276 branch:
  ```bash
  git checkout sx1276-lg01-lg02
  ```
- To switch back to main:
  ```bash
  git checkout main
  ```

---

## 2. Environment Setup (One-Step Script)

The repository provides an automated environment setup script that installs all host dependencies (`build-essential`, `gawk`, `zlib1g-dev`, `python3-pip`, `prompt_toolkit`, etc.) and verifies the MIPS cross-toolchain:

```bash
chmod +x scripts/setup_env.sh
./scripts/setup_env.sh
```

---

## 3. How to Build

### Option A: From `main` branch (Unified Builder)

```bash
# Build LPS8 (SX1302) apps and firmware image:
./build.sh sx1302

# Build LG01 / LG02 (SX1276) apps and firmware image:
./build.sh lg02

# Build both targets sequentially:
./build.sh all

# Compile only applications without building the firmware image:
./build.sh app sx1302
./build.sh app lg02

# Build only the OpenWrt image using existing overlay:
./build.sh image sx1302
./build.sh image lg02
```

### Option B: From Dedicated Target Branches

When on the `sx1302` or `sx1276-lg01-lg02` branch:
```bash
# Build everything for this target:
./build_all.sh

# Or build individually:
./build_app.sh    # Compiles app and stages into files/usr/bin/
./build_image.sh  # Generates openwrt-...-sysupgrade.bin
```

---

## 4. Built Images & Flash Locations

All firmware images are generated in:
`bin/targets/ar71xx/generic/openwrt-18.06.9-ar71xx-generic-dragino2-squashfs-sysupgrade.bin`

### Flashing to Gateway:
1. **Via SSH / SCP (Sysupgrade)**:
   ```bash
   scp bin/targets/ar71xx/generic/openwrt-18.06.9-ar71xx-generic-dragino2-squashfs-sysupgrade.bin root@192.168.1.11:/tmp/firmware.bin
   ssh root@192.168.1.11 "sysupgrade -n /tmp/firmware.bin"
   ```
2. **Via Web GUI**: Navigate to `http://192.168.1.x` and upload the `.bin` image under the upgrade section.
3. **Via U-Boot TFTP Recovery**: Set PC IP to `192.168.255.2`, connect ethernet, power on holding the reset button for 5 seconds, and flash via TFTP.

---

## 5. PC Testing & Monitor Console (`run.py`)

A Python interactive console is included to monitor uplinks, send immediate downlinks, and inspect heartbeats:

```bash
python3 run.py
```
- **Listening on**: UDP `:5555` (uplink from gateway)
- **Sending to**: UDP `:5556` (downlink to gateway)
- Interactive commands: `/help`, `/tx <hex_payload>`, `/stat`, `/clear`.

---

## 6. Technical Details & Specifications

For comprehensive hardware pinouts, GPIO definitions, SPI bus bitbang configurations, and wire protocol details, see [ARCHITECTURE.md](ARCHITECTURE.md).
