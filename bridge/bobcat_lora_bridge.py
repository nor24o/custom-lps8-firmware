#!/usr/bin/env python3
"""
bobcat_lora_bridge.py - Industrial LoRa Ingestion, Decoder, SQLite, and Home Assistant MQTT Bridge
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
DB_NODES_PATH = "/etc/lora/nodes.db"
DB_RAM_PATH = "/tmp/lora_messages.db"
PACKETS_JSON = "/tmp/lora_packets.json"

PORT_UP = 5555
PORT_DOWN = 5556
STATUS_PORT = 5557

try:
    import paho.mqtt.client as mqtt
    PAHO_AVAILABLE = True
except ImportError:
    PAHO_AVAILABLE = False


# -----------------------------------------------------------------------------
# Configuration Loader
# -----------------------------------------------------------------------------
def load_config():
    try:
        with open(CONFIG_PATH, "r", encoding="utf-8") as f:
            return json.load(f)
    except Exception as e:
        print(f"[WARN] Failed to read {CONFIG_PATH}: {e}")
        return {}


def load_decoders():
    try:
        with open(DECODERS_PATH, "r", encoding="utf-8") as f:
            return json.load(f).get("schemes", [])
    except Exception as e:
        print(f"[WARN] Failed to read {DECODERS_PATH}: {e}")
        return []


# -----------------------------------------------------------------------------
# Payload Decoders Engine
# -----------------------------------------------------------------------------
def is_printable_ascii(raw_bytes):
    if len(raw_bytes) < 2:
        return False
    return all((32 <= b <= 126) or b in (9, 10, 13) for b in raw_bytes)


def decode_cayenne_lpp(raw_bytes):
    out = {}
    i = 0
    parsed_any = False
    n = len(raw_bytes)

    while i < n:
        ch = raw_bytes[i]
        i += 1
        if i >= n:
            break
        type_code = raw_bytes[i]
        i += 1
        pfx = f"ch{ch}_"

        if type_code == 0x00:  # Digital Input (1B)
            if i >= n:
                break
            out[f"{pfx}digital_in"] = raw_bytes[i]
            i += 1
            parsed_any = True
        elif type_code == 0x01:  # Digital Output (1B)
            if i >= n:
                break
            out[f"{pfx}digital_out"] = raw_bytes[i]
            i += 1
            parsed_any = True
        elif type_code == 0x02:  # Analog Input (2B, 0.01 signed)
            if i + 1 >= n:
                break
            val = struct.unpack(">h", raw_bytes[i:i+2])[0]
            i += 2
            out[f"{pfx}analog_in"] = round(val * 0.01, 2)
            parsed_any = True
        elif type_code == 0x03:  # Analog Output (2B, 0.01 signed)
            if i + 1 >= n:
                break
            val = struct.unpack(">h", raw_bytes[i:i+2])[0]
            i += 2
            out[f"{pfx}analog_out"] = round(val * 0.01, 2)
            parsed_any = True
        elif type_code == 0x65:  # Illuminance (2B, 1 Lux)
            if i + 1 >= n:
                break
            val = struct.unpack(">H", raw_bytes[i:i+2])[0]
            i += 2
            out[f"{pfx}illuminance_lux"] = val
            parsed_any = True
        elif type_code == 0x66:  # Presence (1B)
            if i >= n:
                break
            out[f"{pfx}presence"] = raw_bytes[i]
            i += 1
            parsed_any = True
        elif type_code == 0x67:  # Temperature (2B, 0.1 °C signed)
            if i + 1 >= n:
                break
            val = struct.unpack(">h", raw_bytes[i:i+2])[0]
            i += 2
            val_c = round(val * 0.1, 1)
            out[f"{pfx}temperature_c"] = val_c
            out["temperature"] = val_c
            parsed_any = True
        elif type_code == 0x68:  # Humidity (1B, 0.5 %)
            if i >= n:
                break
            val_h = round(raw_bytes[i] * 0.5, 1)
            i += 1
            out[f"{pfx}humidity_pct"] = val_h
            out["humidity"] = val_h
            parsed_any = True
        elif type_code == 0x73:  # Barometer (2B, 0.1 hPa)
            if i + 1 >= n:
                break
            val = struct.unpack(">H", raw_bytes[i:i+2])[0]
            i += 2
            out[f"{pfx}barometer_hpa"] = round(val * 0.1, 1)
            out["pressure"] = round(val * 0.1, 1)
            parsed_any = True
        elif type_code == 0x88:  # GPS (9B)
            if i + 8 >= n:
                break
            lat_raw = (raw_bytes[i] << 16) | (raw_bytes[i+1] << 8) | raw_bytes[i+2]
            if lat_raw & 0x800000:
                lat_raw -= 0x1000000
            lon_raw = (raw_bytes[i+3] << 16) | (raw_bytes[i+4] << 8) | raw_bytes[i+5]
            if lon_raw & 0x800000:
                lon_raw -= 0x1000000
            alt_raw = (raw_bytes[i+6] << 16) | (raw_bytes[i+7] << 8) | raw_bytes[i+8]
            if alt_raw & 0x800000:
                alt_raw -= 0x1000000
            i += 9
            out[f"{pfx}gps"] = {
                "latitude": round(lat_raw * 0.0001, 4),
                "longitude": round(lon_raw * 0.0001, 4),
                "altitude_m": round(alt_raw * 0.01, 2)
            }
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
            out[name] = raw_bytes[off:end].hex()
            continue

        if ftype == "ascii":
            end = min(off + flen, n)
            try:
                out[name] = raw_bytes[off:end].decode("ascii", errors="replace")
            except Exception:
                out[name] = raw_bytes[off:end].hex()
            continue

        val = 0
        try:
            if ftype == "uint8":
                val = raw_bytes[off]
            elif ftype == "int8":
                val = struct.unpack("b", raw_bytes[off:off+1])[0]
            elif ftype == "uint16_be":
                val = struct.unpack(">H", raw_bytes[off:off+2])[0]
            elif ftype == "uint16_le":
                val = struct.unpack("<H", raw_bytes[off:off+2])[0]
            elif ftype == "int16_be":
                val = struct.unpack(">h", raw_bytes[off:off+2])[0]
            elif ftype == "int16_le":
                val = struct.unpack("<h", raw_bytes[off:off+2])[0]
            elif ftype == "uint32_be":
                val = struct.unpack(">I", raw_bytes[off:off+4])[0]
            elif ftype == "uint32_le":
                val = struct.unpack("<I", raw_bytes[off:off+4])[0]
            computed = round((val * scale) + add, 3)
            out[name] = computed
            if unit:
                out[f"{name}_unit"] = unit
        except Exception:
            pass
    return out


def decode_aa0b(raw_bytes, hex_str):
    # AA0B scheme: [0..1]=AA0B, [2..3]=seq, [4..5]=temp_raw/10, [6..7]=volt_raw/1000
    if len(raw_bytes) < 8:
        return {"raw_hex": hex_str}
    seq = (raw_bytes[2] << 8) | raw_bytes[3]
    temp_raw = struct.unpack(">h", raw_bytes[4:6])[0]
    volt_raw = (raw_bytes[6] << 8) | raw_bytes[7]
    temp_c = round(temp_raw / 10.0, 1)
    volt_v = round(volt_raw / 1000.0, 2)
    return {
        "node_type": "AA0B",
        "seq": seq,
        "temperature": temp_c,
        "battery": volt_v,
        "battery_mv": volt_raw,
        "extra": hex_str[16:]
    }


def decode_aa0c(raw_bytes, hex_str):
    # AA0C scheme: [0..1]=AA0C, [2..3]=seq, [4..5]=sensor_val, [6..7]=volt_raw/1000
    if len(raw_bytes) < 8:
        return {"raw_hex": hex_str}
    seq = (raw_bytes[2] << 8) | raw_bytes[3]
    sensor_raw = (raw_bytes[4] << 8) | raw_bytes[5]
    volt_raw = (raw_bytes[6] << 8) | raw_bytes[7]
    volt_v = round(volt_raw / 1000.0, 2)
    return {
        "node_type": "AA0C",
        "seq": seq,
        "sensor_val": sensor_raw,
        "ch1_val": sensor_raw,
        "battery": volt_v,
        "battery_mv": volt_raw,
        "extra": hex_str[16:]
    }


def execute_decoder(raw_bytes, hex_str, schemes):
    clean_hex = hex_str.lower()
    for s in schemes:
        if not s.get("enabled", True):
            continue
        m_type = s.get("matchType", "default")
        m_val = str(s.get("matchValue", "")).strip().lower()

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
        elif m_type == "default":
            matched = True

        if matched:
            s_type = s.get("type", "js")
            s_id = s.get("id", "")
            if s_id == "scheme_aa0b" or clean_hex.startswith("aa0b"):
                return s_id, s.get("name", "AA0B"), decode_aa0b(raw_bytes, hex_str)
            elif s_id == "scheme_aa0c" or clean_hex.startswith("aa0c"):
                return s_id, s.get("name", "AA0C"), decode_aa0c(raw_bytes, hex_str)
            elif s_type == "ascii":
                return s_id, s.get("name", "ASCII"), {"text": raw_bytes.decode("ascii", errors="replace")}
            elif s_type == "cayenne_lpp":
                res = decode_cayenne_lpp(raw_bytes)
                if res:
                    return s_id, s.get("name", "Cayenne LPP"), res
            elif s_type == "fields":
                res = decode_fields_slicer(raw_bytes, s.get("fields", []))
                return s_id, s.get("name", "Fields"), res

    # Automatic fallback
    if clean_hex.startswith("aa0b"):
        return "scheme_aa0b", "Sensor Node AA0B", decode_aa0b(raw_bytes, hex_str)
    if clean_hex.startswith("aa0c"):
        return "scheme_aa0c", "Sensor Node AA0C", decode_aa0c(raw_bytes, hex_str)
    if is_printable_ascii(raw_bytes):
        return "fallback_ascii", "ASCII Text", {"text": raw_bytes.decode("ascii", errors="replace")}
    lpp = decode_cayenne_lpp(raw_bytes)
    if lpp:
        return "fallback_lpp", "Cayenne LPP", lpp

    return "raw", "Raw Payload", {"hex": hex_str}


def extract_node_id(raw_bytes, hex_str, decoded_data):
    clean_hex = hex_str.upper()
    if clean_hex.startswith("AA0B"):
        return "AA0B"
    if clean_hex.startswith("AA0C"):
        return "AA0C"
    if "node_type" in decoded_data and decoded_data["node_type"]:
        return str(decoded_data["node_type"]).upper()
    if len(raw_bytes) >= 4 and clean_hex.startswith("AA"):
        return f"{raw_bytes[0]:02X}{raw_bytes[1]:02X}"
    if len(clean_hex) >= 4:
        return clean_hex[:4]
    return "UNKNOWN"


# -----------------------------------------------------------------------------
# SQLite Database Storage & Auto-Registration
# -----------------------------------------------------------------------------
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

    # 1. Ephemeral DB (/tmp/lora_messages.db)
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

    # 2. Persistent DB (/etc/lora/nodes.db)
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
            default_model = "temperature_sensor" if node_id == "AA0B" else ("relay_valve" if node_id == "AA0C" else "generic")
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
        print(f"[LINK-ERR] {e}")
        return

    now = time.time()
    for rule in rules:
        (link_id, name, src, trigger_field, op, thresh, target_node,
         action_type, action_payload, turnaround_ms, cooldown_sec, last_trig_str) = rule

        # Check cooldown
        if last_trig_str:
            try:
                last_trig_t = datetime.strptime(last_trig_str, "%Y-%m-%d %H:%M:%S").timestamp()
                if (now - last_trig_t) < (cooldown_sec or 30):
                    continue
            except Exception:
                pass

        # Check condition
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

            # Optional turnaround delay
            if turnaround_ms and turnaround_ms > 0:
                time.sleep(turnaround_ms / 1000.0)

            # Dispatch action
            dispatch_lora_downlink(target_node, action_payload)

            # Log audit
            try:
                con_l = sqlite3.connect(DB_RAM_PATH, timeout=5)
                con_l.execute("""
                    INSERT INTO link_execution_logs (link_id, timestamp, event_type, source_node, target_node, tx_status, details)
                    VALUES (?, ?, 'AUTO_TRIGGER', ?, ?, 'DISPATCHED', ?)
                """, (link_id, now_str, src, target_node, f"Condition: {trigger_field} {op} {thresh} (val={current_val})"))
                con_l.commit()
                con_l.close()
            except Exception:
                pass


# -----------------------------------------------------------------------------
# Home Assistant MQTT Bridge & Supervisor
# -----------------------------------------------------------------------------
class MqttBridgeSupervisor(threading.Thread):
    def __init__(self):
        super().__init__(daemon=True)
        self.client = None
        self.connected = False
        self.gw_eui = "0016C001F1500B48"
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
                    self.publish_gateway_telemetry()
                    self.sync_all_discovery()
                    time.sleep(10)

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
            topic_root = m_cfg.get("state_prefix", "lora")
            client.subscribe(f"{topic_root}/+/set")
            client.subscribe(f"{topic_root}/gateway/restart")
            self.publish_gateway_discovery()
            self.sync_all_discovery()
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
            node_id = topic[len(prefix):-len(suffix)].upper()
            print(f"[MQTT-CMD] Downlink dispatch for node {node_id}: {payload}")
            dispatch_lora_downlink(node_id, payload)
            # Update state in HA immediately
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
            "sw_version": "v2.2.0",
            "configuration_url": "http://192.168.1.15/"
        }

        # Temperature
        self.publish(f"{ha_pfx}/sensor/bobcat_gw_{gw_id}/temp/config", json.dumps({
            "name": "Concentrator Temperature",
            "unique_id": f"bobcat_gw_{gw_id}_temp",
            "state_topic": state_topic,
            "value_template": "{{ value_json.temp_c | default(none) }}",
            "unit_of_measurement": "°C",
            "device_class": "temperature",
            "state_class": "measurement",
            "device": gw_device
        }), retain=True)

        # Uplinks Received
        self.publish(f"{ha_pfx}/sensor/bobcat_gw_{gw_id}/rx/config", json.dumps({
            "name": "LoRa Uplinks Received",
            "unique_id": f"bobcat_gw_{gw_id}_rx",
            "state_topic": state_topic,
            "value_template": "{{ value_json.rx | default(0) }}",
            "state_class": "total_increasing",
            "entity_category": "diagnostic",
            "icon": "mdi:radio-tower",
            "device": gw_device
        }), retain=True)

        # Downlinks Sent
        self.publish(f"{ha_pfx}/sensor/bobcat_gw_{gw_id}/tx/config", json.dumps({
            "name": "LoRa Downlinks Sent",
            "unique_id": f"bobcat_gw_{gw_id}_tx",
            "state_topic": state_topic,
            "value_template": "{{ value_json.tx | default(0) }}",
            "state_class": "total_increasing",
            "entity_category": "diagnostic",
            "icon": "mdi:transmit-tower",
            "device": gw_device
        }), retain=True)

        # Active Nodes
        self.publish(f"{ha_pfx}/sensor/bobcat_gw_{gw_id}/active_nodes/config", json.dumps({
            "name": "Active LoRa Nodes",
            "unique_id": f"bobcat_gw_{gw_id}_active_nodes",
            "state_topic": state_topic,
            "value_template": "{{ value_json.active_nodes | default(0) }}",
            "icon": "mdi:devices",
            "device": gw_device
        }), retain=True)

        # Concentrator Restart Button
        self.publish(f"{ha_pfx}/button/bobcat_gw_{gw_id}/restart/config", json.dumps({
            "name": "Restart LoRa Concentrator",
            "unique_id": f"bobcat_gw_{gw_id}_restart",
            "command_topic": f"{topic_root}/gateway/restart",
            "payload_press": "PRESS",
            "device_class": "restart",
            "entity_category": "config",
            "device": gw_device
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
            print(f"[HA-SYNC-ERR] {e}")
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

            # RSSI
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

            # SNR
            self.publish(f"{ha_pfx}/sensor/lora_{nid}/snr/config", json.dumps({
                "name": "Signal SNR",
                "has_entity_name": True,
                "unique_id": f"lora_{nid}_snr",
                "state_topic": state_topic,
                "value_template": "{{ value_json.snr | default(none) }}",
                "unit_of_measurement": "dB",
                "entity_category": "diagnostic",
                "icon": "mdi:signal-distance-variant",
                "device": dev_obj
            }), retain=True)

            # Actuator Switch (Class C or valve/relay)
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

        # Purge inactive
        for nid in purged_ids:
            for comp, key in [("sensor", "temp"), ("sensor", "batt"), ("sensor", "rssi"), ("sensor", "snr"), ("switch", "switch")]:
                self.publish(f"{ha_pfx}/{comp}/lora_{nid}/{key}/config", "", retain=True)

    def publish_node_telemetry(self, node_id, metrics):
        cfg = load_config()
        m_cfg = cfg.get("mqtt", {})
        topic_root = m_cfg.get("state_prefix", "lora")
        self.publish(f"{topic_root}/{node_id}/state", json.dumps(metrics), retain=True)


# -----------------------------------------------------------------------------
# Main Ingestion UDP Loop
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
                # raw_lora_app is not responding (broken/stopped) -> set solid RED
                try:
                    with open("/sys/class/leds/red:status/brightness", "w") as f:
                        f.write("1")
                    with open("/sys/class/leds/blue:status/brightness", "w") as f:
                        f.write("0")
                    with open("/sys/class/leds/green:status/brightness", "w") as f:
                        f.write("0")
                except Exception:
                    pass
        except Exception:
            pass


def main():
    print(f"============================================================")
    print(f"Bobcat LoRa Bridge & Ingestion Daemon Starting (UDP :{PORT_UP})")
    print(f"============================================================")

    # Initialize databases if needed
    os.system("/usr/local/bin/lora_db_init.sh >/dev/null 2>&1")

    # Start Concentrator Watchdog for Hardware Error LED indication
    threading.Thread(target=raw_lora_watchdog_thread, daemon=True).start()

    # Start MQTT Supervisor
    mqtt_super = MqttBridgeSupervisor()
    mqtt_super.start()

    # Bind UDP Socket for raw_lora_app uplinks
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    sock.bind(("0.0.0.0", PORT_UP))
    print(f"[BRIDGE] Listening for raw_lora_app uplinks on UDP port {PORT_UP}...")

    schemes = load_decoders()
    last_schemes_reload = time.time()

    while True:
        try:
            data, addr = sock.recvfrom(4096)
            if not data:
                continue

            # Reload decoders periodically or on mod
            if time.time() - last_schemes_reload > 10:
                schemes = load_decoders()
                last_schemes_reload = time.time()

            try:
                msg = json.loads(data.decode("utf-8", errors="replace"))
            except Exception:
                continue

            rxpk_list = msg.get("rxpk", [])
            for pkt in rxpk_list:
                b64_str = pkt.get("data", "")
                if not b64_str:
                    continue
                try:
                    raw_bytes = base64.b64decode(b64_str)
                    raw_hex = raw_bytes.hex().upper()
                except Exception:
                    continue

                # Run Multi-Scheme Decoder Engine
                scheme_id, scheme_name, decoded = execute_decoder(raw_bytes, raw_hex, schemes)

                # Extract Node ID
                node_id = extract_node_id(raw_bytes, raw_hex, decoded)

                # Attach RF Metadata to decoded payload
                telemetry_payload = dict(decoded)
                telemetry_payload["rssi"] = pkt.get("rssic", pkt.get("rssi", -100.0))
                telemetry_payload["snr"] = pkt.get("lsnr", pkt.get("snr", 0.0))
                telemetry_payload["freq"] = pkt.get("freq", 868.1)
                telemetry_payload["datr"] = pkt.get("datr", "SF7BW125")
                telemetry_payload["hex"] = raw_hex
                telemetry_payload["last_seen"] = datetime.utcnow().strftime("%Y-%m-%d %H:%M:%S")

                print(f"[UPLINK] Node [{node_id}] | Scheme: {scheme_name} | RSSI: {telemetry_payload['rssi']} dBm | Payload: {raw_hex}")
                print(f"         Decoded: {decoded}")

                # Record into SQLite databases (/tmp/lora_messages.db & /etc/lora/nodes.db)
                record_to_databases(node_id, pkt, raw_hex, decoded)

                # Publish to Home Assistant MQTT
                mqtt_super.publish_node_telemetry(node_id, telemetry_payload)

                # Evaluate Edge Device Linking Rules
                evaluate_linking_rules(node_id, decoded)

        except KeyboardInterrupt:
            print("[BRIDGE] Exiting on SIGINT.")
            break
        except Exception as e:
            print(f"[BRIDGE-ERR] {e}")
            traceback.print_exc()
            time.sleep(0.5)


if __name__ == "__main__":
    main()
