# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

SX1302 HAL — a Semtech-authored C library (`libloragw`) and packet forwarder for LoRa gateway hardware based on the SX1302 concentrator chip. Supports SPI and USB interfaces. The packet forwarder bridges LoRa RF packets to a network server via UDP.

## Build Commands

```bash
# Build everything (from repo root)
make clean all

# Build only the HAL library
cd libloragw && make clean all

# Build only the packet forwarder
cd packet_forwarder && make clean all

# Deploy to target gateway via SSH/SCP (requires target.cfg)
make install          # deploy binaries
make install_conf     # deploy configuration files
```

### Cross-compilation (e.g. Raspberry Pi ARM)

```bash
export PATH=[toolchain_path]/arm-bcm2708/gcc-linaro-arm-linux-gnueabihf-raspbian-x64/bin:$PATH
export ARCH=arm
export CROSS_COMPILE=arm-linux-gnueabihf-
make clean all
```

### Build configuration

- `target.cfg` — deployment target: `TARGET_IP`, `TARGET_DIR`, `TARGET_USR`
- `libloragw/library.cfg` — per-module debug flags (all default 0)
- `libloragw/inc/config.h` — auto-generated from `VERSION` + `library.cfg` at build time; do not edit manually

## Running Tests

Test binaries are built into `libloragw/` alongside the library. They must be run on actual hardware (SX1302 concentrator). Examples:

```bash
# HAL-level RX/TX tests
./test_loragw_hal_rx
./test_loragw_hal_tx

# Communication and register tests
./test_loragw_com
./test_loragw_reg

# Radio-specific tests
./test_loragw_com_sx1250
./test_loragw_com_sx1261

# Other tests
./test_loragw_i2c
./test_loragw_cal_sx125x
./test_loragw_counter
./test_loragw_gps
./test_loragw_toa
./test_loragw_sx1261_rssi
```

## Running the Packet Forwarder

```bash
cd packet_forwarder
./lora_pkt_fwd -c global_conf.json.sx1250.EU868   # pick region-specific config
```

Region configs: `EU868`, `US915`, `CN490`, `AS923` variants in `packet_forwarder/`.

## Architecture

```
RF hardware (SX1302 + SX1250/SX1255/SX1257 radios)
              |
    SPI or USB interface
              |
     libloragw (HAL library) ← static lib, linked by all apps
       /          \
packet_forwarder   util_* / test_*
(gateway daemon)   (standalone utilities)
```

### libloragw layers

**HAL API** (`loragw_hal.c`) — the single public entry point for applications. Key functions: `lgw_board_setconf()`, `lgw_rxrf_setconf()`, `lgw_start()`, `lgw_receive()`, `lgw_send()`, `lgw_stop()`, `lgw_spectral_scan_*()`.

**Chip control** — `loragw_sx1302.c` (largest file, ~117 KB) drives the concentrator; `loragw_sx1302_rx.c` handles RX path; `loragw_sx1302_timestamp.c` handles internal counter/timestamp.

**Radio drivers** — `loragw_sx1250.c`, `loragw_sx125x.c`, `loragw_sx1261.c` implement radio-specific init and calibration; `loragw_cal.c` contains calibration sequences; `loragw_lbt.c` implements Listen-Before-Talk for AS923.

**Communication abstraction** — `loragw_com.c` wraps SPI (`loragw_spi.c`) and USB (`loragw_usb.c` + `loragw_mcu.c`). The USB path goes through an STM32 MCU bridge; its firmware binary is in `mcu_bin/`.

**Peripherals** — `loragw_i2c.c` (I2C bus), `loragw_gps.c` (NMEA parsing), `loragw_stts751.c` (temperature sensor), `loragw_ad5338r.c` (DAC).

**Register map** — `loragw_reg.c` (~114 KB) provides named register access over the communication layer.

**Firmware blobs** — AGC and arbitration firmware for SX1250/SX1257 are embedded as `.var` files included at compile time.

### Third-party libraries (`libtools/`)

- **parson** — JSON parsing (used by packet forwarder)
- **base64** — encoding for uplink payloads
- **tinymt32** — PRNG for test payload generation

### packet_forwarder

Multi-threaded daemon (`lora_pkt_fwd.c`, ~171 KB). Threads: uplink (RX → UDP), downlink (UDP → TX), GPS sync, JIT scheduler. `jitqueue.c` manages the TX timing queue. Configured via `global_conf.json` (server addresses, channel plan, GPS, NTP).

### Utilities

| Directory | Purpose |
|-----------|---------|
| `util_chip_id/` | Read SX1302 EUI for gateway identification |
| `util_boot/` | Switch STM32 MCU into USB DFU mode for firmware update |
| `util_net_downlink/` | Inject test downlinks and log uplinks |
| `util_spectral_scan/` | Spectral scan via SX1261 radio |
| `tools/` | `reset_lgw.sh` (GPIO reset script), systemd service files, Node-RED config |

## Code Conventions

- ANSI C (C99), no C++ 
- Public API declared in `libloragw/inc/loragw_hal.h`; internal module headers also in `inc/`
- Error returns: `LGW_HAL_SUCCESS` (0) / `LGW_HAL_ERROR` (-1) pattern used throughout
- Debug output gated by per-module `DEBUG_*` macros set in `library.cfg`
