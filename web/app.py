import sqlite3
import os
import re
import time
import json
import socket
import base64
import shutil
import subprocess
from flask import Flask, render_template, jsonify, request

app = Flask(__name__, template_folder='templates', static_folder='static')

# Physical RGB Mapping on Bobcat G285:
# /sys/class/leds/blue:status  (GPIO4_A0) -> Physical GREEN channel
# /sys/class/leds/green:status (GPIO4_A1) -> Physical BLUE channel
# /sys/class/leds/red:status   (GPIO4_A2) -> Physical RED channel
RGB_CHANNELS = {
    'R': '/sys/class/leds/red:status',
    'G': '/sys/class/leds/blue:status',
    'B': '/sys/class/leds/green:status'
}

COLOR_PRESETS = {
    'off':     [],
    'red':     ['R'],
    'green':   ['G'],
    'blue':    ['B'],
    'yellow':  ['R', 'G'],
    'cyan':    ['G', 'B'],
    'purple':  ['R', 'B'],
    'white':   ['R', 'G', 'B']
}

def get_cpu_temp():
    try:
        with open('/sys/class/thermal/thermal_zone0/temp', 'r') as f:
            return round(int(f.read().strip()) / 1000.0, 1)
    except:
        return None

def get_gpu_temp():
    try:
        with open('/sys/class/thermal/thermal_zone1/temp', 'r') as f:
            return round(int(f.read().strip()) / 1000.0, 1)
    except:
        return None

