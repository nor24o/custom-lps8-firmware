#!/usr/bin/env python3
"""
bobcat_lora_bridge.py - Industrial LoRa Ingestion, Multi-Scheme Decoder, SQLite & HA MQTT Bridge
Bobcat Miner 300 (RK3566 / SX1302 Concentrator)
"""

import os
import sys
import time
import json
import socket
import select
import base64
import struct
import sqlite3
import threading
import traceback
from datetime import datetime

CONFIG_PATH = "/etc/lora/config.json"
DECODERS_PATH = "/etc/lora/decoders.json"
SATELLITES_PATH = "/etc/lora/satellites.json"
CONCENTRATORS_JSON = "/tmp/lora_concentrators.json"
DB_NODES_PATH = "/etc/lora/nodes.db"
DB_RAM_PATH = "/tmp/lora_messages.db"
PACKETS_JSON = "/tmp/lora_packets.json"

PORT_UP = 5555
PORT_SEMTECH = 1700
PORT_DOWN = 5556
STATUS_PORT = 5557

try:
    import paho.mqtt.client as mqtt
    PAHO_AVAILABLE = True
except ImportError:
    PAHO_AVAILABLE = False


# -----------------------------------------------------------------------------
# Configuration & Scheme Loader
# -----------------------------------------------------------------------------
def load_config():
    try:
        with open(CONFIG_PATH, "r", encoding="utf-8") as f:
            return json.load(f)
    except Exception as e:
        return {}


def load_decoders():
    try:
        with open(DECODERS_PATH, "r", encoding="utf-8") as f:
            data = json.load(f)
            schemes = data.get("schemes", [])
            global_rule = data.get("globalNodeId", {"source": "node_2b"})
            return schemes, global_rule
    except Exception as e:
        return [], {"source": "node_2b"}


# -----------------------------------------------------------------------------
# Concentrator Fleet Tracker (Main SX1302 + Satellite Concentrators)
# -----------------------------------------------------------------------------
class ConcentratorTracker:
    def __init__(self, main_eui="0016C001F1500B48"):
        self.lock = threading.Lock()
        self.main_eui = main_eui
        self.concentrators = {}
        self.start_time = time.time()
        self.register_main()
        self.load_saved_satellites()

    def register_main(self):
        with self.lock:
            if self.main_eui not in self.concentrators:
                self.concentrators[self.main_eui] = {
                    "gateway_id": self.main_eui,
                    "name": "Bobcat Main Concentrator",
                    "type": "main",
                    "ip": "127.0.0.1",
                    "port": PORT_UP,
                    "protocol": "Local SX1302 SPI",
                    "status": "ONLINE",
                    "last_seen": datetime.utcnow().strftime("%Y-%m-%d %H:%M:%S"),
                    "uptime_s": int(time.time() - self.start_time),
                    "rx_count": 0,
                    "crc_err": 0,
                    "temp_c": 30.0,
                    "nodes": {}
                }

    def load_saved_satellites(self):
        try:
            if os.path.exists(SATELLITES_PATH):
                with open(SATELLITES_PATH, "r", encoding="utf-8") as f:
                    sats = json.load(f)
                    if isinstance(sats, list):
                        with self.lock:
                            for s in sats:
                                gid = s.get("gateway_id")
                                if gid and gid not in self.concentrators:
                                    self.concentrators[gid] = {
                                        "gateway_id": gid,
                                        "name": s.get("name", f"Satellite {gid}"),
                                        "type": "satellite",
                                        "ip": s.get("ip", "0.0.0.0"),
                                        "port": s.get("port", PORT_SEMTECH),
                                        "protocol": s.get("protocol", "Semtech UDP 1700"),
                                        "status": "STANDBY",
                                        "last_seen": s.get("last_seen", "--"),
                                        "uptime_s": 0,
                                        "rx_count": 0,
                                        "crc_err": 0,
                                        "nodes": s.get("nodes", {})
                                    }
        except Exception as e:
            print(f"[CONCENTRATOR] Error loading satellites: {e}")

    def update_main_status(self, stat):
        if not stat:
            return
        with self.lock:
            if "eui" in stat and stat["eui"]:
                old_eui = self.main_eui
                self.main_eui = stat["eui"]
                if old_eui in self.concentrators and old_eui != self.main_eui:
                    self.concentrators[self.main_eui] = self.concentrators.pop(old_eui)
                    self.concentrators[self.main_eui]["gateway_id"] = self.main_eui

            gw = self.concentrators.get(self.main_eui)
            if gw:
                gw["uptime_s"] = stat.get("uptime_s", gw["uptime_s"])
                if stat.get("rx", 0) > gw["rx_count"]:
                    gw["rx_count"] = stat.get("rx", gw["rx_count"])
                gw["crc_err"] = stat.get("crc_err", gw.get("crc_err", 0))
                gw["temp_c"] = stat.get("temp_c", 30.0)
                gw["status"] = "ONLINE"
                gw["last_seen"] = datetime.utcnow().strftime("%Y-%m-%d %H:%M:%S")

    def register_heartbeat(self, gw_id, name, ip, port, protocol):
        with self.lock:
            now_str = datetime.utcnow().strftime("%Y-%m-%d %H:%M:%S")
            is_main = (gw_id == self.main_eui or ip == "127.0.0.1")
            actual_id = self.main_eui if is_main else gw_id

            if actual_id not in self.concentrators:
                self.concentrators[actual_id] = {
                    "gateway_id": actual_id,
                    "name": name or ("Bobcat Main Concentrator" if is_main else f"Satellite Gateway ({ip})"),
                    "type": "main" if is_main else "satellite",
                    "ip": ip,
                    "port": port,
                    "protocol": protocol,
                    "status": "ONLINE",
                    "last_seen": now_str,
                    "uptime_s": int(time.time() - self.start_time),
                    "rx_count": 0,
                    "crc_err": 0,
                    "nodes": {}
                }
            else:
                gw = self.concentrators[actual_id]
                gw["last_seen"] = now_str
                gw["status"] = "ONLINE"
                if ip and ip != "127.0.0.1":
                    gw["ip"] = ip
                if protocol:
                    gw["protocol"] = protocol
        self.save_cache()

    def record_uplink(self, gw_id, name, ip, port, protocol, node_id, telemetry_payload, raw_hex=""):
        with self.lock:
            now_str = datetime.utcnow().strftime("%Y-%m-%d %H:%M:%S")
            is_main = (gw_id == self.main_eui or ip == "127.0.0.1")
            actual_id = self.main_eui if is_main else gw_id

            if actual_id not in self.concentrators:
                self.concentrators[actual_id] = {
                    "gateway_id": actual_id,
                    "name": name or ("Bobcat Main Concentrator" if is_main else f"Satellite Gateway ({ip})"),
                    "type": "main" if is_main else "satellite",
                    "ip": ip,
                    "port": port,
                    "protocol": protocol,
                    "status": "ONLINE",
                    "last_seen": now_str,
                    "uptime_s": int(time.time() - self.start_time),
                    "rx_count": 0,
                    "crc_err": 0,
                    "nodes": {}
                }

            gw = self.concentrators[actual_id]
            gw["rx_count"] += 1
            gw["last_seen"] = now_str
            gw["status"] = "ONLINE"
            gw["uptime_s"] = int(time.time() - self.start_time)
            if ip and ip != "127.0.0.1":
                gw["ip"] = ip
            if protocol:
                gw["protocol"] = protocol

            # Deep copy telemetry to avoid mutable pointer collisions
            node_data = dict(telemetry_payload)
            node_data["gateway_id"] = actual_id
            node_data["gateway_name"] = gw["name"]
            node_data["gateway_ip"] = gw["ip"]
            node_data["node_id"] = node_id
            node_data["last_seen"] = now_str
            if raw_hex:
                node_data["raw_hex"] = raw_hex

            gw["nodes"][node_id] = node_data

        self.save_cache()
        return actual_id, gw["name"], gw["ip"]

    def save_cache(self):
        try:
            with self.lock:
                snapshot = dict(self.concentrators)
            with open(CONCENTRATORS_JSON + ".tmp", "w", encoding="utf-8") as f:
                json.dump(snapshot, f, indent=2)
            os.replace(CONCENTRATORS_JSON + ".tmp", CONCENTRATORS_JSON)
        except Exception:
            pass

    def get_all(self):
        with self.lock:
            now_ts = time.time()
            for gid, gw in self.concentrators.items():
                if gw["type"] == "satellite" and gw.get("last_seen") and gw["last_seen"] != "--":
                    try:
                        t = datetime.strptime(gw["last_seen"], "%Y-%m-%d %H:%M:%S").timestamp()
                        if (now_ts - t) > 120:
                            gw["status"] = "STANDBY"
                    except Exception:
                        pass
            return dict(self.concentrators)


