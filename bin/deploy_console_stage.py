#!/usr/bin/env python3
"""Install a tested staged console on the Bobcat, preserving configuration."""
import datetime
import json
import os
import shutil
import sqlite3
import subprocess

stage = '/tmp/bobcat-deploy-stage'
backup = '/opt/bobcat-console-backup-' + datetime.datetime.now().strftime('%Y%m%d-%H%M%S')
os.makedirs(backup)
files = {'bobcat_lora_bridge.py':'/usr/local/bin/bobcat_lora_bridge.py',
         'packet_profiles.py':'/usr/local/bin/packet_profiles.py',
         'decoder_js.py':'/usr/local/bin/decoder_js.py',
         'app.py':'/opt/bobcat-web/app.py', 'console.html':'/opt/bobcat-web/templates/console.html',
         'console.css':'/opt/bobcat-web/static/console.css', 'console.js':'/opt/bobcat-web/static/console.js',
         'decoder_studio.js':'/opt/bobcat-web/static/decoder_studio.js',
         'decoder_studio.css':'/opt/bobcat-web/static/decoder_studio.css',
         'packet_profiler.css':'/opt/bobcat-web/static/packet_profiler.css',
         'native_settings.css':'/opt/bobcat-web/static/native_settings.css',
         'native_settings.js':'/opt/bobcat-web/static/native_settings.js',
         'profile_studio.js':'/opt/bobcat-web/static/profile_studio.js',
         'console_life.css':'/opt/bobcat-web/static/console_life.css',
         'console_life.js':'/opt/bobcat-web/static/console_life.js',
         'activity_ui.js':'/opt/bobcat-web/static/activity_ui.js',
         'management_ui.js':'/opt/bobcat-web/static/management_ui.js',
         'management_ui.css':'/opt/bobcat-web/static/management_ui.css'}
for source, target in files.items():
    if os.path.exists(target):
        shutil.copy2(target, os.path.join(backup, source))
for name in ('config.json', 'packet_profiles.json', 'decoders.json'):
    shutil.copy2('/etc/lora/' + name, os.path.join(backup, name))
with sqlite3.connect('/etc/lora/nodes.db') as original, sqlite3.connect(backup + '/nodes.db') as saved:
    original.backup(saved)

# Migrate only already enrolled devices whose serial was actually observed.
with open('/etc/lora/config.json') as f:
    config = json.load(f)
try:
    with open('/tmp/lora_concentrators.json') as f:
        fleet = json.load(f)
except (OSError, ValueError):
    fleet = {}
with sqlite3.connect('/etc/lora/nodes.db') as db:
    columns = [row[1] for row in db.execute('PRAGMA table_info(node_settings)')]
    for gateway in fleet.values():
        for legacy_id, node in gateway.get('nodes', {}).items():
            serial = node.get('device_serial')
            if not serial or '-' in legacy_id:
                continue
            row = db.execute('SELECT * FROM node_settings WHERE node_id=? AND is_configured=1', (legacy_id,)).fetchone()
            if row:
                device_id = legacy_id + '-' + serial.upper()
                values = list(row)
                values[columns.index('node_id')] = device_id
                db.execute('INSERT OR IGNORE INTO node_settings (' + ','.join(columns) + ') VALUES (' + ','.join('?' for _ in columns) + ')', values)
                config.setdefault('device_aliases', {})[device_id] = legacy_id
config.setdefault('pipeline', {}).update(filter_unregistered_nodes=False)
config['pipeline'].setdefault('dedup_window_ms', 150)
config['pipeline'].setdefault('join_frequency_repeats', True)
with open('/etc/lora/config.json.tmp', 'w') as f:
    json.dump(config, f, indent=2)
os.replace('/etc/lora/config.json.tmp', '/etc/lora/config.json')
if not os.path.exists('/etc/lora/packet_profiles.json'):
    shutil.copy2(stage + '/packet_profiles.json', '/etc/lora/packet_profiles.json')
for source, target in files.items():
    shutil.copy2(stage + '/' + source, target)
subprocess.run(['systemctl', 'restart', 'bobcat-lora-bridge', 'bobcat-web'], check=True)
subprocess.run(['systemctl', 'is-active', 'raw-lora', 'bobcat-lora-bridge', 'bobcat-web'], check=True)
print('Backup:', backup)
