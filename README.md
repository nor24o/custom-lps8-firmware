# Dragino LG01 / LG02 Custom Firmware & SX1276 Applications

This branch/target contains the complete custom firmware, rootfs overlay, and application stack for the **Dragino LG01** (single-channel) and **Dragino LG02** (dual-channel) LoRa gateways powered by the Qualcomm Atheros AR9331 SoC and Semtech SX1276 transceiver(s).

---

## 1. Hardware Architecture & Interfaces

- **SoC**: Atheros AR9331 (MIPS 24Kc @ 400 MHz, 64 MB RAM, 16 MB Flash)
- **Radios**: Semtech SX1276/78
  - **Radio 1 (RX)**: Bitbang SPI bus 1 (`/dev/spidev1.0`)
    - SCK: GPIO 14
    - MOSI: GPIO 16
    - MISO: GPIO 26
    - NSS (CS): GPIO 15
    - Reset: GPIO 8
    - DIO0: GPIO 7
  - **Radio 2 (TX / RX on LG01)**: Bitbang SPI bus 2 (`/dev/spidev2.0`)
    - SCK: GPIO 18
    - MOSI: GPIO 21
    - MISO: GPIO 19
    - NSS (CS): GPIO 24
    - Reset: GPIO 23
- **Auto-Detection**: The boot script uses `/usr/bin/simple_spi_rw` to test SPI communication. If both radios respond, it starts `lg02_pkt_fwd` in dual mode. If only Radio 2 responds, it operates in single mode (LG01).

---

## 2. Directory Structure

```
.
├── build_app.sh           # Compiles lg01_pkt_fwd, lg02_pkt_fwd, and simple_spi_rw
├── build_image.sh         # Generates OpenWrt sysupgrade.bin using ImageBuilder
├── build_all.sh           # Builds both apps and complete firmware image
├── src/                   # SX1276 C source code
│   ├── lg01_pkt_fwd.c     # Single-channel forwarder (UCI / JSON)
│   ├── lg02_pkt_fwd.c     # Dual-channel forwarder (mirrors LPS8 raw_lora_app wire format)
│   ├── simple_spi_rw.c    # Hardware test & register probe utility
│   ├── radio.c / radio.h  # SX1276 register configuration and SPI bitbang driver
│   ├── jitqueue.c / .h    # JIT packet queue for deterministic TX scheduling
│   ├── parson.c / .h      # JSON parser
│   └── base64.c / .h      # Base64 encoder/decoder
└── files/                 # Target Rootfs Overlay (injected into SquashFS)
    ├── etc/
    │   ├── config/        # network, wireless, system, uhttpd, dropbear
    │   ├── init.d/        # lg02_pkt_fwd, spi_init, sx1276_app
    │   ├── lora/          # config.json (radio_0 and radio_1 config)
    │   └── modules.d/     # 30-spi-gpio-custom
    ├── usr/bin/           # lg01_pkt_fwd, lg02_pkt_fwd, simple_spi_rw, sx1276_app, net_watchdog.sh
    └── www/               # Custom Dark Web GUI (Status, LoRa Config, WiFi Scan & Station Setup)
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

### Python Dependencies (for PC Test Console)
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

### Quick Build (Apps + Firmware Image)
```bash
chmod +x build_all.sh build_app.sh build_image.sh
./build_all.sh
```

### Build Only Applications
```bash
./build_app.sh
```
Compiles `lg01_pkt_fwd`, `lg02_pkt_fwd`, `simple_spi_rw`, and stages them into `files/usr/bin/`.

### Build Only OpenWrt Image
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
    "radio_0": {
        "enabled": true,
        "spi_path": "/dev/spidev1.0",
        "freq": 868100000,
        "sf": 7,
        "bw": 125,
        "tx_enable": false
    },
    "radio_1": {
        "enabled": true,
        "spi_path": "/dev/spidev2.0",
        "freq": 868300000,
        "sf": 7,
        "bw": 125,
        "tx_enable": true,
        "tx_power": 14
    }
}
```

---

## 6. Web Interface

The firmware provides a web UI on port 80:
- **Status Tab**: Packet reception, RSSI, SNR, daemon state, and gateway uptime.
- **LoRa Config Tab**: Frequency, SF, bandwidth, sync word, and server IP/port settings.
- **Device Tab**: Real-time WiFi scanning, station mode connection (WWAN), and LAN IP configuration.
