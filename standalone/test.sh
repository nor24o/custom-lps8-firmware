#!/usr/bin/env bash
# ==============================================================================
# test.sh — 1-Click Standalone LoRa Decoder & Pipeline Test Runner
# ==============================================================================
# Auto-detects available runtime (Lua, Python 3, or Node.js) and executes
# the standalone self-test suite and sample payload decoding.
# ==============================================================================

set -e

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$DIR"

echo "=============================================================="
echo " Standalone LoRa Decoder & Pipeline Verification Runner"
echo "=============================================================="

SAMPLE_HEX="CAFE96B840EB010201490271FFFB00180421036700B404880000000000000000"

# 1. Try Lua
LUA_BIN=""
for b in lua lua5.1 lua5.2 lua5.3 lua5.4 luajit; do
    if command -v "$b" >/dev/null 2>&1; then
        LUA_BIN="$b"
        break
    fi
done

if [ -n "$LUA_BIN" ]; then
    echo "[INFO] Running via Lua ($LUA_BIN)..."
    "$LUA_BIN" service.lua --test
    echo ""
    echo "[INFO] Testing sample payload decode (Node CAFE):"
    "$LUA_BIN" service.lua --hex "$SAMPLE_HEX" --decoders decoders.json
    echo ""
    echo "=============================================================="
    echo " Standalone Test Passed via $LUA_BIN!"
    echo "=============================================================="
    exit 0
fi

# 2. Try Node.js
if command -v node >/dev/null 2>&1; then
    echo "[INFO] Running via Node.js..."
    node test_standalone.js
    exit 0
fi

# 3. Try Python 3
if command -v python3 >/dev/null 2>&1; then
    echo "[INFO] Running via Python 3..."
    python3 test_standalone.py
    exit 0
fi

echo "[ERROR] No Lua, Node.js, or Python 3 interpreter found on this system."
echo "Please install Lua (e.g. 'sudo apt install lua5.1') or Python 3."
exit 1
