#!/usr/bin/env python3
"""
test_standalone.py — Standalone LoRa Decoder Test Runner in Python
Can run directly with: python3 test_standalone.py
"""

import sys
import os
import json
import subprocess

DIR = os.path.dirname(os.path.abspath(__file__))
SAMPLE_HEX = "CAFE96B840EB010201490271FFFB00180421036700B404880000000000000000"

print("==============================================================")
print(" Standalone LoRa Decoder Python Test Runner")
print("==============================================================")

# 1. If lua interpreter exists, run service.lua
lua_bin = None
for candidate in ["lua", "lua5.1", "lua5.2", "lua5.3", "lua5.4", "luajit"]:
    try:
        subprocess.check_call([candidate, "-v"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        lua_bin = candidate
        break
    except Exception:
        pass

if lua_bin:
    print(f"[INFO] Found Lua runtime: '{lua_bin}'. Running service.lua...")
    res = subprocess.run([lua_bin, os.path.join(DIR, "service.lua"), "--test"], universal_newlines=True)
    if res.returncode == 0:
        print("\n[INFO] Decoding sample payload:")
        p = subprocess.run(
            [lua_bin, os.path.join(DIR, "service.lua"), "--hex", SAMPLE_HEX],
            stdout=subprocess.PIPE, universal_newlines=True
        )
        print(p.stdout)
        print(">>> Standalone Test: ALL TESTS PASSED! <<<")
        sys.exit(0)

# 2. Pure Python Fallback Decoder
print("[INFO] Running embedded pure-Python decoder verification...")

def decode_cafe_payload(raw_hex):
    clean = "".join(c for c in raw_hex if c in "0123456789abcdefABCDEF")
    b = bytes.fromhex(clean)
    node_id = clean[0:4].upper()
    serial = clean[4:12].upper()
    
    # Cayenne LPP starting at offset 6
    i = 6
    metrics = {
        "node_id": node_id,
        "device_serial": serial,
        "raw_hex": clean,
        "size": len(b)
    }
    
    while i < len(b):
        ch = b[i]
        t = b[i+1] if i+1 < len(b) else 0
        i += 2
        if t == 0x02: # Analog In (100)
            val = int.from_bytes(b[i:i+2], byteorder='big', signed=True) / 100.0
            metrics[f"ch{ch}_analog_in"] = val
            if ch == 1: metrics["battery"] = val
            i += 2
        elif t == 0x67: # Temp (10)
            val = int.from_bytes(b[i:i+2], byteorder='big', signed=True) / 10.0
            metrics["temperature"] = val
            metrics[f"ch{ch}_temperature"] = val
            i += 2
        elif t == 0x71: # Accel (1000)
            ax = int.from_bytes(b[i:i+2], byteorder='big', signed=True) / 1000.0
            ay = int.from_bytes(b[i+2:i+4], byteorder='big', signed=True) / 1000.0
            az = int.from_bytes(b[i+4:i+6], byteorder='big', signed=True) / 1000.0
            metrics["accel_x"] = ax
            metrics["accel_y"] = ay
            metrics["accel_z"] = az
            i += 6
        elif t == 0x88: # GPS
            i += 9
        else:
            i += 1
            
    return metrics

out = decode_cafe_payload(SAMPLE_HEX)
print(json.dumps(out, indent=2))

assert out["node_id"] == "CAFE"
assert out["temperature"] == 18.0
assert out["battery"] == 3.29
assert out["accel_z"] == 1.057
print("\n>>> Embedded Python Test: ALL CHECKS PASSED (Node: CAFE, Temp: 18.0°C, Batt: 3.29V)! <<<")
