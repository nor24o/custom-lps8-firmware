#!/usr/bin/env bash
# ==============================================================================
# test.sh — 1-Click Standalone LoRa Decoder, Pipeline, Benchmark & Web UI Runner
# ==============================================================================
# Usage:
#   ./test.sh          # Run complete verification test suite
#   ./test.sh --web    # Launch standalone Decoder Studio Web UI (http://localhost:8080)
#   ./test.sh --bench  # Run high-precision latency & throughput benchmark
# ==============================================================================

set -e

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$DIR"

SAMPLE_HEX="CAFE96B840EB010201490271FFFB00180421036700B404880000000000000000"

# Detect Lua binary
LUA_BIN=""
for b in lua lua5.1 lua5.2 lua5.3 lua5.4 luajit; do
    if command -v "$b" >/dev/null 2>&1; then
        LUA_BIN="$b"
        break
    fi
done

# Check for --web command
if [ "$1" = "--web" ]; then
    PORT="${2:-8080}"
    if command -v python3 >/dev/null 2>&1; then
        echo "[INFO] Starting Decoder Studio Web UI via Python 3 on port $PORT..."
        exec python3 web_server.py --port "$PORT"
    elif command -v node >/dev/null 2>&1; then
        echo "[INFO] Starting Decoder Studio Web UI via Node.js on port $PORT..."
        exec node web_server.js "$PORT"
    else
        echo "[ERROR] Python 3 or Node.js is required to run the standalone Web Server."
        echo "Tip: You can also open '$DIR/web/index.html' directly in your browser!"
        exit 1
    fi
fi

# Check for --bench command
if [ "$1" = "--bench" ]; then
    if [ -n "$LUA_BIN" ]; then
        echo "[INFO] Running benchmark via $LUA_BIN..."
        exec "$LUA_BIN" benchmark_pipeline.lua
    else
        echo "[ERROR] Lua runtime is required for benchmark_pipeline.lua."
        exit 1
    fi
fi

echo "=============================================================="
echo " Standalone LoRa Decoder & Pipeline Verification Runner"
echo "=============================================================="

# 1. Try Lua
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
    echo " Tip: Run './test.sh --web' to launch the interactive Web Studio!"
    echo "=============================================================="
    exit 0
fi

# 2. Try Node.js
if command -v node >/dev/null 2>&1; then
    echo "[INFO] Running via Node.js..."
    node test_standalone.js
    echo " Tip: Run './test.sh --web' to launch the interactive Web Studio!"
    exit 0
fi

# 3. Try Python 3
if command -v python3 >/dev/null 2>&1; then
    echo "[INFO] Running via Python 3..."
    python3 test_standalone.py
    echo " Tip: Run './test.sh --web' to launch the interactive Web Studio!"
    exit 0
fi

echo "[ERROR] No Lua, Node.js, or Python 3 interpreter found on this system."
echo "Please install Lua (e.g. 'sudo apt install lua5.1') or Python 3."
exit 1
