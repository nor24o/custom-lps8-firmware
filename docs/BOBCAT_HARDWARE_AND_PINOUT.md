# Bobcat Miner 300 (Model G285 / RK3566) Hardware Reference & Pinout

This document details the hardware architecture, pinout, and wiring for the Bobcat Miner 300 (Model G285) running Armbian Linux.

---

## 1. System Specifications

| Component | Specification |
| :--- | :--- |
| **SoC** | Rockchip RK3566 (Quad-Core Cortex-A55 @ up to 1.8 GHz) |
| **RAM** | 1 GB / 2 GB LPDDR4 |
| **Flash** | 32 GB / 64 GB eMMC 5.1 |
| **Ethernet** | 10/100/1000 Mbps Gigabit Ethernet (RJ45) |
| **Wi-Fi / BT** | AIC8800 (SDIO Wi-Fi 802.11b/g/n/ac + Bluetooth 5.0) |
| **LoRa Concentrator** | Semtech SX1302 + Dual SX1250 RF Front-Ends |
| **Crypto Element** | Microchip ATECC608A (I2C Bus 1, Address `0x60`) |
| **Status Indicator** | Multi-color Front RGB LED |

---

## 2. LoRa Concentrator (Semtech SX1302) Interface

The SX1302 concentrator communicates over the Rockchip SPI bus:
- **SPI Device**: `/dev/spidev5.0` (SPI Controller 5, Chip Select 0)
- **Speed**: 8 MHz
- **Mode**: SPI Mode 0

### GPIO Control Lines

The Bobcat 300 isolates and switches power to the LoRa module using two high-side switches, with a dedicated active-high pulse line for hardware reset:

| Signal | Global Linux GPIO | Rockchip Bank / Pin | Sysfs Path | Active Level |
| :--- | :--- | :--- | :--- | :--- |
| **LoRa Power Rail 1** | `125` | `GPIO3_D5` | `/sys/class/gpio/gpio125` | HIGH (`1`) = Power ON |
| **LoRa Power Rail 2** | `122` | `GPIO3_D2` | `/sys/class/gpio/gpio122` | HIGH (`1`) = Power ON |
| **SX1302 Hardware Reset** | `149` | `GPIO4_B5` | `/sys/class/gpio/gpio149` | HIGH (`1`) pulse for 100 ms |

> [!IMPORTANT]
> Both GPIO 125 and GPIO 122 must be driven HIGH to supply power to the SX1302 module. When either line is LOW, the module is completely unpowered.

The reset sequence is implemented in `/usr/local/bin/reset_lgw.sh`:
```bash
# Power cycle
pin 125 low; pin 122 low; sleep 1
pin 125 high; pin 122 high; sleep 0.2

# Reset pulse
pin 149 high; sleep 0.1
pin 149 low; sleep 0.1
pin 149 input  # Float to avoid loading internal pull-down
```

---

## 3. Front RGB Status LED Wiring & Inversion Mapping

On the Bobcat Miner 300 G285, the front RGB LED is connected to GPIO4.
The Linux kernel DTS labels and physical LED dies are mapped as follows:

| Sysfs Node | Linux Kernel Name | Physical LED Die | Bobcat GPIO |
| :--- | :--- | :--- | :--- |
| `/sys/class/leds/red:status` | `red:status` | **PHYSICAL RED** | GPIO 130 (`GPIO4_A2`) |
| `/sys/class/leds/blue:status` | `blue:status` | **PHYSICAL GREEN** | GPIO 128 (`GPIO4_A0`) |
| `/sys/class/leds/green:status` | `green:status` | **PHYSICAL BLUE** | GPIO 129 (`GPIO4_A1`) |

> [!WARNING]
> Notice the sysfs name inversion on the green and blue channels:
> - Writing to `/sys/class/leds/blue:status` activates the **physical GREEN** die.
> - Writing to `/sys/class/leds/green:status` activates the **physical BLUE** die.
>
> Maximum brightness is `1` (binary ON/OFF). Writing `255` will return `-EINVAL`.

### Industrial State Machine Patterns

| State | Color | Pattern |
| :--- | :--- | :--- |
| **Normal / Healthy (System OK)** | **Green** | Double-pulse biological heartbeat: `80ms ON / 140ms OFF / 80ms ON / 900ms OFF` |
| **LoRa Transmit (TX)** | **Blue** | Pure Blue 180 ms pulse |
| **LoRa Receive (RX)** | **Red** | Pure Red 120 ms pulse |
| **SX1302 Concentrator HAL Error** | **Red** | Fast flash: `100ms ON / 100ms OFF` |
| **Network Gateway Unreachable** | **Yellow** | Flashing Yellow (Red + Green): `200ms ON / 200ms OFF` |
| **Booting / Initializing** | **Cyan** | Solid Cyan (Green + Blue) |
| **Daemon Crash / Failure** | **Red** | Solid Red (watchdog fallback) |

---

## 4. RF & Antenna Configuration

The original internal cabling in the Bobcat passes through internal PCB tracks and switching circuits. For optimal reception and 27 dBm (500 mW) transmission:
- The internal lead was replaced with a direct **coaxial RG316/RG178 pigtail** connecting directly from the SX1302 U.FL connector to the rear SMA connector.
- The `config.json` is tuned with a calibrated 16-point Power Amplifier Look-Up Table (LUT) covering from 12 dBm up to **27 dBm** maximum legal EIRP for EU868.
