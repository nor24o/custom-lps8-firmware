#!/usr/bin/env bash
# ==============================================================================
# test.sh — Universal Standalone LoRa Decoder, Pipeline, Benchmark & Web UI Runner
# Works on Linux, macOS, Raspberry Pi, WSL, Git Bash, MSYS2
# ==============================================================================

set -e

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$DIR"

SAMPLE_HEX="CAFE96B840EB010201490271FFFB00180421036700B404880000000000000000"

# Detect Python binary (filtering out broken Windows Store aliases)
PYTHON_BIN=""
for p in python3 python py; do
    if command -v "$p" >/dev/null 2>&1; then
        if "$p" -c "import sys; sys.exit(0)" >/dev/null 2>&1; then
            PYTHON_BIN="$p"
            break
        fi
    fi
done

# Detect Node binary
NODE_BIN=""
if command -v node >/dev/null 2>&1; then
    NODE_BIN="node"
fi

# Detect Lua binary
LUA_BIN=""
for b in lua lua5.1 lua5.2 lua5.3 lua5.4 luajit; do
    if command -v "$b" >/dev/null 2>&1; then
        LUA_BIN="$b"
        break
    fi
done

# Check for --web command
if [ "$1" = "--web" ] || [ "$1" = "-w" ]; then
    PORT="${2:-8080}"
    if [ -n "$PYTHON_BIN" ]; then
        echo "[INFO] Starting Decoder Studio Web UI via $PYTHON_BIN on port $PORT..."
        exec "$PYTHON_BIN" web_server.py --port "$PORT"
    elif [ -n "$NODE_BIN" ]; then
        echo "[INFO] Starting Decoder Studio Web UI via $NODE_BIN on port $PORT..."
        exec "$NODE_BIN" web_server.js "$PORT"
    else
        echo "[NOTE] No Python or Node.js runtime found on this system."
        echo "[INFO] Opening Decoder Studio directly in your web browser (Zero-Install Mode)..."
        if command -v xdg-open >/dev/null 2>&1; then
            xdg-open "$DIR/index.html"
        elif command -v open >/dev/null 2>&1; then
            open "$DIR/index.html"
        else
            echo "Please open '$DIR/index.html' in your web browser!"
        fi
        exit 0
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
if [ -n "$NODE_BIN" ]; then
    echo "[INFO] Running via Node.js ($NODE_BIN)..."
    "$NODE_BIN" test_standalone.js
    echo " Tip: Run './test.sh --web' to launch the interactive Web Studio!"
    exit 0
fi

# 3. Try Python
if [ -n "$PYTHON_BIN" ]; then
    echo "[INFO] Running via Python ($PYTHON_BIN)..."
    "$PYTHON_BIN" test_standalone.py
    echo " Tip: Run './test.sh --web' to launch the interactive Web Studio!"
    exit 0
fi

echo "[NOTE] No Lua, Node.js, or Python interpreter found on this system."
echo "[INFO] You can still use the full Decoder Studio Web UI by opening:"
echo "       $DIR/index.html"
if command -v xdg-open >/dev/null 2>&1; then
    xdg-open "$DIR/index.html"
elif command -v open >/dev/null 2>&1; then
    open "$DIR/index.html"
fi
exit 0
