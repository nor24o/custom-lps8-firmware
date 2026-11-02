#!/bin/sh
# /usr/bin/lora_db_init.sh
# Dual-Database Initialization:
#   1. /etc/lora/nodes.db       -> Persistent on Flash (Settings, Class A/B/C, Links)
#   2. /tmp/lora_messages.db    -> RAM tmpfs (Rolling 50 messages/node, Queues, Logs)

set -e

DB_NODES="/etc/lora/nodes.db"
DB_RAM="/tmp/lora_messages.db"

mkdir -p /etc/lora /var/log /tmp

# ==============================================================================
# 1. Persistent Database (/etc/lora/nodes.db on SPI Flash)
# ==============================================================================
if [ ! -f "$DB_NODES" ] || [ ! -s "$DB_NODES" ]; then
    echo "[lora_db_init] Initializing persistent database at $DB_NODES..."
    sqlite3 "$DB_NODES" <<'EOF'
PRAGMA journal_mode = MEMORY;
PRAGMA synchronous = OFF;

-- Node Registry & Profiles
CREATE TABLE IF NOT EXISTS node_settings (
    node_id             TEXT PRIMARY KEY,
    name                TEXT NOT NULL,
    node_class          TEXT NOT NULL DEFAULT 'A', -- 'A' (Battery/RX1), 'B' (Ping Slots), 'C' (Always Listening)
    model               TEXT DEFAULT 'generic',
    group_name          TEXT DEFAULT 'Default',
    is_configured       INTEGER DEFAULT 0,         -- 0 = Auto-Discovered (New/Pending), 1 = Configured
    rx1_delay_ms        INTEGER DEFAULT 1000,
    rx2_delay_ms        INTEGER DEFAULT 2000,
    rx2_freq_hz         INTEGER DEFAULT 869525000,
    rx2_sf              INTEGER DEFAULT 9,
    ping_period_sec     INTEGER DEFAULT 32,
    default_tx_power    INTEGER DEFAULT 14,
    ha_enabled          INTEGER DEFAULT 1,
    last_seen           DATETIME,
    last_rssi           REAL,
    last_snr            REAL,
    created_at          DATETIME DEFAULT CURRENT_TIMESTAMP,
    updated_at          DATETIME DEFAULT CURRENT_TIMESTAMP
);

-- Device Linking & Automations ("What is linked to what and how")
CREATE TABLE IF NOT EXISTS node_links (
    link_id             INTEGER PRIMARY KEY AUTOINCREMENT,
    name                TEXT NOT NULL,
    source_node         TEXT NOT NULL,
    trigger_field       TEXT NOT NULL,             -- e.g. 'temperature', 'humidity', 'btn', 'any'
    operator            TEXT NOT NULL DEFAULT '>', -- '>', '<', '==', '!=', 'always'
    threshold_val       REAL NOT NULL DEFAULT 0.0,
    target_node         TEXT NOT NULL,
    action_type         TEXT DEFAULT 'downlink_raw',
    action_payload      TEXT NOT NULL,             -- Downlink payload e.g. '0101' or 'VALVE:ON'
    turnaround_delay_ms INTEGER DEFAULT 1000,      -- Delay before TX (Class A RX1 turnaround)
    cooldown_sec        INTEGER DEFAULT 60,        -- Minimum seconds between triggers (debounce)
    pulse_sec           INTEGER DEFAULT 0,         -- Optional auto-reset timer (0 = disabled)
    lbt_enabled         INTEGER DEFAULT 1,         -- 1 = Listen-Before-Send (LBT / Carrier Sense)
    lbt_rssi_threshold  INTEGER DEFAULT -85,       -- dBm threshold for busy channel
    lbt_max_retries     INTEGER DEFAULT 3,         -- Max backoff retries if channel busy
    lbt_backoff_ms      INTEGER DEFAULT 50,        -- Backoff slot time
    ack_required        INTEGER DEFAULT 0,         -- 1 = Wait for target confirmation uplink
    ack_timeout_ms      INTEGER DEFAULT 3000,
    enabled             INTEGER DEFAULT 1,
    last_triggered      DATETIME,
    last_status         TEXT
);