def get_uptime_str():
    try:
        with open('/proc/uptime', 'r') as f:
            total_seconds = float(f.read().split()[0])
            days = int(total_seconds // 86400)
            hours = int((total_seconds % 86400) // 3600)
            minutes = int((total_seconds % 3600) // 60)
            seconds = int(total_seconds % 60)
            if days > 0:
                return f"{days}d {hours}h {minutes}m {seconds}s"
            return f"{hours}h {minutes}m {seconds}s"
    except:
        return "Unknown"

_prev_idle = 0
_prev_total = 0

def get_cpu_usage():
    global _prev_idle, _prev_total
    try:
        with open('/proc/stat', 'r') as f:
            fields = [float(x) for x in f.readline().strip().split()[1:]]
        idle = fields[3] + fields[4]
        total = sum(fields)
        idle_delta = idle - _prev_idle
        total_delta = total - _prev_total
        _prev_idle = idle
        _prev_total = total
        if total_delta <= 0:
            return 0.0
        usage = 100.0 * (1.0 - idle_delta / total_delta)
        return round(max(0.0, min(100.0, usage)), 1)
    except:
        return 0.0

def get_ram_info():
    try:
        mem = {}
        with open('/proc/meminfo', 'r') as f:
            for line in f:
                parts = line.split(':')
                if len(parts) == 2:
                    mem[parts[0].strip()] = int(parts[1].strip().split()[0])
        total = mem.get('MemTotal', 0) // 1024
        free = mem.get('MemFree', 0) // 1024
        avail = mem.get('MemAvailable', free) // 1024
        used = total - avail
        pct = round(100.0 * used / total, 1) if total > 0 else 0
        return {'total': total, 'used': used, 'free': free, 'percent': pct}
    except:
        return {'total': 0, 'used': 0, 'free': 0, 'percent': 0}

def get_disk_info():
    try:
        usage = shutil.disk_usage('/')
        total = round(usage.total / (1024**3), 1)
        used = round(usage.used / (1024**3), 1)
        free = round(usage.free / (1024**3), 1)
        pct = round(100.0 * usage.used / usage.total, 1) if usage.total > 0 else 0
        return {'total': total, 'used': used, 'free': free, 'percent': pct}
    except:
        return {'total': 0, 'used': 0, 'free': 0, 'percent': 0}

def find_ethernet_interface():
    try:
        ifaces = os.listdir('/sys/class/net')
        for name in ['end0', 'eth0']:
            if name in ifaces:
                return name
        for iface in ifaces:
            if iface.startswith(('end', 'eth', 'enp')) and not iface.startswith('lo'):
                return iface
    except:
        pass
    return 'end0'

def get_default_gateway():
    try:
        out = subprocess.check_output(['ip', 'route'], text=True, stderr=subprocess.DEVNULL)
        m = re.search(r'default via\s+(\d+\.\d+\.\d+\.\d+)', out)
        if m:
            return m.group(1)
    except:
        pass
    return '--'

def get_hostname():
    try:
        with open('/etc/hostname', 'r') as f:
            h = f.read().strip()
            if h:
                return h
    except:
        pass
    return socket.gethostname()

def get_load_averages():
    try:
        l1, l5, l15 = os.getloadavg()
        return round(l1, 2)
    except:
        return 0.0

def get_ip_info(iface):
    ip = "Disconnected"
    mac = ""
    try:
        out = subprocess.check_output(['ip', 'addr', 'show', iface], text=True, stderr=subprocess.DEVNULL)
        m = re.search(r'inet\s+(\d+\.\d+\.\d+\.\d+/\d+)', out)
        if m:
            ip = m.group(1)
        m2 = re.search(r'link/ether\s+([0-9a-fA-F:]{17})', out)
        if m2:
            mac = m2.group(1)
    except:
        pass
    return {'ip': ip, 'mac': mac}

def get_wifi_status():
    status = {'connected': False, 'ssid': '', 'signal': 0, 'ip': '', 'mac': ''}
    try:
        out = subprocess.check_output(['nmcli', '-t', '-f', 'DEVICE,TYPE,STATE,CONNECTION', 'dev'], text=True)
        for line in out.splitlines():
            parts = line.split(':')
            if len(parts) >= 4 and parts[0] == 'wlan0':
                if parts[2] == 'connected':
                    status['connected'] = True
                    status['ssid'] = parts[3]
        ip_info = get_ip_info('wlan0')
        status['ip'] = ip_info['ip']
        status['mac'] = ip_info['mac']
        if status['connected']:
            sig_out = subprocess.check_output(['nmcli', '-t', '-f', 'IN-USE,SIGNAL', 'dev', 'wifi'], text=True)
            for s in sig_out.splitlines():
                if s.startswith('*:'):
                    status['signal'] = int(s.split(':')[1])
    except:
        pass
    return status

def get_lora_power_status():
    try:
        with open('/sys/class/gpio/gpio125/value', 'r') as f:
            v1 = f.read().strip()
        with open('/sys/class/gpio/gpio122/value', 'r') as f:
            v2 = f.read().strip()
        return (v1 == '1' and v2 == '1')
    except:
        return False

def get_current_led_color():
    active = set()
    for ch, path in RGB_CHANNELS.items():
        try:
            with open(f"{path}/brightness", "r") as f:
                if int(f.read().strip()) > 0:
                    active.add(ch)
            with open(f"{path}/trigger", "r") as f:
                if '[heartbeat]' in f.read():
                    active.add(ch)
        except:
            pass

    for name, channels in COLOR_PRESETS.items():
        if set(channels) == active and len(channels) > 0:
            return name
    if len(active) == 0:
        return 'off'
    return 'custom'

def query_lora_app_metrics():
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        s.settimeout(1.0)
        s.connect(('127.0.0.1', 5557))
        data = s.recv(1024).decode('utf-8')
        s.close()
        return json.loads(data.strip())
    except:
        return None

# ==================== WEB ROUTES ====================

@app.route('/')
def index():
    return render_template('index.html')

@app.route('/api/status')
def api_status():
    hostname = get_hostname()
    eth_iface = find_ethernet_interface()
    eth_info = get_ip_info(eth_iface)
    wifi_info = get_wifi_status()
    lora_power = get_lora_power_status()
    led_color = get_current_led_color()
    gw = get_default_gateway()
    load1 = get_load_averages()
    cpu_temp = get_cpu_temp()
    gpu_temp = get_gpu_temp()
    cpu_pct = get_cpu_usage()
    ram = get_ram_info()
    disk = get_disk_info()

    # Query custom LoRa app daemon status
    lora_app_active = False
    lora_app_enabled = False
    try:
        res = subprocess.run(['systemctl', 'is-active', 'raw-lora.service'], capture_output=True, text=True)
        lora_app_active = (res.stdout.strip() == 'active')
        res2 = subprocess.run(['systemctl', 'is-enabled', 'raw-lora.service'], capture_output=True, text=True)
        lora_app_enabled = (res2.stdout.strip() == 'enabled')
    except:
        pass

    lora_metrics = query_lora_app_metrics() if lora_app_active else None

    # Clean IP addresses (without CIDR mask for UI display)
    eth_clean_ip = eth_info.get('ip', 'Disconnected').split('/')[0] if eth_info.get('ip') != 'Disconnected' else 'Disconnected'
    wifi_clean_ip = wifi_info.get('ip', 'Not connected').split('/')[0] if (wifi_info.get('connected') and wifi_info.get('ip') != 'Disconnected') else 'Not connected'

    return jsonify({
        'hostname': hostname,
        'uptime': get_uptime_str(),
        'soc_temp': cpu_temp,
        'cpu_temp': cpu_temp,
        'gpu_temp': gpu_temp,
        'cpu_percent': cpu_pct,
        'cpu_usage': cpu_pct,
        'ram_used_mb': ram.get('used', 0),
        'ram_total_mb': ram.get('total', 0),
        'load_1m': load1,
        'default_gateway': gw,
        'interfaces': {
            'eth0': {
                'name': eth_iface,
                'ip': eth_clean_ip,
                'mac': eth_info.get('mac', '--')
            },
            'end0': {
                'name': eth_iface,
                'ip': eth_clean_ip,
                'mac': eth_info.get('mac', '--')
            },
            'wlan0': {
                'name': 'wlan0',
                'ip': wifi_clean_ip,
                'mac': wifi_info.get('mac', '--')
            }
        },
        'wifi_ssid': wifi_info.get('ssid', '--'),
        'wifi_signal': wifi_info.get('signal', 0),
        'wifi_status': 'Connected' if wifi_info.get('connected') else 'Disconnected',
        'ram': ram,
        'disk': disk,
        'eth0': eth_info,
        'wifi': wifi_info,
        'lora_power': lora_power,
        'led_color': led_color,
        'lora_app': {
            'active': lora_app_active,
            'enabled': lora_app_enabled,
            'metrics': lora_metrics
        },
        'pipeline': (json.load(open('/etc/lora/config.json', 'r', encoding='utf-8')).get('pipeline', {}) if os.path.exists('/etc/lora/config.json') else {})
    })

@app.route('/api/wifi/scan')
def api_wifi_scan():
    networks = []
    try:
        out = subprocess.check_output(['nmcli', '-t', '-f', 'IN-USE,SSID,SIGNAL,SECURITY,CHAN', 'dev', 'wifi', 'list', '--rescan', 'yes'], text=True)
        seen = set()
        for line in out.splitlines():
            parts = line.split(':')
            if len(parts) >= 5:
                in_use = (parts[0] == '*')
                ssid = parts[1].strip()
                if not ssid or ssid in seen:
                    continue
                seen.add(ssid)
                sig = int(parts[2]) if parts[2].isdigit() else 0
                sec = parts[3] if parts[3] else 'Open'
                chan = parts[4]
                networks.append({
                    'in_use': in_use,
                    'ssid': ssid,
                    'signal': sig,
                    'security': sec,
                    'chan': chan
                })
    except Exception as e:
        print(f"Wi-Fi scan failed: {e}")
    return jsonify(networks)

@app.route('/api/wifi/connect', methods=['POST'])
def api_wifi_connect():
    data = request.json or {}
    ssid = data.get('ssid')
    password = data.get('password')
    if not ssid:
        return jsonify({'error': 'SSID is required'}), 400
    try:
        cmd = ['nmcli', 'dev', 'wifi', 'connect', ssid]
        if password:
            cmd.extend(['password', password])
        res = subprocess.run(cmd, capture_output=True, text=True, timeout=25)
        if res.returncode == 0:
            return jsonify({'success': True, 'message': f'Connected to {ssid} successfully!'})
        else:
            return jsonify({'success': False, 'message': res.stderr or res.stdout}), 400
    except Exception as e:
        return jsonify({'error': str(e)}), 500

@app.route('/api/wifi/disconnect', methods=['POST'])
def api_wifi_disconnect():
    try:
        res = subprocess.run(['nmcli', 'dev', 'disconnect', 'wlan0'], capture_output=True, text=True, timeout=10)
        return jsonify({'success': True, 'message': 'Wi-Fi disconnected.'})
    except Exception as e:
        return jsonify({'error': str(e)}), 500

@app.route('/api/hostname', methods=['POST'])
def api_set_hostname():
    data = request.get_json(force=True, silent=True) or request.form or {}
    new_host = (data.get('hostname') or '').strip()
    print(f"[HOSTNAME] Raw data: {request.data}, parsed: {data}, new_host: '{new_host}'", flush=True)
    if not new_host or not re.match(r'^[a-zA-Z0-9-]+$', new_host):
        return jsonify({'error': 'Invalid hostname (letters, numbers, hyphens only)'}), 400
    try:
        # 1. Update systemd hostname
        subprocess.run(['hostnamectl', 'set-hostname', new_host], check=False)
        # 2. Update live kernel nodename immediately
        subprocess.run(['hostname', new_host], check=False)
        # 3. Write /etc/hostname
        try:
            with open('/etc/hostname', 'w') as f:
                f.write(f"{new_host}\n")
        except:
            pass
        # 4. Update /etc/hosts
        try:
            with open('/etc/hosts', 'r') as f:
                lines = f.readlines()
            with open('/etc/hosts', 'w') as f:
                for l in lines:
                    if '127.0.1.1' in l:
                        f.write(f"127.0.1.1\t{new_host}\n")
                    elif '::1' in l and 'ip6-localhost' in l:
                        f.write(f"::1\tlocalhost {new_host} ip6-localhost ip6-loopback\n")
                    else:
                        f.write(l)
        except:
            pass
        # 5. Notify avahi-daemon to broadcast the new mDNS hostname immediately
        subprocess.run(['systemctl', 'try-restart', 'avahi-daemon'], check=False)
        return jsonify({'success': True, 'hostname': new_host, 'message': f'Hostname changed to {new_host}'})
    except Exception as e:
        return jsonify({'error': str(e)}), 500

# ==================== HARDWARE & LOW-LEVEL LORA ====================

@app.route('/api/lora/test', methods=['POST'])
def api_lora_test():
    try:
        res = subprocess.run(['/usr/local/bin/test-lora'], capture_output=True, text=True, timeout=15)
        return jsonify({
            'success': (res.returncode == 0),
            'output': res.stdout + res.stderr
        })
    except Exception as e:
        return jsonify({'success': False, 'output': str(e)}), 500

@app.route('/api/lora/power', methods=['POST'])
def api_lora_power():
    data = request.json or {}
    enable = bool(data.get('enable', True))
    action = 'start' if enable else 'stop'
    try:
        res = subprocess.run(['/usr/local/bin/reset_lgw.sh', action], capture_output=True, text=True, timeout=10)
        return jsonify({'success': (res.returncode == 0), 'state': enable})
    except Exception as e:
        return jsonify({'error': str(e)}), 500

# ==================== CUSTOM LORA APP (raw_lora_app) ROUTES ====================

@app.route('/api/lora/app/status', methods=['GET'])
def api_lora_app_status():
    is_active = False
    is_enabled = False
    try:
        res = subprocess.run(['systemctl', 'is-active', 'raw-lora.service'], capture_output=True, text=True)
        is_active = (res.stdout.strip() == 'active')
        res2 = subprocess.run(['systemctl', 'is-enabled', 'raw-lora.service'], capture_output=True, text=True)
        is_enabled = (res2.stdout.strip() == 'enabled')
    except:
        pass

    metrics = query_lora_app_metrics() if is_active else None
    is_running = is_active and (metrics is not None)

    return jsonify({
        'running': is_running,
        'active': is_active,
        'enabled': is_enabled,
        'live': metrics or {},
        'metrics': metrics or {},
        'rx': metrics.get('rx', 0) if metrics else 0,
        'tx': metrics.get('tx', 0) if metrics else 0,
        'crc_err': metrics.get('crc_err', 0) if metrics else 0
    })

@app.route('/api/lora/app/service', methods=['POST'])
def api_lora_app_service():
    data = request.json or {}
    action = data.get('action', 'status')
    if action not in ['start', 'stop', 'restart', 'enable', 'disable']:
        return jsonify({'error': 'Invalid action'}), 400
    try:
        res = subprocess.run(['systemctl', action, 'raw-lora.service'], capture_output=True, text=True, timeout=15)
        return jsonify({
            'success': (res.returncode == 0),
            'action': action,
            'message': res.stderr or res.stdout or f'Service {action} successful'
        })
    except Exception as e:
        return jsonify({'error': str(e)}), 500


@app.route('/api/lora/pipeline', methods=['GET', 'POST'])
def api_lora_pipeline():
    cfg_path = '/etc/lora/config.json'
    default_pipeline = {
        'decoding_enabled': True,
        'ha_telemetry_enabled': True,
        'ha_discovery_enabled': True,
        'ha_gateway_telemetry_enabled': True,
        'sqlite_logging_enabled': True,
        'linking_enabled': True,
        'filter_unregistered_nodes': False
    }

    try:
        cfg = {}
        if os.path.exists(cfg_path):
            with open(cfg_path, 'r', encoding='utf-8') as f:
                cfg = json.load(f)
        pipeline = dict(default_pipeline)
        pipeline.update(cfg.get('pipeline', {}))

        if request.method == 'POST':
            data = request.get_json(silent=True) or {}
            for k in default_pipeline.keys():
                if k in data:
                    pipeline[k] = bool(data[k])
            cfg['pipeline'] = pipeline
            with open(cfg_path, 'w', encoding='utf-8') as f:
                json.dump(cfg, f, indent=4)
            return jsonify({'success': True, 'pipeline': pipeline})

        return jsonify({'success': True, 'pipeline': pipeline})
    except Exception as e:
        return jsonify({'error': str(e)}), 500

@app.route('/api/lora/app/config', methods=['GET', 'POST'])
def api_lora_app_config():
    cfg_path = '/etc/lora/config.json'
    if request.method == 'GET':
        if not os.path.exists(cfg_path):
            return jsonify({'error': 'Configuration file not found'}), 404
        try:
            with open(cfg_path, 'r') as f:
                cfg = json.load(f)
            return jsonify({'success': True, 'config': cfg})
        except Exception as e:
            return jsonify({'error': str(e)}), 500

    # POST - update config
    try:
        new_cfg = request.json
        if not isinstance(new_cfg, dict):
            return jsonify({'error': 'Invalid JSON configuration'}), 400

        with open(cfg_path, 'w') as f:
            json.dump(new_cfg, f, indent=4)

        restart = request.args.get('restart', 'false').lower() == 'true'
        if restart:
            subprocess.run(['systemctl', 'restart', 'raw-lora.service'], timeout=15)

        return jsonify({'success': True, 'message': 'Configuration saved successfully!'})
    except Exception as e:
        return jsonify({'error': str(e)}), 500

@app.route('/api/lora/app/tx', methods=['POST'])
def api_lora_app_tx():
    data = request.json or {}
    payload_hex = data.get('payload_hex', '').strip()
    payload_text = data.get('payload_text', '').strip()
    freq = float(data.get('freq', 868.1))
    sf = int(data.get('sf', 7))
    bw = int(data.get('bw', 125))
    power = int(data.get('power', 14))

    if payload_hex:
        try:
            raw_bytes = bytes.fromhex(payload_hex.replace(' ', ''))
        except Exception as e:
            return jsonify({'error': f'Invalid hex string: {e}'}), 400
    elif payload_text:
        raw_bytes = payload_text.encode('utf-8')
    else:
        # Default test packet (magic 0x6B 0x5A)
        raw_bytes = b'\x6B\x5A\x01\xFE\x02\x01\x01\x01'

    b64 = base64.b64encode(raw_bytes).decode('ascii')
    pkt = {
        "imme": True,
        "freq": freq,
        "rfch": 0,
        "powe": power,
        "modu": "LORA",
        "datr": f"SF{sf}BW{bw}",
        "codr": "4/5",
        "ipol": False,
        "data": b64
    }

    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.settimeout(2.0)
        s.sendto(json.dumps(pkt).encode('utf-8'), ('127.0.0.1', 5556))
        s.close()
        return jsonify({
            'success': True,
            'message': f'Queued {len(raw_bytes)} bytes downlink (SF{sf}, {freq} MHz, {power} dBm)',
            'bytes_count': len(raw_bytes)
        })
    except Exception as e:
        return jsonify({'error': str(e)}), 500

@app.route('/api/lora/app/logs', methods=['GET'])
def api_lora_app_logs():
    lines = request.args.get('lines', 50)
    try:
        res = subprocess.run(['journalctl', '-u', 'raw-lora.service', '-n', str(lines), '--no-pager'], capture_output=True, text=True, timeout=5)
        return jsonify({'success': True, 'logs': res.stdout})
    except Exception as e:
        return jsonify({'error': str(e)}), 500


# ==================== DECODERS & PACKETS ====================

@app.route('/api/lora/decoders', methods=['GET', 'POST'])
def api_lora_decoders():
    dec_path = '/etc/lora/decoders.json'
    if request.method == 'GET':
        if not os.path.exists(dec_path):
            return jsonify({'version': 1, 'schemes': []})
        try:
            with open(dec_path, 'r', encoding='utf-8') as f:
                data = json.load(f)
            return jsonify(data)
        except Exception as e:
            return jsonify({'error': str(e)}), 500

    # POST - save schemes
    try:
        data = request.json or {}
        with open(dec_path, 'w', encoding='utf-8') as f:
            json.dump(data, f, indent=2)
        return jsonify({'success': True, 'message': 'Decoders saved successfully!'})
    except Exception as e:
        return jsonify({'error': str(e)}), 500

@app.route('/api/lora/packets', methods=['GET'])
def api_lora_packets():
    packets_path = '/tmp/lora_packets.json'
    if not os.path.exists(packets_path):
        return jsonify([])
    try:
        with open(packets_path, 'r', encoding='utf-8') as f:
            data = json.load(f)
        return jsonify(data)
    except Exception as e:
        return jsonify([])

# ==================== NODES REGISTRY & MESSAGES ====================

@app.route('/api/lora/nodes', methods=['GET', 'POST'])
def api_lora_nodes():
    db_nodes = '/etc/lora/nodes.db'
    db_ram = '/tmp/lora_messages.db'

    if request.method == 'GET':
        if not os.path.exists(db_nodes):
            return jsonify({'nodes': []})
        try:
            con = sqlite3.connect(db_nodes, timeout=5)
            con.row_factory = sqlite3.Row
            cur = con.cursor()
            cur.execute("""
                SELECT node_id, name, node_class, model, group_name, is_configured,
                       default_tx_power, ha_enabled, last_seen, last_rssi, last_snr,
                       created_at, updated_at
                FROM node_settings
                ORDER BY is_configured DESC, last_seen DESC
            """)
            rows = [dict(r) for r in cur.fetchall()]
            con.close()

            # Attach message count from RAM DB
            if os.path.exists(db_ram):
                try:
                    con_r = sqlite3.connect(db_ram, timeout=3)
                    cur_r = con_r.cursor()
                    for node in rows:
                        cur_r.execute("SELECT count(*) FROM node_messages WHERE node_id = ?", (node['node_id'],))
                        c = cur_r.fetchone()
                        node['msg_count'] = c[0] if c else 0
                    con_r.close()
                except Exception:
                    pass

            return jsonify({'nodes': rows})
        except Exception as e:
            return jsonify({'error': str(e)}), 500

    # POST - create or update node
    try:
        data = request.json or {}
        nid = str(data.get('node_id', '')).strip().upper()
        if not nid:
            return jsonify({'error': 'node_id is required'}), 400

        name = data.get('name', f'LoRa Node {nid}')
        cls = data.get('node_class', 'A').upper()
        model = data.get('model', 'generic')
        group_name = data.get('group_name', 'Default')
        is_conf = int(data.get('is_configured', 1))
        ha_en = int(data.get('ha_enabled', 1))
        tx_pwr = int(data.get('default_tx_power', 14))

        con = sqlite3.connect(db_nodes, timeout=5)
        cur = con.cursor()
        cur.execute("""
            INSERT INTO node_settings (node_id, name, node_class, model, group_name, is_configured, ha_enabled, default_tx_power, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, CURRENT_TIMESTAMP)
            ON CONFLICT(node_id) DO UPDATE SET
                name = excluded.name,
                node_class = excluded.node_class,
                model = excluded.model,
                group_name = excluded.group_name,
                is_configured = excluded.is_configured,
                ha_enabled = excluded.ha_enabled,
                default_tx_power = excluded.default_tx_power,
                updated_at = CURRENT_TIMESTAMP
        """, (nid, name, cls, model, group_name, is_conf, ha_en, tx_pwr))
        con.commit()
        con.close()
        return jsonify({'success': True, 'message': f'Node {nid} updated successfully!'})
    except Exception as e:
        return jsonify({'error': str(e)}), 500

@app.route('/api/lora/nodes/<node_id>', methods=['DELETE'])
def api_lora_node_delete(node_id):
    db_nodes = '/etc/lora/nodes.db'
    try:
        con = sqlite3.connect(db_nodes, timeout=5)
        cur = con.cursor()
        cur.execute("DELETE FROM node_settings WHERE node_id = ?", (node_id.upper(),))
        con.commit()
        con.close()
        return jsonify({'success': True, 'message': f'Node {node_id} removed.'})
    except Exception as e:
        return jsonify({'error': str(e)}), 500

@app.route('/api/lora/nodes/<node_id>/messages', methods=['GET'])
def api_lora_node_messages(node_id):
    db_ram = '/tmp/lora_messages.db'
    if not os.path.exists(db_ram):
        return jsonify({'messages': []})
    try:
        con = sqlite3.connect(db_ram, timeout=5)
        con.row_factory = sqlite3.Row
        cur = con.cursor()
        cur.execute("""
            SELECT id, node_id, timestamp, rssi, snr, freq_hz, sf, payload_raw, payload_decoded
            FROM node_messages
            WHERE node_id = ?
            ORDER BY id DESC
            LIMIT 50
        """, (node_id.upper(),))
        rows = [dict(r) for r in cur.fetchall()]
        con.close()
        return jsonify({'messages': rows})
    except Exception as e:
        return jsonify({'error': str(e)}), 500

@app.route('/api/lora/nodes/<node_id>/downlink', methods=['POST'])
def api_lora_node_downlink(node_id):
    data = request.json or {}
    cmd = data.get('payload', '').strip()
    if not cmd:
        return jsonify({'error': 'Payload is required'}), 400

    power = int(data.get('power', 27))
    sf = int(data.get('sf', 7))
    freq = float(data.get('freq', 868.1))

    if cmd.upper() in ('ON', '1'):
        raw_bytes = bytes.fromhex('0101')
    elif cmd.upper() in ('OFF', '0'):
        raw_bytes = bytes.fromhex('0100')
    else:
        try:
            raw_bytes = bytes.fromhex(cmd)
        except ValueError:
            raw_bytes = cmd.encode('utf-8')

    b64 = base64.b64encode(raw_bytes).decode('ascii')
    pkt = {
        "imme": True,
        "freq": freq,
        "rfch": 0,
        "powe": power,
        "modu": "LORA",
        "datr": f"SF{sf}BW125",
        "codr": "4/5",
        "ipol": False,
        "size": len(raw_bytes),
        "data": b64
    }

    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.settimeout(2.0)
        s.sendto(json.dumps(pkt).encode('ascii'), ('127.0.0.1', 5556))
        s.close()
        return jsonify({'success': True, 'message': f'Downlink dispatched to {node_id} ({len(raw_bytes)}B)'})
    except Exception as e:
        return jsonify({'error': str(e)}), 500

# ==================== DEVICE LINKING RULES ====================

@app.route('/api/lora/links', methods=['GET', 'POST'])
def api_lora_links():
    db_nodes = '/etc/lora/nodes.db'
    if request.method == 'GET':
        if not os.path.exists(db_nodes):
            return jsonify({'links': []})
        try:
            con = sqlite3.connect(db_nodes, timeout=5)
            con.row_factory = sqlite3.Row
            cur = con.cursor()
            cur.execute("""
                SELECT link_id, name, source_node, trigger_field, operator, threshold_val,
                       target_node, action_type, action_payload, turnaround_delay_ms, cooldown_sec,
                       enabled, last_triggered, last_status
                FROM node_links
                ORDER BY link_id ASC
            """)
            rows = [dict(r) for r in cur.fetchall()]
            con.close()
            return jsonify({'links': rows})
        except Exception as e:
            return jsonify({'error': str(e)}), 500

    # POST - create or update link
    try:
        data = request.json or {}
        link_id = data.get('link_id')
        name = data.get('name', 'Automation Rule')
        src = str(data.get('source_node', '')).strip().upper()
        field = str(data.get('trigger_field', 'temperature')).strip()
        op = str(data.get('operator', '>')).strip()
        thresh = float(data.get('threshold_val', 0.0))
        target = str(data.get('target_node', '')).strip().upper()
        payload = str(data.get('action_payload', '0101')).strip()
        delay_ms = int(data.get('turnaround_delay_ms', 1000))
        cooldown = int(data.get('cooldown_sec', 60))
        en = int(data.get('enabled', 1))

        if not src or not target or not payload:
            return jsonify({'error': 'Source, target, and action payload are required'}), 400

        con = sqlite3.connect(db_nodes, timeout=5)
        cur = con.cursor()
        if link_id:
            cur.execute("""
                UPDATE node_links
                SET name = ?, source_node = ?, trigger_field = ?, operator = ?, threshold_val = ?,
                    target_node = ?, action_payload = ?, turnaround_delay_ms = ?, cooldown_sec = ?,
                    enabled = ?
                WHERE link_id = ?
            """, (name, src, field, op, thresh, target, payload, delay_ms, cooldown, en, link_id))
        else:
            cur.execute("""
                INSERT INTO node_links (name, source_node, trigger_field, operator, threshold_val,
                                       target_node, action_payload, turnaround_delay_ms, cooldown_sec, enabled)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, (name, src, field, op, thresh, target, payload, delay_ms, cooldown, en))
        con.commit()
        con.close()
        return jsonify({'success': True, 'message': 'Linking rule saved!'})
    except Exception as e:
        return jsonify({'error': str(e)}), 500

@app.route('/api/lora/links/<int:link_id>', methods=['DELETE'])
def api_lora_link_delete(link_id):
    db_nodes = '/etc/lora/nodes.db'
    try:
        con = sqlite3.connect(db_nodes, timeout=5)
        cur = con.cursor()
        cur.execute("DELETE FROM node_links WHERE link_id = ?", (link_id,))
        con.commit()
        con.close()
        return jsonify({'success': True, 'message': f'Rule #{link_id} deleted.'})
    except Exception as e:
        return jsonify({'error': str(e)}), 500

@app.route('/api/lora/links/<int:link_id>/test', methods=['POST'])
def api_lora_link_test(link_id):
    db_nodes = '/etc/lora/nodes.db'
    db_ram = '/tmp/lora_messages.db'
    try:
        con = sqlite3.connect(db_nodes, timeout=5)
        cur = con.cursor()
        cur.execute("SELECT target_node, action_payload FROM node_links WHERE link_id = ?", (link_id,))
        row = cur.fetchone()
        con.close()
        if not row:
            return jsonify({'error': 'Rule not found'}), 404

        target, payload = row[0], row[1]
        try:
            raw_bytes = bytes.fromhex(payload)
        except ValueError:
            raw_bytes = payload.encode('utf-8')

        pkt = {
            "imme": True, "freq": 868.1, "rfch": 0, "powe": 27, "modu": "LORA",
            "datr": "SF7BW125", "codr": "4/5", "ipol": False, "size": len(raw_bytes),
            "data": base64.b64encode(raw_bytes).decode('ascii')
        }
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.sendto(json.dumps(pkt).encode('ascii'), ('127.0.0.1', 5556))
        s.close()

        # Log audit
        try:
            con_l = sqlite3.connect(db_ram, timeout=3)
            con_l.execute("""
                INSERT INTO link_execution_logs (link_id, timestamp, event_type, target_node, tx_status, details)
                VALUES (?, CURRENT_TIMESTAMP, 'MANUAL_TEST', ?, 'DISPATCHED', 'Triggered manually from Web Dashboard')
            """, (link_id, target))
            con_l.commit()
            con_l.close()
        except:
            pass

        return jsonify({'success': True, 'message': f'Test action dispatched to {target}: {payload}'})
    except Exception as e:
        return jsonify({'error': str(e)}), 500

@app.route('/api/lora/links/logs', methods=['GET'])
def api_lora_link_logs():
    db_ram = '/tmp/lora_messages.db'
    if not os.path.exists(db_ram):
        return jsonify({'logs': []})
    try:
        con = sqlite3.connect(db_ram, timeout=5)
        con.row_factory = sqlite3.Row
        cur = con.cursor()
        cur.execute("""
            SELECT id, link_id, timestamp, event_type, source_node, target_node, tx_status, details
            FROM link_execution_logs
            ORDER BY id DESC
            LIMIT 50
        """)
        rows = [dict(r) for r in cur.fetchall()]
        con.close()
        return jsonify({'logs': rows})
    except Exception as e:
        return jsonify({'error': str(e)}), 500

# ==================== MQTT & HOME ASSISTANT ====================

@app.route('/api/lora/mqtt', methods=['GET', 'POST'])
def api_lora_mqtt():
    cfg_path = '/etc/lora/config.json'
    if request.method == 'GET':
        try:
            with open(cfg_path, 'r', encoding='utf-8') as f:
                cfg = json.load(f)
            mqtt_cfg = cfg.get('mqtt', {
                'enabled': False,
                'server': '192.168.1.8',
                'port': 1883,
                'user': '',
                'password': '',
                'discovery_prefix': 'homeassistant',
                'state_prefix': 'lora'
            })
            return jsonify({'success': True, 'mqtt': mqtt_cfg})
        except Exception as e:
            return jsonify({'error': str(e)}), 500

    # POST - save MQTT config
    try:
        new_mqtt = request.json or {}
        with open(cfg_path, 'r', encoding='utf-8') as f:
            cfg = json.load(f)
        cfg['mqtt'] = new_mqtt
        with open(cfg_path, 'w', encoding='utf-8') as f:
            json.dump(cfg, f, indent=4)

        # Restart bridge service to reload new MQTT settings
        subprocess.run(['systemctl', 'restart', 'bobcat-lora-bridge.service'], timeout=10)
        return jsonify({'success': True, 'message': 'MQTT settings saved and bridge service restarted!'})
    except Exception as e:
        return jsonify({'error': str(e)}), 500

@app.route('/api/lora/mqtt/test', methods=['POST'])
def api_lora_mqtt_test():
    data = request.json or {}
    host = data.get('server', '127.0.0.1')
    try:
        port = int(data.get('port', 1883))
    except (ValueError, TypeError):
        port = 1883
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        s.settimeout(3.0)
        s.connect((host, port))
        s.close()
        return jsonify({'success': True, 'message': f'Successfully connected to MQTT broker at {host}:{port}'})
    except Exception as e:
        return jsonify({'success': False, 'error': f'Failed to connect to {host}:{port}: {e}'})


# ==================== LED & SYSTEM ====================

@app.route('/api/leds/test', methods=['POST'])
def api_leds_test():
    try:
        res = subprocess.run(['/usr/local/bin/test-leds'], capture_output=True, text=True, timeout=15)
        return jsonify({'success': True, 'output': res.stdout})
    except Exception as e:
        return jsonify({'error': str(e)}), 500

@app.route('/api/leds/set', methods=['POST'])
def api_leds_set():
    data = request.json or {}
    color = data.get('color', 'off').lower()
    mode = data.get('mode', 'on')

    if color not in COLOR_PRESETS and color != 'off':
        return jsonify({'error': f'Unknown color {color}'}), 400

    for ch, path in RGB_CHANNELS.items():
        try:
            with open(f"{path}/trigger", "w") as f:
                f.write("none")
            with open(f"{path}/brightness", "w") as f:
                f.write("0")
        except:
            pass

    if color == 'off' or mode == 'off':
        return jsonify({'success': True, 'color': 'off'})

    active_channels = COLOR_PRESETS.get(color, [])
    for ch in active_channels:
        path = RGB_CHANNELS[ch]
        try:
            if mode == 'heartbeat':
                with open(f"{path}/trigger", "w") as f:
                    f.write("heartbeat")
            else:
                with open(f"{path}/brightness", "w") as f:
                    f.write("1")
        except Exception as e:
            return jsonify({'error': str(e)}), 500

    return jsonify({'success': True, 'color': color, 'mode': mode})

@app.route('/api/system/reboot', methods=['POST'])
def api_system_reboot():
    def do_reboot():
        time.sleep(1)
        os.system('reboot')
    import threading
    threading.Thread(target=do_reboot).start()
    return jsonify({'success': True, 'message': 'System is rebooting...'})

@app.route('/api/system/poweroff', methods=['POST'])
def api_system_poweroff():
    def do_poweroff():
        time.sleep(1)
        os.system('poweroff')
    import threading
    threading.Thread(target=do_poweroff).start()
    return jsonify({'success': True, 'message': 'System is powering off...'})

if __name__ == '__main__':
    # Listen on dual-stack '::' so both IPv4 (192.168.1.x) and IPv6 (fe80::... link-local / LLMNR) work
    app.run(host='::', port=80, debug=False)
