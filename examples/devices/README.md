# Reference Device Firmware & Implementation Guide

This folder provides tested reference firmware implementations for building custom LoRa nodes that communicate with the Dragino LPS8 (SX1302) and LG01/LG02 (SX1276) custom firmware.

---

## 1. Directory Structure

- `class_a_sensor/`: Complete Arduino / ESP32 example for low-power battery-operated sensors. Sleeps in deep sleep, wakes up, sends telemetry, waits for the 1,000 ms RX1 turnaround window, captures downlinks, and returns to sleep.
- `class_c_actuator/`: Complete Arduino / ESP32 example for mains-powered actuators (Relays, Solenoid Valves, Motors). Continuously listens on the frequency (never sleeps), receives instant downlinks from the gateway, executes switching, and replies with an instant confirmation ACK.

---

## 2. Hardware Wiring (ESP32 to SX1276 / RFM95)

Connect your microcontroller to the LoRa transceiver module as follows:

| SX1276 (RFM95) Pin | ESP32 GPIO Pin | Function |
| :--- | :--- | :--- |
| **VCC** | 3.3V | Power Supply (Ensure stable 3.3V) |
| **GND** | GND | Ground |
| **SCK** | GPIO 5 | SPI Clock |
| **MISO** | GPIO 19 | SPI MISO |
| **MOSI** | GPIO 27 | SPI MOSI |
| **NSS / CS** | GPIO 18 | SPI Chip Select |
| **DIO0** | GPIO 26 | Packet Done / RX Interrupt |
| **RESET / RST**| GPIO 14 | Hardware Reset |
| **DIO1** | GPIO 33 | Timeout / RX Window (Optional) |

---

## 3. Required Arduino Libraries

In the Arduino IDE Library Manager, install:
- **RadioLib** (by Jan Gromes) - Version 6.0.0 or later.
- If using ESP32: **esp32** board package by Espressif Systems.

---

## 4. Packet Payload Standards

### Modern 2-Byte Node ID & TLV Telemetry Format (No Magic Key)

The payload starts directly with the unique 2-byte (16-bit) Node ID without requiring a magic network key:

```text
[Byte 0..1: Node ID] [Byte 2: Device Type] [Byte 3: Seq] [Byte 4..N: TLV Channel Telemetry]
```

#### **Device Type Descriptor (Byte 2):**
- **Upper Nibble (Bits 7..4) — Operating Class:**
  - `0x1_` = **Class A** (Battery, Sleep, Turnaround RX1/RX2 windows)
  - `0x2_` = **Class B** (Beacon-synchronized scheduled ping slots)
  - `0x3_` = **Class C** (Mains powered, continuous listening RX)
- **Lower Nibble (Bits 3..0) — Primary Capability:**
  - `0x_1` = **Sensor** (Temp, Humidity, Battery, ADC)
  - `0x_2` = **Actuator** (Relay, Solenoid valve, Switch)
  - `0x_3` = **Combo** (Smart Plug with Relay + Power/Voltage Monitoring)
  - `0x_4` = **Meter** (Utility pulse counter)
  - `0x_5` = **Security** (Door/Window reed switch, PIR)

#### **Example: Class A Sensor (12 Bytes Total)**
- `0x12, 0x34`: Node ID (`1234`)
- `0x11`: Device Type (Class A Sensor)
- `0x00`: Rolling Sequence Counter
- `0x01, 0x11, 0x09, 0x92`: Channel 1 Temperature (24.50 °C)
- `0x02, 0x05, 0x0C, 0xE4`: Channel 2 Battery (3300 mV / 3.30 V)

#### **Example: Class C Actuator Uplink / Confirmation ACK (7 Bytes Total)**
- `0x56, 0x78`: Node ID (`5678`)
- `0x32`: Device Type (Class C Actuator)
- `0x01`: Rolling Sequence Counter
- `0x01, 0x01, 0x01`: Channel 1 Digital State ON

### Actuator Downlink Command Payloads (`class_c_actuator`)
- `0x56, 0x78, 0x01, 0x01`: Addressed Relay ON (Target Node 5678, Ch1, ON)
- `0x56, 0x78, 0x01, 0x00`: Addressed Relay OFF (Target Node 5678, Ch1, OFF)
- Or Direct Binary: `0x01, 0x01` (ON) / `0x01, 0x00` (OFF)
- Or ASCII: `VALVE:ON`, `VALVE:OFF`
