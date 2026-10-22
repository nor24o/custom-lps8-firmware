# Custom Dragino Firmware & Applications Architecture

This document describes the technical architecture, GPIO pinouts, SPI bus configurations, and UDP wire protocol for custom firmware on **Dragino LPS8** (SX1302) and **Dragino LG01 / LG02** (SX1276).

---

## 1. Hardware Comparison Matrix

| Specification | Dragino LPS8 | Dragino LG02 (Dual) | Dragino LG01 (Single) |
|---|---|---|---|
| **SoC** | Qualcomm Atheros AR9331 (400 MHz) | Atheros AR9331 (400 MHz) | Atheros AR9331 (400 MHz) |
| **RAM / Flash** | 64 MB DDR2 / 16 MB SPI Flash | 64 MB DDR2 / 16 MB SPI Flash | 64 MB DDR2 / 16 MB SPI Flash |
| **LoRa Silicon** | Semtech SX1302 + 2x SX1250 | 2x Semtech SX1276/78 | 1x Semtech SX1276/78 |
| **Channels** | 8 Multi-SF channels + FSK/LoRa service | 2 single-frequency channels (1 RX + 1 TX) | 1 single-frequency channel (half-duplex) |
| **SPI Buses** | 1 (`/dev/spidev1.0`) | 2 bitbang buses (`spidev1.0` & `spidev2.0`) | 1 bitbang bus (`spidev2.0`) |
| **Primary App** | `raw_lora_app` | `lg02_pkt_fwd` | `lg01_pkt_fwd` |
| **Web GUI** | 8-Channel Plan + RF LUT | Single/Dual LoRa + WiFi STA Manager | Single LoRa + WiFi STA Manager |

---

## 2. SPI & GPIO Interface Specifications

### 2.1 Dragino LPS8 (SX1302 Concentrator)
The SX1302 communicates over `/dev/spidev1.0` via standard or bitbang SPI:
- **SPI Device**: `/dev/spidev1.0`
- **Reset Line**: GPIO 23
- **Power Amplifier (PA) Switch**: LED / GPIO `dragino2:red:wan`
  - Can be toggled between active-high (TX=HIGH, RX=LOW) and active-low (TX=LOW, RX=HIGH) via `"pa_gpio_active_high"` in `/etc/lora/config.json`.
- **Clock Source**: TCXO 32 MHz (`clksrc: 0`)

### 2.2 Dragino LG01 & LG02 (SX1276 Transceivers)
The AR9331 drives independent GPIO bitbang SPI buses defined in `/etc/init.d/spi_init`:
```sh
insmod spi-gpio-custom bus0=1,14,16,26,0,8000000,15 bus1=2,18,21,19,0,8000000,24
```

#### Radio 1 (Primary RX Radio on LG02):
- **SPI Bus**: `/dev/spidev1.0` (Bus 1)
- **SCK**: GPIO 14
- **MOSI**: GPIO 16
- **MISO**: GPIO 26
- **NSS (CS)**: GPIO 15
- **Reset**: GPIO 8
- **DIO0 (Interrupt)**: GPIO 7

#### Radio 2 (TX Radio on LG02 / Primary Transceiver on LG01):
- **SPI Bus**: `/dev/spidev2.0` (Bus 2)
- **SCK**: GPIO 18
- **MOSI**: GPIO 21
- **MISO**: GPIO 19
- **NSS (CS)**: GPIO 24
- **Reset**: GPIO 23

### 2.3 Hardware Auto-Detection Logic
The daemon startup script `/etc/init.d/lg02_pkt_fwd` runs `/usr/bin/simple_spi_rw` to test SPI register `0x42` (RegVersion == `0x12`):
```sh
# Probe Radio1 (rst=8, spidev1.0) and Radio2 (rst=23, spidev2.0)
probe 8 0  -> Radio 1 status
probe 23 1 -> Radio 2 status
```
- If **both** radios respond: Operates in **LG02 dual-radio mode**.
- If **only Radio 2** responds: Operates in **LG01 single-radio mode**.
- If neither responds but `spidev1.0` exists: Fallback to **SX1302** daemon.

---

## 3. Network & UDP Wire Protocol

Both `raw_lora_app` (SX1302) and `lg02_pkt_fwd` (SX1276) implement a mirrored UDP packet protocol:

### Upstream (Gateway -> Server / PC)
- **Destination**: `target_ip : port_up` (Default: `192.168.1.8:5555`)
- **RF Packet format**: Semtech JSON payload:
  ```json
  {
    "rxpk": [
      {
        "tmst": 12345678,
        "chan": 0,
        "rfch": 0,
        "freq": 868.100000,
        "stat": 1,
        "modu": "LORA",
        "datr": "SF7BW125",
        "codr": "4/5",
        "rssi": -42,
        "lsnr": 9.5,
        "size": 14,
        "data": "SGVsbG8gV29ybGQh"
      }
    ]
  }
  ```
- **Heartbeat format**: Binary datagram sent every `heartbeat_interval_s`:
  - Byte 0: `0x02` (`PKT_TYPE_HEARTBEAT`)
  - Bytes 1-8: Gateway EUI (MAC address formatted)
  - Bytes 9-12: Gateway uptime (seconds, uint32)
  - Bytes 13-16: Total RX packet counter
  - Bytes 17-20: Total TX packet counter

### Downstream (Server / PC -> Gateway)
- **Listen Port**: `port_down` (Default: `5556`)
- **Format**: JSON TX request:
  ```json
  {
    "imme": true,
    "freq": 868100000,
    "rfch": 0,
    "powe": 14,
    "modu": "LORA",
    "datr": "SF7BW125",
    "codr": "4/5",
    "ipol": false,
    "size": 12,
    "data": "SGVsbG8gV29ybGQh"
  }
  ```

---

## 4. Software Watchdog (`net_watchdog.sh`)

A watchdog runs periodically via `/etc/crontabs/root`:
- Pings gateway gateway upstream server.
- Verifies LoRa daemon process is running.
- Restarts services or issues a system reboot if connectivity is lost for over 15 minutes.