g_tracker = ConcentratorTracker()


# -----------------------------------------------------------------------------
# Multi-Scheme Payload Decoding Engine
# -----------------------------------------------------------------------------
def is_printable_ascii(raw_bytes):
    if len(raw_bytes) < 2:
        return False
    return all((32 <= b <= 126) or b in (9, 10, 13) for b in raw_bytes)


def decode_cayenne_lpp(raw_bytes, offset=0):
    out = {}
    i = offset
    n = len(raw_bytes)
    parsed_any = False

    while i < n:
        if i + 1 >= n:
            break
        ch = raw_bytes[i]
        type_code = raw_bytes[i + 1]
        i += 2
        pfx = f"ch{ch}_"

        if type_code == 0x00:  # Digital Input (1B)
            if i >= n: break
            val = raw_bytes[i]
            i += 1
            out[f"{pfx}digital_in"] = val
            parsed_any = True
        elif type_code == 0x01:  # Digital Output (1B)
            if i >= n: break
            val = raw_bytes[i]
            i += 1
            out[f"{pfx}digital_out"] = val
            parsed_any = True
        elif type_code == 0x02:  # Analog Input (2B, 0.01 signed)
            if i + 1 >= n: break
            val = struct.unpack(">h", raw_bytes[i:i + 2])[0]
            i += 2
            computed = round(val * 0.01, 2)
            out[f"{pfx}analog_in"] = computed
            if "battery" not in out:
                out["battery"] = computed
            parsed_any = True
        elif type_code == 0x03:  # Analog Output (2B, 0.01 signed)
            if i + 1 >= n: break
            val = struct.unpack(">h", raw_bytes[i:i + 2])[0]
            i += 2
            out[f"{pfx}analog_out"] = round(val * 0.01, 2)
            parsed_any = True
        elif type_code == 0x65:  # Illuminance (2B, 1 Lux)
            if i + 1 >= n: break
            val = struct.unpack(">H", raw_bytes[i:i + 2])[0]
            i += 2
            out[f"{pfx}illuminance_lux"] = val
            parsed_any = True
        elif type_code == 0x66:  # Presence (1B)
            if i >= n: break
            out[f"{pfx}presence"] = raw_bytes[i]
            i += 1
            parsed_any = True
        elif type_code == 0x67:  # Temperature (2B, 0.1 °C signed)
            if i + 1 >= n: break
            val = struct.unpack(">h", raw_bytes[i:i + 2])[0]
            i += 2
            temp_c = round(val * 0.1, 1)
            out[f"{pfx}temperature_c"] = temp_c
            out["temperature"] = temp_c
            parsed_any = True
        elif type_code == 0x68:  # Humidity (1B, 0.5 %)
            if i >= n: break
            h = round(raw_bytes[i] * 0.5, 1)
            i += 1
            out[f"{pfx}humidity_pct"] = h
            out["humidity"] = h
            parsed_any = True
        elif type_code == 0x71:  # Accelerometer (6B, 3x int16, 0.001 g)
            if i + 5 >= n: break
            ax, ay, az = struct.unpack(">hhh", raw_bytes[i:i + 6])
            i += 6
            out["accel_x"] = round(ax * 0.001, 3)
            out["accel_y"] = round(ay * 0.001, 3)
            out["accel_z"] = round(az * 0.001, 3)
            out[f"{pfx}accel"] = {"x": out["accel_x"], "y": out["accel_y"], "z": out["accel_z"]}
            parsed_any = True
        elif type_code == 0x73:  # Barometer (2B, 0.1 hPa)
            if i + 1 >= n: break
            val = struct.unpack(">H", raw_bytes[i:i + 2])[0]
            i += 2
            p = round(val * 0.1, 1)
            out[f"{pfx}barometer_hpa"] = p
            out["pressure"] = p
            parsed_any = True
        elif type_code == 0x86:  # Gyrometer (6B, 3x int16, 0.01 °/s)
            if i + 5 >= n: break
            gx, gy, gz = struct.unpack(">hhh", raw_bytes[i:i + 6])
            i += 6
            out[f"{pfx}gyro"] = {"x": round(gx * 0.01, 2), "y": round(gy * 0.01, 2), "z": round(gz * 0.01, 2)}
            parsed_any = True
        elif type_code == 0x88:  # GPS (9B)
            if i + 8 >= n: break
            lat_raw = (raw_bytes[i] << 16) | (raw_bytes[i + 1] << 8) | raw_bytes[i + 2]
            if lat_raw & 0x800000: lat_raw -= 0x1000000
            lon_raw = (raw_bytes[i + 3] << 16) | (raw_bytes[i + 4] << 8) | raw_bytes[i + 5]
            if lon_raw & 0x800000: lon_raw -= 0x1000000
            alt_raw = (raw_bytes[i + 6] << 16) | (raw_bytes[i + 7] << 8) | raw_bytes[i + 8]
            if alt_raw & 0x800000: alt_raw -= 0x1000000
            i += 9
            out["latitude"] = round(lat_raw * 0.0001, 4)
            out["longitude"] = round(lon_raw * 0.0001, 4)
            out["altitude_m"] = round(alt_raw * 0.01, 2)
            out[f"{pfx}gps"] = {"lat": out["latitude"], "lon": out["longitude"], "alt": out["altitude_m"]}
            parsed_any = True
        else:
            break

    return out if parsed_any else None


