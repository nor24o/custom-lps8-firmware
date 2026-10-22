#!/usr/bin/env bash
# ==============================================================================
# build_all.sh — Full Build (Apps + Firmware Image) for Dragino LG01 / LG02 (SX1276)
# ==============================================================================
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "==> Step 1: Building SX1276 Applications..."
"$SCRIPT_DIR/build_app.sh"

echo "==> Step 2: Building Firmware Image..."
"$SCRIPT_DIR/build_image.sh"

echo "==> All builds complete!"
