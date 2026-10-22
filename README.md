# Dragino LPS8 Custom Firmware & SX1302 HAL Application

This branch/target contains the complete custom firmware, rootfs overlay, and application stack for the **Dragino LPS8** (and SX1302 concentrator variants) powered by the Qualcomm Atheros AR9331 SoC.

---

## 1. Hardware Architecture & Interfaces

- **SoC**: Atheros AR9331 (MIPS 24Kc @ 400 MHz, 64 MB RAM, 16 MB Flash)
- **Concentrator**: Semtech SX1302 (8 Multi-SF channels + SX1250 RF frontends)
- **SPI Bus**: `/dev/spidev1.0` (handled by kernel `spi-gpio-custom` or hardware SPI)
- **Reset GPIO**: `GPIO 23`
- **PA/LNA Switch**: LED / GPIO `dragino2:red:wan` (configurable active-high or active-low in `config.json`)

---

## 2. Directory Structure

```
.
├── build_app.sh           # Cross-compiles libtools, libloragw.a, and raw_lora_app
├── build_image.sh         # Generates OpenWrt sysupgrade.bin using ImageBuilder
├── build_all.sh           # Builds both app and complete firmware image
├── src/                   # SX1302 HAL library & application source code
│   ├── libloragw/         # Semtech SX1302 hardware abstraction library
│   ├── libtools/          # Auxiliary JSON (parson), base64, PRNG libraries
│   ├── packet_forwarder/  # Standard Semtech forwarder
│   ├── raw_lora_app.c     # Optimized custom UDP forwarder with PA control & heartbeat
│   ├── run.py             # PC terminal monitor & injector (prompt_toolkit)
│   └── config.json.example# Hardware configuration reference
└── files/                 # Target Rootfs Overlay (injected into SquashFS)
    ├── etc/
    │   ├── config/        # network, system, uhttpd, dropbear
    │   ├── init.d/        # raw_lora_app (procd service daemon)
    │   ├── lora/          # config.json (SX1302 8-channel plan + RF frontend)
    │   └── modules.d/     # 30-spi-gpio-custom (SX1302 SPI bus)
    ├── usr/bin/           # raw_lora_app, reset_lgw.sh, net_watchdog.sh
    └── www/               # Custom Dark Web GUI & CGI scripts (config, status, logs)
```

---

## 3. Operating System & Tool Requirements

### Supported Host OS
- **Recommended**: **Ubuntu 18.04 LTS (Bionic Beaver)** 64-bit (Native Linux or WSL / WSL2)
- **Compatible**: **Ubuntu 20.04 LTS (Focal Fossa)** 64-bit
- *Note:* Ubuntu 18.04/20.04 is recommended because OpenWrt 18.06.9 ImageBuilder uses host-compiled utilities (`mksquashfs4`, `opkg`, `mkimage`) linked against glibc 2.27/2.31.

### Required Host Tools & Packages
Run the following command to install all necessary packages via `apt`:
```bash
sudo apt-get update && sudo apt-get install -y \
    build-essential \
    gawk \
    git \
    subversion \
    libncurses5-dev \
    zlib1g-dev \
    libssl-dev \
    xsltproc \
    rsync \
    wget \
    unzip \
    file \
    sshpass \
    tree \
    python3 \
    python3-pip \
    python3-distutils
```

### Python Dependencies (for PC Test Console `run.py`)
```bash
pip3 install prompt_toolkit
```

### Cross-Compilation Toolchain
The applications are built for the Atheros AR9331 SoC (**MIPS 24Kc**, musl libc):
- **Toolchain**: `mips-openwrt-linux-musl-gcc` (GCC 7.5.0 / musl)
- **Default Path**: `/home/hor/openwrt/openwrt/staging_dir/toolchain-mips_24kc_gcc-7.5.0_musl/bin`
- Or specify via environment variable:
  ```bash
  export TOOLCHAIN=/path/to/staging_dir/toolchain-mips_24kc_gcc-7.5.0_musl/bin
  ```

### Automated One-Step Setup Script
The repository includes an automated setup script that verifies the OS, installs missing apt packages, sets up Python dependencies, and confirms toolchain availability:
```bash
chmod +x scripts/setup_env.sh
./scripts/setup_env.sh
```

---

## 4. How to Build

### Quick Build (App + Firmware Image)
```bash
chmod +x build_all.sh build_app.sh build_image.sh
./build_all.sh
```

### Build Only the Application
```bash
./build_app.sh
```
The compiled binary `raw_lora_app` is placed in `src/` and staged into `files/usr/bin/raw_lora_app`.

### Build Only the OpenWrt Image
```bash
./build_image.sh
```
The resulting firmware is generated in:
`bin/targets/ar71xx/generic/openwrt-18.06.9-ar71xx-generic-dragino2-squashfs-sysupgrade.bin`

---

## 5. Configuration (`/etc/lora/config.json`)

```json
{
    "target_ip": "192.168.1.8",
    "port_up": 5555,
    "port_down": 5556,
    "status_port": 5557,
    "heartbeat_interval_s": 10,
    "spi_path": "/dev/spidev1.0",
    "reset_gpio": "23",
    "pa_gpio": "dragino2:red:wan",
    "pa_gpio_active_high": false,
    "clksrc": 0,
    "sync_word": "private"
}
```

---

## 6. Web Interface

The firmware includes a web GUI on port 80:
- **Status Tab**: Real-time daemon uptime, memory, CPU load, and system health.
- **Configuration Tab**: Live 8-channel frequency plan and TX power LUT tables.
- **Logs Tab**: Gateway system journal and packet reception stats.