def decode_fields_slicer(raw_bytes, fields):
    out = {}
    n = len(raw_bytes)
    for f in fields:
        name = f.get("name")
        if not name:
            continue
        off = int(f.get("offset", 0))
        flen = int(f.get("length", 1))
        ftype = f.get("type", "uint8")
        scale = float(f.get("scale", 1.0))
        add = float(f.get("add", 0.0))
        unit = f.get("unit", "")

        if off >= n:
            continue

        if ftype == "hex":
            end = min(off + flen, n)
            out[name] = raw_bytes[off:end].hex().upper()
            continue

        if ftype == "ascii":
            end = min(off + flen, n)
            try:
                out[name] = raw_bytes[off:end].decode("ascii", errors="replace")
            except Exception:
                out[name] = raw_bytes[off:end].hex().upper()
            continue

        try:
            val = 0
            if ftype == "uint8":
                val = raw_bytes[off]
            elif ftype == "int8":
                val = struct.unpack("b", raw_bytes[off:off + 1])[0]
            elif ftype == "uint16_be":
                val = struct.unpack(">H", raw_bytes[off:off + 2])[0]
            elif ftype == "uint16_le":
                val = struct.unpack("<H", raw_bytes[off:off + 2])[0]
            elif ftype == "int16_be":
                val = struct.unpack(">h", raw_bytes[off:off + 2])[0]
            elif ftype == "int16_le":
                val = struct.unpack("<h", raw_bytes[off:off + 2])[0]
            elif ftype == "uint32_be":
                val = struct.unpack(">I", raw_bytes[off:off + 4])[0]
            elif ftype == "uint32_le":
                val = struct.unpack("<I", raw_bytes[off:off + 4])[0]
            computed = round((val * scale) + add, 3)
            out[name] = computed
            if unit:
                out[f"{name}_unit"] = unit
        except Exception:
            pass
    return out


def decode_aa0b(raw_bytes, hex_str):
    if len(raw_bytes) < 8:
        return {"raw_hex": hex_str}
    seq = (raw_bytes[2] << 8) | raw_bytes[3]
    temp_raw = struct.unpack(">h", raw_bytes[4:6])[0]
    volt_raw = (raw_bytes[6] << 8) | raw_bytes[7]
    return {
        "node_type": "AA0B",
        "seq": seq,
        "temperature": round(temp_raw / 10.0, 1),
        "battery": round(volt_raw / 1000.0, 2),
        "battery_mv": volt_raw,
        "extra": hex_str[16:]
    }


def decode_aa0c(raw_bytes, hex_str):
    if len(raw_bytes) < 8:
        return {"raw_hex": hex_str}
    seq = (raw_bytes[2] << 8) | raw_bytes[3]
    sensor_raw = (raw_bytes[4] << 8) | raw_bytes[5]
    volt_raw = (raw_bytes[6] << 8) | raw_bytes[7]
    return {
        "node_type": "AA0C",
        "seq": seq,
        "sensor_val": sensor_raw,
        "ch1_val": sensor_raw,
        "battery": round(volt_raw / 1000.0, 2),
        "battery_mv": volt_raw,
        "extra": hex_str[16:]
    }


def execute_decoder(raw_bytes, hex_str, schemes, dec_enabled=True):
    clean_hex = hex_str.lower()
    if not dec_enabled:
        return "raw_disabled", "Raw Passthrough (Decoding Disabled)", {"hex": hex_str, "raw_hex": hex_str, "decoding": False}

    for s in schemes:
        if not s.get("enabled", True):
            continue
        m_type = s.get("matchType", "default")
        m_val = str(s.get("matchValue", "")).strip().lower()
        s_id = s.get("id", "")
        s_type = s.get("type", "cayenne_lpp")
        data_offset = int(s.get("dataOffset", 0))

        matched = False
        if m_type == "prefix":
            clean_pfx = m_val.replace("0x", "")
            if clean_hex.startswith(clean_pfx):
                matched = True
        elif m_type == "size":
            try:
                matched = (len(raw_bytes) == int(m_val))
            except ValueError:
                pass
        elif m_type == "condition":
            if s_id == "scheme_ascii_ping":
                matched = is_printable_ascii(raw_bytes)
            elif s_id == "scheme_2b_node_tlv":
                matched = (len(raw_bytes) >= 4)
            else:
                matched = True
        elif m_type == "default":
            matched = True

        if matched:
            name = s.get("name", s_id)
            # 1. Node CAFE special handling (Multi-Sensor LPP)
            if s_id == "scheme_node_cafe" or clean_hex.startswith("cafe"):
                res = {}
                if len(raw_bytes) >= 6:
                    res["node_id"] = raw_bytes[0:2].hex().upper()
                    res["device_serial"] = raw_bytes[2:6].hex().upper()
                    res["node_class"] = "A"
                    res["capability"] = "Sensor"
                lpp_res = decode_cayenne_lpp(raw_bytes, offset=data_offset or 6)
                if lpp_res:
                    res.update(lpp_res)
                return s_id, name, res

            # 2. Standard 2B Node TLV
            if s_id == "scheme_2b_node_tlv" or s_type == "ctv":
                res = {}
                if len(raw_bytes) >= 4:
                    res["node_id"] = raw_bytes[0:2].hex().upper()
                    dev_type = raw_bytes[2]
                    res["device_type"] = f"0x{dev_type:02X}"
                    class_code = dev_type // 16
                    res["node_class"] = "B" if class_code == 2 else ("C" if class_code == 3 else "A")
                    res["seq"] = raw_bytes[3]
                lpp_res = decode_cayenne_lpp(raw_bytes, offset=data_offset or 4)
                if lpp_res:
                    res.update(lpp_res)
                return s_id, name, res

            # 3. AA0B / AA0C
            if s_id == "scheme_aa0b" or clean_hex.startswith("aa0b"):
                return s_id, name, decode_aa0b(raw_bytes, hex_str)
            if s_id == "scheme_aa0c" or clean_hex.startswith("aa0c"):
                return s_id, name, decode_aa0c(raw_bytes, hex_str)

            # 4. ASCII
            if s_type == "ascii":
                return s_id, name, {"text": raw_bytes.decode("ascii", errors="replace")}

            # 5. Fields Slicer
            if s_type == "fields":
                return s_id, name, decode_fields_slicer(raw_bytes, s.get("fields", []))

            # 6. Standard Cayenne LPP
            if s_type == "cayenne_lpp":
                lpp_res = decode_cayenne_lpp(raw_bytes, offset=data_offset)
                if lpp_res:
                    return s_id, name, lpp_res

    # Automatic Fallbacks
    if clean_hex.startswith("cafe"):
        res = {"node_id": "CAFE"}
        if len(raw_bytes) >= 6:
            res["device_serial"] = raw_bytes[2:6].hex().upper()
        lpp = decode_cayenne_lpp(raw_bytes, offset=6)
        if lpp: res.update(lpp)
        return "scheme_node_cafe", "Node CAFE (Multi-Sensor LPP)", res

    if clean_hex.startswith("aa0b"):
        return "scheme_aa0b", "Sensor Node AA0B", decode_aa0b(raw_bytes, hex_str)
    if clean_hex.startswith("aa0c"):
        return "scheme_aa0c", "Sensor Node AA0C", decode_aa0c(raw_bytes, hex_str)
    if is_printable_ascii(raw_bytes):
        return "fallback_ascii", "ASCII Text", {"text": raw_bytes.decode("ascii", errors="replace")}

    lpp = decode_cayenne_lpp(raw_bytes, 0)
    if lpp:
        return "fallback_lpp", "Cayenne LPP", lpp

    return "raw", "Raw Payload", {"hex": hex_str}


