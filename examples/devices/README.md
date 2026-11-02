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

### Custom Binary Telemetry (10 Bytes - Example `class_a_sensor`)
- Bytes `0..1`: Node ID (e.g. `0xAA, 0x0B`)
- Bytes `2..3`: Packet Sequence Counter (`uint16_t` big-endian)
- Bytes `4..5`: Temperature in tenths of a degree (`int16_t` big-endian, e.g. `245` = 24.5 °C)
- Bytes `6..7`: Battery Voltage in millivolts (`uint16_t` big-endian, e.g. `3300` = 3.30 V)
- Bytes `8..9`: Optional CRC / Checksum

### Actuator Downlink Payloads (`class_c_actuator`)
- `0x01, 0x01`: Relay ON
- `0x01, 0x00`: Relay OFF
- Or ASCII: `VALVE:ON`, `VALVE:OFF`