-- Seed Reference Nodes
INSERT OR IGNORE INTO node_settings (node_id, name, node_class, model, group_name, rx1_delay_ms, is_configured)
VALUES ('AA0B', 'Living Room Sensor', 'A', 'temperature_sensor', 'Indoor', 1000, 1);

INSERT OR IGNORE INTO node_settings (node_id, name, node_class, model, group_name, default_tx_power, is_configured)
VALUES ('AA0C', 'Irrigation Valve Actuator', 'C', 'relay_valve', 'Garden', 14, 1);

-- Seed Reference Linking Rule
INSERT OR IGNORE INTO node_links (link_id, name, source_node, trigger_field, operator, threshold_val, target_node, action_payload, turnaround_delay_ms, cooldown_sec, lbt_enabled)
VALUES (1, 'Overheat Protection Valve', 'AA0B', 'temperature', '>', 30.0, 'AA0C', '0101', 1000, 60, 1);
EOF
else
    # Schema Migration for existing databases
    sqlite3 "$DB_NODES" "ALTER TABLE node_settings ADD COLUMN is_configured INTEGER DEFAULT 1;" 2>/dev/null || true
fi

# ==============================================================================
# 2. Ephemeral RAM Database (/tmp/lora_messages.db in tmpfs)
# ==============================================================================
if [ ! -f "$DB_RAM" ] || [ ! -s "$DB_RAM" ]; then
    echo "[lora_db_init] Initializing RAM database at $DB_RAM..."
    sqlite3 "$DB_RAM" <<'EOF'
PRAGMA journal_mode = MEMORY;
PRAGMA synchronous = OFF;

-- Rolling 50 Messages per Node (Circular Buffer)
CREATE TABLE IF NOT EXISTS node_messages (
    id                  INTEGER PRIMARY KEY AUTOINCREMENT,
    node_id             TEXT NOT NULL,
    timestamp           DATETIME DEFAULT CURRENT_TIMESTAMP,
    rssi                REAL,
    snr                 REAL,
    freq_hz             INTEGER,
    sf                  INTEGER,
    payload_raw         TEXT,
    payload_decoded     TEXT,
    tmst                INTEGER
);

CREATE INDEX IF NOT EXISTS idx_node_messages ON node_messages(node_id, id DESC);

-- Automatic Circular Buffer: Keep only last 50 messages per node
CREATE TRIGGER IF NOT EXISTS prune_node_history
AFTER INSERT ON node_messages
BEGIN
    DELETE FROM node_messages
    WHERE node_id = NEW.node_id
      AND id NOT IN (
          SELECT id FROM node_messages
          WHERE node_id = NEW.node_id
          ORDER BY id DESC
          LIMIT 50
      );
END;

-- Pending Downlink Queue (Class A / Class B)
CREATE TABLE IF NOT EXISTS pending_downlinks (
    id                  INTEGER PRIMARY KEY AUTOINCREMENT,
    target_node         TEXT NOT NULL,
    target_class        TEXT NOT NULL DEFAULT 'A',
    payload             TEXT NOT NULL,
    status              TEXT DEFAULT 'QUEUED', -- 'QUEUED', 'DISPATCHED', 'FAILED', 'EXPIRED'
    created_at          DATETIME DEFAULT CURRENT_TIMESTAMP,
    dispatched_at       DATETIME,
    lbt_status          TEXT,
    ack_received        INTEGER DEFAULT 0
);

-- Realtime Audit & Execution Log
CREATE TABLE IF NOT EXISTS link_execution_logs (
    id                  INTEGER PRIMARY KEY AUTOINCREMENT,
    link_id             INTEGER,
    timestamp           DATETIME DEFAULT CURRENT_TIMESTAMP,
    event_type          TEXT, -- 'AUTO_TRIGGER', 'MANUAL_TEST', 'SIMULATION'
    source_node         TEXT,
    target_node         TEXT,
    target_class        TEXT,
    lbt_status          TEXT,
    delay_ms            INTEGER,
    tx_status           TEXT,
    ack_status          TEXT,
    details             TEXT
);
EOF
fi

chmod 644 "$DB_NODES" "$DB_RAM" 2>/dev/null || true
echo "[lora_db_init] Databases successfully initialized."