def extract_node_id(raw_bytes, hex_str, decoded_data, schemes=None, global_rule=None):
    clean_hex = hex_str.upper()

    if decoded_data and isinstance(decoded_data, dict):
        for k in ("node_id", "nodeId", "id", "device_id"):
            if k in decoded_data and decoded_data[k]:
                return str(decoded_data[k]).upper()

    rule = global_rule or {"source": "node_2b"}
    src = rule.get("source", "node_2b")
    if src == "node_2b" and len(raw_bytes) >= 2:
        return f"{raw_bytes[0]:02X}{raw_bytes[1]:02X}"
    if src == "serial_4b" and len(raw_bytes) >= 6:
        return raw_bytes[2:6].hex().upper()

    if clean_hex.startswith("AA0B"): return "AA0B"
    if clean_hex.startswith("AA0C"): return "AA0C"
    if clean_hex.startswith("CAFE"): return "CAFE"
    if len(clean_hex) >= 4: return clean_hex[:4]
    return "UNKNOWN"


# -----------------------------------------------------------------------------
# SQLite Database Storage & Node Registry
# -----------------------------------------------------------------------------
def is_node_registered(node_id):
    try:
        con = sqlite3.connect(DB_NODES_PATH, timeout=2)
        cur = con.cursor()
        cur.execute("SELECT is_configured FROM node_settings WHERE node_id = ?", (node_id,))
        row = cur.fetchone()
        con.close()
        return bool(row and row[0] == 1)
    except Exception:
        return True


def record_to_databases(node_id, pkt, raw_hex, decoded_dict):
    now_str = datetime.utcnow().strftime("%Y-%m-%d %H:%M:%S")
    rssi = float(pkt.get("rssi", pkt.get("rssis", -100.0)))
    snr = float(pkt.get("lsnr", pkt.get("snr", 0.0)))
    freq_hz = int(float(pkt.get("freq", 868.1)) * 1e6)
    datr_str = str(pkt.get("datr", "SF7BW125"))
    sf = 7
    if "SF" in datr_str:
        try:
            sf = int(datr_str.split("SF")[1].split("BW")[0])
        except Exception:
            sf = 7
    tmst = int(pkt.get("tmst", 0))

    try:
        con_ram = sqlite3.connect(DB_RAM_PATH, timeout=5)
        cur_ram = con_ram.cursor()
        cur_ram.execute("""
            INSERT INTO node_messages (node_id, timestamp, rssi, snr, freq_hz, sf, payload_raw, payload_decoded, tmst)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
        """, (node_id, now_str, rssi, snr, freq_hz, sf, raw_hex, json.dumps(decoded_dict), tmst))
        con_ram.commit()
        con_ram.close()
    except Exception as e:
        print(f"[DB-RAM-ERR] {e}")

    try:
        con_nodes = sqlite3.connect(DB_NODES_PATH, timeout=5)
        cur_nodes = con_nodes.cursor()
        cur_nodes.execute("SELECT node_id, is_configured, group_name FROM node_settings WHERE node_id = ?", (node_id,))
        row = cur_nodes.fetchone()
        if row:
            cur_nodes.execute("""
                UPDATE node_settings
                SET last_seen = ?, last_rssi = ?, last_snr = ?, updated_at = ?
                WHERE node_id = ?
            """, (now_str, rssi, snr, now_str, node_id))
        else:
            default_model = "Multi-Sensor (CAFE)" if node_id == "CAFE" else ("temperature_sensor" if node_id == "AA0B" else ("relay_valve" if node_id == "AA0C" else "generic"))
            node_cls = "C" if default_model == "relay_valve" else "A"
            cur_nodes.execute("""
                INSERT INTO node_settings (node_id, name, node_class, model, group_name, is_configured, ha_enabled, last_seen, last_rssi, last_snr, created_at, updated_at)
                VALUES (?, ?, ?, ?, 'Default', 1, 1, ?, ?, ?, ?, ?)
            """, (node_id, f"LoRa Node {node_id}", node_cls, default_model, now_str, rssi, snr, now_str, now_str))
        con_nodes.commit()
        con_nodes.close()
    except Exception as e:
        print(f"[DB-NODES-ERR] {e}")


# -----------------------------------------------------------------------------
# LoRa Downlink Dispatcher (UDP 5556)
# -----------------------------------------------------------------------------
def dispatch_lora_downlink(target_node, payload_hex_or_str, power_dbm=27, datr="SF7BW125", freq_mhz=868.1):
    payload_str = str(payload_hex_or_str).strip()
    if payload_str.upper() == "ON" or payload_str == "1":
        raw_bytes = bytes.fromhex("0101")
    elif payload_str.upper() == "OFF" or payload_str == "0":
        raw_bytes = bytes.fromhex("0100")
    else:
        try:
            raw_bytes = bytes.fromhex(payload_str)
        except ValueError:
            raw_bytes = payload_str.encode("utf-8")

    b64_data = base64.b64encode(raw_bytes).decode("ascii")

    pkt = {
        "imme": True,
        "freq": freq_mhz,
        "rfch": 0,
        "powe": power_dbm,
        "modu": "LORA",
        "datr": datr,
        "codr": "4/5",
        "ipol": False,
        "size": len(raw_bytes),
        "data": b64_data
    }

    try:
        sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        msg_bytes = json.dumps(pkt).encode("ascii")
        sock.sendto(msg_bytes, ("127.0.0.1", PORT_DOWN))
        sock.close()
        print(f"[TX-DOWNLINK] Sent to {target_node} ({len(raw_bytes)}B): {payload_str}")
        return True
    except Exception as e:
        print(f"[TX-DOWNLINK-ERR] {e}")
        return False


# -----------------------------------------------------------------------------
# Edge Device Linking Engine
# -----------------------------------------------------------------------------
def evaluate_linking_rules(source_node, decoded_dict):
    try:
        con_nodes = sqlite3.connect(DB_NODES_PATH, timeout=5)
        cur_nodes = con_nodes.cursor()
        cur_nodes.execute("""
            SELECT link_id, name, source_node, trigger_field, operator, threshold_val,
                   target_node, action_type, action_payload, turnaround_delay_ms, cooldown_sec,
                   last_triggered
            FROM node_links
            WHERE enabled = 1 AND source_node = ?
        """, (source_node,))
        rules = cur_nodes.fetchall()
        con_nodes.close()
    except Exception as e:
        return

    now = time.time()
    for rule in rules:
        (link_id, name, src, trigger_field, op, thresh, target_node,
         action_type, action_payload, turnaround_ms, cooldown_sec, last_trig_str) = rule

        if last_trig_str:
            try:
                last_trig_t = datetime.strptime(last_trig_str, "%Y-%m-%d %H:%M:%S").timestamp()
                if (now - last_trig_t) < (cooldown_sec or 30):
                    continue
            except Exception:
                pass

        current_val = None
        if trigger_field in decoded_dict:
            current_val = decoded_dict[trigger_field]
        elif trigger_field == "any":
            current_val = 1
        elif "val" in decoded_dict:
            current_val = decoded_dict["val"]

        if current_val is None:
            continue

        try:
            val_num = float(str(current_val).replace("°C", "").replace("V", "").strip())
        except ValueError:
            val_num = None

        trigger_match = False
        if op == "always" or trigger_field == "any":
            trigger_match = True
        elif val_num is not None:
            if op == ">" and val_num > thresh:
                trigger_match = True
            elif op == "<" and val_num < thresh:
                trigger_match = True
            elif op == "==" and abs(val_num - thresh) < 0.001:
                trigger_match = True
            elif op == "!=" and abs(val_num - thresh) >= 0.001:
                trigger_match = True

        if trigger_match:
            print(f"[RULE-FIRED] Rule '{name}' triggered by {src}.{trigger_field}={current_val} (target: {target_node})")
            now_str = datetime.utcnow().strftime("%Y-%m-%d %H:%M:%S")
            try:
                con_u = sqlite3.connect(DB_NODES_PATH, timeout=5)
                con_u.execute("UPDATE node_links SET last_triggered = ?, last_status = 'TRIGGERED' WHERE link_id = ?", (now_str, link_id))
                con_u.commit()
                con_u.close()
            except Exception:
                pass

            if turnaround_ms and turnaround_ms > 0:
                time.sleep(turnaround_ms / 1000.0)

            dispatch_lora_downlink(target_node, action_payload)


# -----------------------------------------------------------------------------
# Home Assistant MQTT Bridge & Supervisor
# -----------------------------------------------------------------------------
class MqttBridgeSupervisor(threading.Thread):
    def __init__(self, tracker=None):
        super().__init__(daemon=True)
        self.client = None
        self.connected = False
        self.gw_eui = "0016C001F1500B48"
        self.tracker = tracker or g_tracker
        self.lock = threading.Lock()

    def run(self):
        while True:
            cfg = load_config()
            m_cfg = cfg.get("mqtt", {})
            if not m_cfg.get("enabled", False) or not PAHO_AVAILABLE:
                time.sleep(5)
                continue

            host = m_cfg.get("server", "127.0.0.1")
            port = int(m_cfg.get("port", 1883))
            user = m_cfg.get("user", "")
            passwd = m_cfg.get("password", "")

            try:
                print(f"[MQTT] Connecting to broker {host}:{port}...")
                self.client = mqtt.Client(client_id=f"bobcat_lora_{int(time.time())}")
                if user and passwd:
                    self.client.username_pw_set(user, passwd)
                self.client.on_connect = self.on_connect
                self.client.on_disconnect = self.on_disconnect
                self.client.on_message = self.on_message

                self.client.connect(host, port, keepalive=60)
                self.client.loop_start()

                while self.connected:
                    time.sleep(10)
                    pipeline = load_config().get("pipeline", {})
                    if pipeline.get("ha_gateway_telemetry_enabled", True):
                        self.publish_gateway_telemetry()
                    if pipeline.get("ha_discovery_enabled", True):
                        self.sync_all_discovery()

                self.client.loop_stop()
            except Exception as e:
                print(f"[MQTT-CONN-ERR] {e}")
                time.sleep(5)

    def on_connect(self, client, userdata, flags, rc):
        if rc == 0:
            print("[MQTT] Successfully connected to MQTT broker!")
            self.connected = True
            cfg = load_config()
            m_cfg = cfg.get("mqtt", {})
            pipeline = cfg.get("pipeline", {})
            topic_root = m_cfg.get("state_prefix", "lora")
            client.subscribe(f"{topic_root}/+/set")
            client.subscribe(f"{topic_root}/gateways/+/set")
            client.subscribe(f"{topic_root}/gateway/restart")
            if pipeline.get("ha_discovery_enabled", True):
                self.publish_gateway_discovery()
                self.sync_all_discovery()
            if pipeline.get("ha_gateway_telemetry_enabled", True):
                self.publish_gateway_telemetry()
        else:
            print(f"[MQTT] Connection rejected (rc={rc})")
            self.connected = False

    def on_disconnect(self, client, userdata, rc):
        print(f"[MQTT] Disconnected from broker (rc={rc})")
        self.connected = False

    def on_message(self, client, userdata, msg):
        topic = msg.topic
        payload = msg.payload.decode("utf-8", errors="replace").strip()
        print(f"[MQTT-IN] Topic: {topic} | Payload: {payload}")

        cfg = load_config()
        m_cfg = cfg.get("mqtt", {})
        topic_root = m_cfg.get("state_prefix", "lora")

        if topic == f"{topic_root}/gateway/restart":
            print("[MQTT] Concentrator restart requested from Home Assistant!")
            os.system("systemctl restart raw-lora")
            return

        prefix = f"{topic_root}/"
        suffix = "/set"
        if topic.startswith(prefix) and topic.endswith(suffix):
            inner = topic[len(prefix):-len(suffix)]
            if inner.startswith("gateways/"):
                parts = inner.split("/")
                node_id = parts[-1].upper()
            else:
                node_id = inner.upper()
            print(f"[MQTT-CMD] Downlink dispatch for node {node_id}: {payload}")
            dispatch_lora_downlink(node_id, payload)
            state_val = "ON" if (payload in ("ON", "1", "0101")) else "OFF"
            self.publish(f"{topic_root}/{node_id}/state", json.dumps({"state": state_val, "last_cmd": payload}), retain=True)

    def publish(self, topic, payload, retain=False):
        if self.client and self.connected:
            try:
                self.client.publish(topic, payload, retain=retain)
            except Exception as e:
                print(f"[MQTT-PUB-ERR] {e}")

    def query_gateway_status(self):
        try:
            s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            s.settimeout(2.0)
            s.connect(("127.0.0.1", STATUS_PORT))
            raw = s.recv(2048).decode("utf-8")
            s.close()
            data = json.loads(raw)
            if "eui" in data and data["eui"]:
                self.gw_eui = data["eui"]
            return data
        except Exception:
            return {}

    def publish_gateway_telemetry(self):
        cfg = load_config()
        m_cfg = cfg.get("mqtt", {})
        topic_root = m_cfg.get("state_prefix", "lora")
        stat = self.query_gateway_status()

        if self.tracker:
            self.tracker.update_main_status(stat)

        # 1. Legacy Gateway state (backward compatible for standard single-GW dashboards)
        active_nodes = 0
        try:
            con = sqlite3.connect(DB_NODES_PATH, timeout=2)
            cur = con.cursor()
            cur.execute("SELECT count(*) FROM node_settings WHERE is_configured = 1")
            active_nodes = cur.fetchone()[0]
            con.close()
        except Exception:
            pass

        telemetry = {
            "gateway_id": self.gw_eui,
            "temp_c": stat.get("temp_c", 30.0),
            "rx": stat.get("rx", 0),
            "tx": stat.get("tx", 0),
            "crc_err": stat.get("crc_err", 0),
            "rx_status": stat.get("rx_status", "LISTENING"),
            "tx_status": stat.get("tx_status", "TX_FREE"),
            "uptime_s": stat.get("uptime_s", 0),
            "active_nodes": active_nodes
        }
        self.publish(f"{topic_root}/gateway/state", json.dumps(telemetry), retain=True)

        # 2. Publish EACH Concentrator (Main + Satellites) with its ID and EMBEDDED NODE TELEMETRIES
        if self.tracker:
            concentrators = self.tracker.get_all()
            for gid in concentrators.keys():
                self.publish_concentrator_state(gid)

    def publish_concentrator_state(self, gw_id):
        if not self.tracker or not self.client or not self.connected:
            return
        cfg = load_config()
        m_cfg = cfg.get("mqtt", {})
        topic_root = m_cfg.get("state_prefix", "lora")
        concentrators = self.tracker.get_all()
        gw = concentrators.get(gw_id)
        if not gw:
            return

        payload = {
            "gateway_id": gw["gateway_id"],
            "gateway_name": gw["name"],
            "gateway_ip": gw["ip"],
            "type": gw["type"],
            "protocol": gw["protocol"],
            "status": gw["status"],
            "uptime_s": gw.get("uptime_s", 0),
            "rx_count": gw.get("rx_count", 0),
            "crc_err": gw.get("crc_err", 0),
            "last_seen": gw.get("last_seen", ""),
            "nodes_count": len(gw.get("nodes", {})),
            "nodes": gw.get("nodes", {})
        }

        # Dedicated topic: lora/gateways/<gateway_id>/state
        self.publish(f"{topic_root}/gateways/{gw_id}/state", json.dumps(payload), retain=True)
        # Convenient alias: lora/<gateway_id>/state
        self.publish(f"{topic_root}/{gw_id}/state", json.dumps(payload), retain=True)
        print(f"[MQTT] Published Concentrator [{gw_id}] to {topic_root}/gateways/{gw_id}/state ({len(gw.get('nodes', {}))} nodes embedded)")

    def publish_node_telemetry(self, node_id, metrics, gw_id=None):
        cfg = load_config()
        m_cfg = cfg.get("mqtt", {})
        topic_root = m_cfg.get("state_prefix", "lora")
        # Global node state topic: lora/<node_id>/state
        self.publish(f"{topic_root}/{node_id}/state", json.dumps(metrics), retain=True)
        # Gateway-specific node state topic: lora/gateways/<gw_id>/nodes/<node_id>/state
        if gw_id:
            self.publish(f"{topic_root}/gateways/{gw_id}/nodes/{node_id}/state", json.dumps(metrics), retain=True)

    def publish_gateway_discovery(self):
        cfg = load_config()
        m_cfg = cfg.get("mqtt", {})
        ha_pfx = m_cfg.get("discovery_prefix", "homeassistant")
        topic_root = m_cfg.get("state_prefix", "lora")
        gw_id = self.gw_eui.lower()
        state_topic = f"{topic_root}/gateway/state"

        gw_device = {
            "identifiers": [f"bobcat_gateway_{gw_id}"],
            "name": "Bobcat LoRa Gateway",
            "model": "Bobcat Miner 300 (SX1302 8-CH)",
            "manufacturer": "Bobcat / Rockchip",
            "sw_version": "v2.2.0"
        }

        self.publish(f"{ha_pfx}/sensor/bobcat_gw_{gw_id}/temp/config", json.dumps({
            "name": "Concentrator Temperature",
            "unique_id": f"bobcat_gw_{gw_id}_temp",
            "state_topic": state_topic,
            "value_template": "{{ value_json.temp_c | default(none) }}",
            "unit_of_measurement": "°C",
            "device_class": "temperature",
            "device": gw_device
        }), retain=True)

        self.publish(f"{ha_pfx}/sensor/bobcat_gw_{gw_id}/rx/config", json.dumps({
            "name": "LoRa Uplinks Received",
            "unique_id": f"bobcat_gw_{gw_id}_rx",
            "state_topic": state_topic,
            "value_template": "{{ value_json.rx | default(0) }}",
            "device": gw_device
        }), retain=True)

        self.publish(f"{ha_pfx}/button/bobcat_gw_{gw_id}/restart/config", json.dumps({
            "name": "Restart LoRa Concentrator",
            "unique_id": f"bobcat_gw_{gw_id}_restart",
            "command_topic": f"{topic_root}/gateway/restart",
            "payload_press": "PRESS",
            "device_class": "restart",
            "device": gw_device
        }), retain=True)

        # Also register all individual concentrators in Home Assistant
        if self.tracker:
            concentrators = self.tracker.get_all()
            for gid, gw in concentrators.items():
                safe_id = gid.lower()
                c_device = {
                    "identifiers": [f"bobcat_gw_{safe_id}"],
                    "name": f"Concentrator {gw['name']}",
                    "model": f"{gw['protocol']} ({gw['type'].capitalize()})",
                    "manufacturer": "Bobcat LoRa Core",
                    "sw_version": "v2.2.0"
                }
                c_topic = f"{topic_root}/gateways/{gid}/state"

                self.publish(f"{ha_pfx}/sensor/bobcat_gw_{safe_id}/status/config", json.dumps({
                    "name": "Status",
                    "unique_id": f"bobcat_gw_{safe_id}_status",
                    "state_topic": c_topic,
                    "value_template": "{{ value_json.status | default('ONLINE') }}",
                    "device": c_device
                }), retain=True)

                self.publish(f"{ha_pfx}/sensor/bobcat_gw_{safe_id}/rx/config", json.dumps({
                    "name": "Packets Ingested",
                    "unique_id": f"bobcat_gw_{safe_id}_rx",
                    "state_topic": c_topic,
                    "value_template": "{{ value_json.rx_count | default(0) }}",
                    "device": c_device
                }), retain=True)

                self.publish(f"{ha_pfx}/sensor/bobcat_gw_{safe_id}/nodes/config", json.dumps({
                    "name": "Active Nodes Heard",
                    "unique_id": f"bobcat_gw_{safe_id}_nodes",
                    "state_topic": c_topic,
                    "value_template": "{{ value_json.nodes_count | default(0) }}",
                    "json_attributes_topic": c_topic,
                    "json_attributes_template": "{{ value_json.nodes | default({}) | tojson }}",
                    "device": c_device
                }), retain=True)

    def sync_all_discovery(self):
        cfg = load_config()
        m_cfg = cfg.get("mqtt", {})
        ha_pfx = m_cfg.get("discovery_prefix", "homeassistant")
        topic_root = m_cfg.get("state_prefix", "lora")
        gw_id = self.gw_eui.lower()

        try:
            con = sqlite3.connect(DB_NODES_PATH, timeout=5)
            con.row_factory = sqlite3.Row
            cur = con.cursor()
            cur.execute("SELECT * FROM node_settings WHERE ha_enabled = 1 AND is_configured = 1")
            active_nodes = cur.fetchall()
            cur.execute("SELECT node_id FROM node_settings WHERE ha_enabled = 0 OR is_configured = 0")
            purged_ids = [r["node_id"] for r in cur.fetchall()]
            con.close()
        except Exception as e:
            return

        for node in active_nodes:
            nid = node["node_id"]
            name = node["name"] or f"LoRa Node {nid}"
            cls = (node["node_class"] or "A").upper()
            model = node["model"] or ("LoRa Actuator (Class C)" if cls == "C" else "LoRa Sensor (Class A)")
            area = node["group_name"] if node["group_name"] not in ("Default", "Unassigned", "") else None
            state_topic = f"{topic_root}/{nid}/state"

            dev_obj = {
                "identifiers": [f"lora_{nid}"],
                "name": name,
                "model": model,
                "manufacturer": "Bobcat LoRa Gateway",
                "suggested_area": area,
                "sw_version": "v2.2.0",
                "via_device": f"bobcat_gateway_{gw_id}"
            }

            # Temperature
            self.publish(f"{ha_pfx}/sensor/lora_{nid}/temp/config", json.dumps({
                "name": "Temperature",
                "has_entity_name": True,
                "unique_id": f"lora_{nid}_temperature",
                "state_topic": state_topic,
                "value_template": "{{ value_json.temperature | default(none) }}",
                "unit_of_measurement": "°C",
                "device_class": "temperature",
                "state_class": "measurement",
                "device": dev_obj
            }), retain=True)

            # Battery Voltage
            self.publish(f"{ha_pfx}/sensor/lora_{nid}/batt/config", json.dumps({
                "name": "Battery Voltage",
                "has_entity_name": True,
                "unique_id": f"lora_{nid}_battery",
                "state_topic": state_topic,
                "value_template": "{{ value_json.battery | default(none) }}",
                "unit_of_measurement": "V",
                "device_class": "voltage",
                "state_class": "measurement",
                "device": dev_obj
            }), retain=True)

            # Accelerometer X, Y, Z
            for axis in ("x", "y", "z"):
                self.publish(f"{ha_pfx}/sensor/lora_{nid}/accel_{axis}/config", json.dumps({
                    "name": f"Acceleration {axis.upper()}",
                    "has_entity_name": True,
                    "unique_id": f"lora_{nid}_accel_{axis}",
                    "state_topic": state_topic,
                    "value_template": f"{{{{ value_json.accel_{axis} | default(none) }}}}",
                    "unit_of_measurement": "g",
                    "icon": "mdi:axis-arrow",
                    "device": dev_obj
                }), retain=True)

            # Signal RSSI & SNR
            self.publish(f"{ha_pfx}/sensor/lora_{nid}/rssi/config", json.dumps({
                "name": "Signal RSSI",
                "has_entity_name": True,
                "unique_id": f"lora_{nid}_rssi",
                "state_topic": state_topic,
                "value_template": "{{ value_json.rssi | default(none) }}",
                "unit_of_measurement": "dBm",
                "device_class": "signal_strength",
                "entity_category": "diagnostic",
                "device": dev_obj
            }), retain=True)

            self.publish(f"{ha_pfx}/sensor/lora_{nid}/snr/config", json.dumps({
                "name": "Signal SNR",
                "has_entity_name": True,
                "unique_id": f"lora_{nid}_snr",
                "state_topic": state_topic,
                "value_template": "{{ value_json.snr | default(none) }}",
                "unit_of_measurement": "dB",
                "entity_category": "diagnostic",
                "device": dev_obj
            }), retain=True)

            # Switch (Class C)
            if cls == "C" or any(w in model.lower() for w in ("valve", "relay", "actuator")):
                self.publish(f"{ha_pfx}/switch/lora_{nid}/switch/config", json.dumps({
                    "name": "Actuator",
                    "has_entity_name": True,
                    "unique_id": f"lora_{nid}_switch",
                    "state_topic": state_topic,
                    "command_topic": f"{topic_root}/{nid}/set",
                    "value_template": "{{ value_json.state | default('OFF') }}",
                    "payload_on": "ON",
                    "payload_off": "OFF",
                    "state_on": "ON",
                    "state_off": "OFF",
                    "device": dev_obj
                }), retain=True)

        for nid in purged_ids:
            for comp, key in [("sensor", "temp"), ("sensor", "batt"), ("sensor", "rssi"), ("sensor", "snr"), ("switch", "switch"), ("sensor", "accel_x"), ("sensor", "accel_y"), ("sensor", "accel_z")]:
                self.publish(f"{ha_pfx}/{comp}/lora_{nid}/{key}/config", "", retain=True)

    def publish_node_telemetry(self, node_id, metrics, gw_id=None):
        cfg = load_config()
        m_cfg = cfg.get("mqtt", {})
        topic_root = m_cfg.get("state_prefix", "lora")
        # Global node state topic: lora/<node_id>/state
        self.publish(f"{topic_root}/{node_id}/state", json.dumps(metrics), retain=True)
        # Gateway-specific node state topic: lora/gateways/<gw_id>/nodes/<node_id>/state
        if gw_id:
            self.publish(f"{topic_root}/gateways/{gw_id}/nodes/{node_id}/state", json.dumps(metrics), retain=True)


# -----------------------------------------------------------------------------
# Hardware Watchdog Thread
# -----------------------------------------------------------------------------
def raw_lora_watchdog_thread():
    while True:
        time.sleep(3)
        try:
            s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            s.settimeout(1.0)
            res = s.connect_ex(('127.0.0.1', STATUS_PORT))
            s.close()
            if res != 0:
                try:
                    with open("/sys/class/leds/red:status/brightness", "w") as f: f.write("1")
                    with open("/sys/class/leds/blue:status/brightness", "w") as f: f.write("0")
                    with open("/sys/class/leds/green:status/brightness", "w") as f: f.write("0")
                except Exception:
                    pass
        except Exception:
            pass


# -----------------------------------------------------------------------------
# Main Ingestion UDP Loop (Dual-Port: 5555 JSON & 1700 Semtech Forwarders)
# -----------------------------------------------------------------------------
def main():
    print("============================================================")
    print(f"Bobcat LoRa Bridge & Ingestion Daemon Starting (UDP :{PORT_UP} & :{PORT_SEMTECH})")
    print("============================================================")

    os.system("/usr/local/bin/lora_db_init.sh >/dev/null 2>&1")
    threading.Thread(target=raw_lora_watchdog_thread, daemon=True).start()

    mqtt_super = MqttBridgeSupervisor(tracker=g_tracker)
    mqtt_super.start()

    # 1. Standard Raw JSON UDP socket (Local SX1302 + JSON satellites)
    sock_5555 = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock_5555.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    sock_5555.bind(("0.0.0.0", PORT_UP))
    print(f"[BRIDGE] Listening for local SX1302 & JSON forwarders on UDP port {PORT_UP}...")

    # 2. Semtech Standard UDP Packet Forwarder socket (Dragino, RAK, Mikrotik satellites)
    sock_1700 = None
    try:
        sock_1700 = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        sock_1700.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        sock_1700.bind(("0.0.0.0", PORT_SEMTECH))
        print(f"[BRIDGE] Listening for Semtech UDP forwarders on UDP port {PORT_SEMTECH}...")
    except Exception as e:
        print(f"[BRIDGE-WARN] Could not bind Semtech port {PORT_SEMTECH}: {e}")

    schemes, global_rule = load_decoders()
    last_reload = time.time()

    while True:
        try:
            read_socks = [sock_5555]
            if sock_1700:
                read_socks.append(sock_1700)

            readable, _, _ = select.select(read_socks, [], [], 1.0)
            if not readable:
                continue

            for s in readable:
                data, addr = s.recvfrom(4096)
                if not data:
                    continue

                sender_ip = addr[0]
                sender_port = addr[1]

                # --- 1. Ingress Protocol Demux ---
                if s == sock_1700:
                    # Standard Semtech Packet Forwarder protocol
                    if len(data) < 4:
                        continue
                    version = data[0]
                    token = data[1:3]
                    ident = data[3]
                    gw_eui = data[4:12].hex().upper() if len(data) >= 12 else f"SAT_{sender_ip.replace('.', '_')}"

                    if ident == 0x02:  # PULL_DATA (keepalive heartbeat from satellite)
                        try:
                            s.sendto(bytes([version, token[0], token[1], 0x04]), addr)  # PULL_ACK
                        except Exception:
                            pass
                        g_tracker.register_heartbeat(gw_eui, f"Satellite {gw_eui}", sender_ip, sender_port, "Semtech UDP 1700")
                        continue

                    elif ident == 0x00:  # PUSH_DATA (uplink RF frame)
                        try:
                            s.sendto(bytes([version, token[0], token[1], 0x01]), addr)  # PUSH_ACK
                        except Exception:
                            pass
                        if len(data) <= 12:
                            continue
                        try:
                            msg = json.loads(data[12:].decode("utf-8", errors="replace"))
                        except Exception:
                            continue
                        sender_gw_id = gw_eui
                        sender_gw_name = f"Satellite Gateway ({gw_eui})"
                        sender_protocol = "Semtech UDP 1700"
                    else:
                        continue

                else:  # sock_5555
                    try:
                        msg = json.loads(data.decode("utf-8", errors="replace"))
                    except Exception:
                        continue

                    if sender_ip == "127.0.0.1":
                        sender_gw_id = g_tracker.main_eui
                        sender_gw_name = "Bobcat Main Concentrator"
                        sender_protocol = "Local SX1302 SPI"
                    else:
                        sender_gw_id = msg.get("gateway_id") or msg.get("eui") or f"SAT_{sender_ip.replace('.', '_')}"
                        sender_gw_name = f"Satellite Gateway ({sender_ip})"
                        sender_protocol = "JSON UDP 5555"

                # Check decoders reload
                if time.time() - last_reload > 3:
                    schemes, global_rule = load_decoders()
                    last_reload = time.time()

                cfg = load_config()
                pipeline = cfg.get("pipeline", {})
                dec_enabled = pipeline.get("decoding_enabled", True)
                ha_telemetry_enabled = pipeline.get("ha_telemetry_enabled", True)
                sqlite_logging_enabled = pipeline.get("sqlite_logging_enabled", True)
                linking_enabled = pipeline.get("linking_enabled", True)
                filter_unregistered = pipeline.get("filter_unregistered_nodes", False)

                rxpk_list = msg.get("rxpk", [])
                for pkt in rxpk_list:
                    # 1. Hardware CRC Gate
                    stat_val = pkt.get("stat", 1)
                    status_str = pkt.get("status", "")
                    if stat_val == -1 or status_str == "CRC_BAD":
                        print(f"[CRC-DROP] Gateway [{sender_gw_id}]: Corrupted packet dropped (stat={stat_val}, status={status_str})")
                        continue

                    b64_str = pkt.get("data", "")
                    if not b64_str:
                        continue
                    try:
                        raw_bytes = base64.b64decode(b64_str)
                        raw_hex = raw_bytes.hex().upper()
                    except Exception:
                        continue

                    # 2. Multi-Scheme Decoder Engine (Feature Toggle: decoding_enabled)
                    scheme_id, scheme_name, decoded = execute_decoder(raw_bytes, raw_hex, schemes, dec_enabled=dec_enabled)

                    # 3. Extract Node ID
                    node_id = extract_node_id(raw_bytes, raw_hex, decoded, schemes, global_rule)

                    # 4. Strict Registered Node Filter (Feature Toggle: filter_unregistered_nodes)
                    if filter_unregistered and not is_node_registered(node_id):
                        print(f"[GATE-DROP] Gateway [{sender_gw_id}]: Node [{node_id}] rejected by unregistered filter")
                        continue

                    # Attach RF & Gateway Metadata to decoded payload
                    telemetry_payload = dict(decoded)
                    telemetry_payload["rssi"] = pkt.get("rssic", pkt.get("rssi", -100.0))
                    telemetry_payload["snr"] = pkt.get("lsnr", pkt.get("snr", 0.0))
                    telemetry_payload["freq"] = pkt.get("freq", 868.1)
                    telemetry_payload["datr"] = pkt.get("datr", "SF7BW125")
                    telemetry_payload["hex"] = raw_hex
                    telemetry_payload["gateway_id"] = sender_gw_id
                    telemetry_payload["gateway_name"] = sender_gw_name
                    telemetry_payload["gateway_ip"] = sender_ip
                    telemetry_payload["last_seen"] = datetime.utcnow().strftime("%Y-%m-%d %H:%M:%S")

                    # 5. Record into Concentrator Tracker (Embeds node telemetry inside this gateway!)
                    actual_gw_id, actual_name, _ = g_tracker.record_uplink(
                        sender_gw_id, sender_gw_name, sender_ip, sender_port, sender_protocol,
                        node_id, telemetry_payload, raw_hex=raw_hex
                    )

                    print(f"[UPLINK] Concentrator [{actual_gw_id}] heard Node [{node_id}] | Scheme: {scheme_name} | RSSI: {telemetry_payload['rssi']} dBm | Hex: {raw_hex}")
                    print(f"         Decoded: {decoded}")

                    # 6. Database Logging (Feature Toggle: sqlite_logging_enabled)
                    if sqlite_logging_enabled:
                        record_to_databases(node_id, pkt, raw_hex, decoded)
                    else:
                        print(f"[DB-SKIP] SQLite persistence disabled by toggle for [{node_id}]")

                    # 7. Home Assistant MQTT Telemetry (Every gateway reports with its ID & embedded nodes!)
                    if ha_telemetry_enabled:
                        # Publishes node telemetry (tagged with gateway_id) to lora/<node_id>/state and lora/gateways/<gw_id>/nodes/<node_id>/state
                        mqtt_super.publish_node_telemetry(node_id, telemetry_payload, gw_id=actual_gw_id)
                        # Publishes the gateway state with EMBEDDED NODE TELEMETRIES to lora/gateways/<gw_id>/state
                        mqtt_super.publish_concentrator_state(actual_gw_id)
                    else:
                        print(f"[MQTT-SKIP] HA Telemetry disabled by toggle for [{node_id}]")

                    # 8. Edge Device Linking Rules (Feature Toggle: linking_enabled)
                    if linking_enabled:
                        evaluate_linking_rules(node_id, decoded)
                    else:
                        print(f"[LINK-SKIP] Edge linking disabled by toggle for [{node_id}]")

        except KeyboardInterrupt:
            print("[BRIDGE] Exiting on SIGINT.")
            break
        except Exception as e:
            print(f"[BRIDGE-ERR] {e}")
            time.sleep(0.5)


if __name__ == "__main__":
    main()
