import sqlite3
from datetime import datetime
import os
import re
import time
import json
import socket
import base64
import shutil
import subprocess
import uuid
import ipaddress
import sys
sys.path.insert(0, '/usr/local/bin')
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', 'bridge'))
from packet_profiles import normalize_priorities, identify_packet
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
    return render_template('console.html')


@app.route('/legacy')
def legacy_console():
    return render_template('index.html')


@app.route('/packet-profiler')
def packet_profiler():
    return render_template('index.html', standalone_profiler=True)


@app.route('/api/lora/profiles', methods=['GET', 'POST'])
def api_packet_profiles():
    path = '/etc/lora/packet_profiles.json'
    try:
        if request.method == 'GET':
            with open(path, encoding='utf-8') as f:
                return jsonify(json.load(f))
        data = request.get_json()
        profiles = normalize_priorities(data['profiles'])
        ids = set()
        for profile in profiles:
            if not profile.get('id') or profile['id'] in ids:
                raise ValueError('Each profile needs a unique id')
            ids.add(profile['id'])
            type_spec = profile['type_id']
            value = bytes.fromhex(type_spec['value'])
            offset = type_spec.get('offset', 0)
            if not value or not isinstance(offset, int) or not 0 <= offset <= 255:
                raise ValueError('Invalid type ID or offset')
            for field in ('serial_id', 'counter', 'checksum'):
                spec = profile.get(field)
                if spec is not None:
                    if not isinstance(spec, dict) or type(spec.get('offset')) is not int or type(spec.get('length')) is not int:
                        raise ValueError('Fields need integer offset and length')
                    if spec['offset'] < 0 or not 1 <= spec['length'] <= 255 or spec['offset'] + spec['length'] > 255:
                        raise ValueError('Field exceeds packet bounds')
            checksum = profile.get('checksum')
            if checksum and (checksum.get('algorithm'), checksum['length']) not in [('sum8', 1), ('crc32', 4)]:
                raise ValueError('Supported checksums: sum8 (1 byte), crc32 (4 bytes), big-endian')
        with open(path + '.tmp', 'w', encoding='utf-8') as f:
            json.dump({'profiles': profiles}, f, indent=2)
        os.replace(path + '.tmp', path)
        return jsonify(success=True, profiles=profiles)
    except (ValueError, KeyError, TypeError) as exc:
        return jsonify(error=str(exc)), 400
    except OSError as exc:
        return jsonify(error=str(exc)), 500


@app.route('/api/lora/profiles/test', methods=['POST'])
def api_test_profile():
    try:
        data = request.get_json()
        return jsonify(identity=identify_packet(bytes.fromhex(data['hex']), data['profiles']))
    except (ValueError, KeyError, TypeError) as exc:
        return jsonify(error=str(exc)), 400


@app.route('/api/lora/unknown')
def api_unknown_devices():
    try:
        with open('/dev/shm/lora_unknown.json', encoding='utf-8') as f:
            return jsonify(devices=json.load(f), limit=300)
    except FileNotFoundError:
        return jsonify(devices={}, limit=300)


@app.route('/api/lora/downlink_settings', methods=['GET', 'POST'])
def api_downlink_settings():
    path = '/etc/lora/config.json'
    try:
        with open(path, encoding='utf-8') as f:
            cfg = json.load(f)
        if request.method == 'GET':
            return jsonify(downlinks=cfg.get('downlinks', {'defaults': {'freq': cfg.get('tx_default_freq', 868100000)/1e6, 'sf': cfg.get('tx_default_sf', 7), 'power': cfg.get('tx_default_power', 14)}, 'types': {}, 'devices': {}}))
        rules = request.get_json()
        if not isinstance(rules, dict):
            raise ValueError('Settings must be an object')
        entries = [rules.get('defaults', {})] + list(rules.get('types', {}).values()) + list(rules.get('devices', {}).values())
        for entry in entries:
            if 'sf' in entry and not 5 <= int(entry['sf']) <= 12:
                raise ValueError('SF must be 5..12')
            if 'freq' in entry and not 100 <= float(entry['freq']) <= 1000:
                raise ValueError('Frequency must be MHz, between 100 and 1000')
            if 'power' in entry and not -20 <= int(entry['power']) <= 27:
                raise ValueError('Power must be -20..27 dBm')
        cfg['downlinks'] = rules
        with open(path+'.tmp', 'w', encoding='utf-8') as f:
            json.dump(cfg, f, indent=2)
        os.replace(path+'.tmp', path)
        return jsonify(success=True)
    except (ValueError, TypeError, AttributeError) as exc:
        return jsonify(error=str(exc)), 400
    except OSError as exc:
        return jsonify(error=str(exc)), 500

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
        pipeline.setdefault('dedup_window_ms', 150)
        pipeline.setdefault('join_frequency_repeats', True)

        if request.method == 'POST':
            data = request.get_json(silent=True) or {}
            for k in default_pipeline.keys():
                if k in data:
                    pipeline[k] = bool(data[k])
            if 'dedup_window_ms' in data:
                window = int(data['dedup_window_ms'])
                if not 25 <= window <= 5000:
                    return jsonify(error='dedup_window_ms must be 25..5000'), 400
                pipeline['dedup_window_ms'] = window
            if 'join_frequency_repeats' in data:
                if type(data['join_frequency_repeats']) is not bool:
                    return jsonify(error='join_frequency_repeats must be a boolean'), 400
                pipeline['join_frequency_repeats'] = data['join_frequency_repeats']
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
            with open(cfg_path, 'r', encoding='utf-8') as f:
                cfg = json.load(f)
            return jsonify({'success': True, 'config': cfg})
        except Exception as e:
            return jsonify({'error': str(e)}), 500

    # POST - update config
    try:
        new_cfg = request.get_json(silent=True) or {}
        if not isinstance(new_cfg, dict):
            return jsonify({'error': 'Invalid JSON configuration'}), 400

        current_cfg = {}
        if os.path.exists(cfg_path):
            try:
                with open(cfg_path, 'r', encoding='utf-8') as f:
                    current_cfg = json.load(f)
            except Exception:
                current_cfg = {}

        # Merge new configuration into current config
        for k, v in new_cfg.items():
            if isinstance(v, dict) and isinstance(current_cfg.get(k), dict):
                current_cfg[k].update(v)
            else:
                current_cfg[k] = v

        with open(cfg_path, 'w', encoding='utf-8') as f:
            json.dump(current_cfg, f, indent=4)

        restart = request.args.get('restart', 'false').lower() == 'true'
        if restart:
            subprocess.run(['systemctl', 'restart', 'raw-lora.service'], timeout=15)

        return jsonify({'success': True, 'message': 'Configuration saved successfully!', 'config': current_cfg})
    except Exception as e:
        return jsonify({'error': str(e)}), 500

@app.route('/api/lora/app/tx', methods=['POST'])
def api_lora_app_tx():
    data = request.get_json(silent=True) or {}
    payload_hex = data.get('payload_hex', '').strip()
    payload_text = data.get('payload_text', '').strip()
    freq = float(data.get('freq', 868.1))
    sf = int(data.get('sf', 7))
    bw = int(data.get('bw', 125))
    power = int(data.get('power', 27))
    codr = str(data.get('codr', '4/5')).strip()
    invert_iq = bool(data.get('invert_iq', data.get('ipol', False)))
    rfch = int(data.get('rfch', 0))
    preamble = int(data.get('preamble', 8))
    target_node = str(data.get('target_node', '')).strip().upper()
    if not 100 <= freq <= 1000 or sf not in range(5, 13) or bw not in (125, 250, 500):
        return jsonify(error='Invalid frequency, spreading factor or bandwidth'), 400
    if not -20 <= power <= 27 or rfch not in (0, 1) or codr not in ('4/5', '4/6', '4/7', '4/8') or not 6 <= preamble <= 65535:
        return jsonify(error='Invalid TX power, RF chain, coding rate or preamble'), 400

    if payload_hex:
        try:
            clean_h = payload_hex.replace(' ', '').replace('0x', '')
            raw_bytes = bytes.fromhex(clean_h)
        except Exception as e:
            return jsonify({'error': f'Invalid hex string: {e}'}), 400
    elif payload_text:
        raw_bytes = payload_text.encode('utf-8')
    else:
        raw_bytes = b'\x6B\x5A\x01\xFE\x02\x01\x01\x01'

    if not 1 <= len(raw_bytes) <= 255:
        return jsonify(error='Payload must contain 1..255 bytes'), 400

    b64 = base64.b64encode(raw_bytes).decode('ascii')
    pkt = {
        "imme": True,
        "freq": freq,
        "rfch": rfch,
        "powe": power,
        "modu": "LORA",
        "datr": f"SF{sf}BW{bw}",
        "codr": codr,
        "ipol": invert_iq,
        "prea": preamble,
        "size": len(raw_bytes),
        "data": b64
    }

    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.settimeout(2.0)
        s.sendto(json.dumps(pkt).encode('utf-8'), ('127.0.0.1', 5556))
        s.close()

        # LoRa Time-on-Air (ToA) Exact Physics Calculation
        import math
        bw_val = bw if bw > 0 else 125
        t_sym_ms = (2 ** sf) / (bw_val * 1.0)
        t_preamble_ms = (preamble + 4.25) * t_sym_ms
        cr_denom = int(codr.split('/')[1]) if '/' in codr else 5
        cr_val = cr_denom - 4
        de = 1 if (sf >= 11 and bw_val == 125) else 0
        num = 8 * len(raw_bytes) - 4 * sf + 28 + 16
        den = 4 * (sf - 2 * de)
        payload_syms = 8 + max(math.ceil(num / den) * (cr_val + 4), 0)
        t_payload_ms = payload_syms * t_sym_ms
        toa_ms = round(t_preamble_ms + t_payload_ms, 2)

        now_str = datetime.utcnow().strftime("%H:%M:%S")

        return jsonify({
            'success': True,
            'message': f'Transmitted {len(raw_bytes)} bytes downlink ({target_node or "Broadcast"} @ {freq:.3f} MHz, SF{sf}, {power} dBm)',
            'bytes_count': len(raw_bytes),
            'payload_hex': raw_bytes.hex().upper(),
            'freq': freq,
            'sf': sf,
            'bw': bw,
            'power': power,
            'codr': codr,
            'invert_iq': invert_iq,
            'toa_ms': toa_ms,
            'target_node': target_node or 'BROADCAST',
            'timestamp': now_str
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

@app.route('/api/lora/decoders/test', methods=['POST'])
def api_test_decoder():
    try:
        from bobcat_lora_bridge import execute_decoder
        data = request.get_json()
        payload = bytes.fromhex(data['hex'])
        if not payload or len(payload) > 255:
            raise ValueError('Payload must contain 1..255 bytes')
        scheme = dict(data['scheme'])
        scheme.update(enabled=True, matchType='default')
        scheme_id, name, decoded = execute_decoder(payload, payload.hex().upper(), [scheme], packet=data.get('packet', {}))
        return jsonify(scheme_id=scheme_id, name=name, decoded=decoded)
    except (ValueError, KeyError, TypeError) as exc:
        return jsonify(error=str(exc)), 400

@app.route('/api/lora/decoders', methods=['GET', 'POST'])
@app.route('/api/decoders', methods=['GET', 'POST'])
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
@app.route('/api/packets', methods=['GET'])
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

# ==================== CONCENTRATOR FLEET (MAIN & SATELLITES) ====================

@app.route('/api/lora/concentrators', methods=['GET', 'POST'])
def api_lora_concentrators():
    concentrators_path = '/tmp/lora_concentrators.json'
    satellites_path = '/etc/lora/satellites.json'
    
    cfg = {}
    try:
        with open('/etc/lora/config.json', 'r', encoding='utf-8') as f:
            cfg = json.load(f)
    except:
        pass
    mqtt_cfg = cfg.get('mqtt', {})
    state_prefix = mqtt_cfg.get('state_prefix', 'lora')
    main_eui = "0016C001F1500B48"

    if request.method == 'GET':
        data = {}
        if os.path.exists(concentrators_path):
            try:
                with open(concentrators_path, 'r', encoding='utf-8') as f:
                    data = json.load(f)
            except:
                pass
        
        # Ensure main concentrator is tracked
        if main_eui not in data:
            data[main_eui] = {
                "gateway_id": main_eui,
                "name": "Bobcat Main Concentrator",
                "type": "main",
                "ip": "127.0.0.1",
                "port": 5555,
                "protocol": "Local SX1302 SPI",
                "status": "ONLINE",
                "last_seen": "--",
                "uptime_s": 0,
                "rx_count": 0,
                "crc_err": 0,
                "nodes": {}
            }

        # Merge saved satellites from /etc/lora/satellites.json
        if os.path.exists(satellites_path):
            try:
                with open(satellites_path, 'r', encoding='utf-8') as f:
                    saved_sats = json.load(f)
                    for s in saved_sats:
                        gid = s.get('gateway_id')
                        if gid and gid not in data:
                            data[gid] = {
                                "gateway_id": gid,
                                "name": s.get('name', f"Satellite {gid}"),
                                "type": "satellite",
                                "ip": s.get('ip', '0.0.0.0'),
                                "port": s.get('port', 1700),
                                "protocol": s.get('protocol', 'Semtech UDP 1700'),
                                "status": "STANDBY",
                                "last_seen": s.get('last_seen', '--'),
                                "uptime_s": 0,
                                "rx_count": 0,
                                "crc_err": 0,
                                "nodes": {}
                            }
            except:
                pass

        concentrator_list = list(data.values())
        return jsonify({
            "success": True,
            "main_eui": main_eui,
            "topic_prefix": state_prefix,
            "broker": f"{mqtt_cfg.get('server', '127.0.0.1')}:{mqtt_cfg.get('port', 1883)}",
            "concentrators": concentrator_list
        })

    elif request.method == 'POST':
        req = request.get_json(silent=True) or {}
        gid = req.get('gateway_id', '').strip().upper()
        if not gid:
            return jsonify({'error': 'Missing gateway_id'}), 400
        
        saved_sats = []
        if os.path.exists(satellites_path):
            try:
                with open(satellites_path, 'r', encoding='utf-8') as f:
                    saved_sats = json.load(f)
            except:
                pass
        
        found = False
        for s in saved_sats:
            if s.get('gateway_id') == gid:
                s['name'] = req.get('name', s.get('name'))
                s['ip'] = req.get('ip', s.get('ip'))
                s['port'] = req.get('port', s.get('port', 1700))
                s['protocol'] = req.get('protocol', s.get('protocol', 'Semtech UDP 1700'))
                found = True
                break
        if not found:
            saved_sats.append({
                "gateway_id": gid,
                "name": req.get('name', f"Satellite {gid}"),
                "ip": req.get('ip', '192.168.1.50'),
                "port": req.get('port', 1700),
                "protocol": req.get('protocol', 'Semtech UDP 1700')
            })
        
        with open(satellites_path, 'w', encoding='utf-8') as f:
            json.dump(saved_sats, f, indent=2)

        return jsonify({'success': True, 'message': f'Satellite {gid} saved'})


@app.route('/api/lora/concentrators/<gateway_id>', methods=['DELETE'])
def api_lora_concentrator_delete(gateway_id):
    satellites_path = '/etc/lora/satellites.json'
    concentrators_path = '/tmp/lora_concentrators.json'
    gid = gateway_id.strip().upper()

    if os.path.exists(satellites_path):
        try:
            with open(satellites_path, 'r', encoding='utf-8') as f:
                saved_sats = json.load(f)
            saved_sats = [s for s in saved_sats if s.get('gateway_id') != gid]
            with open(satellites_path, 'w', encoding='utf-8') as f:
                json.dump(saved_sats, f, indent=2)
        except:
            pass

    if os.path.exists(concentrators_path):
        try:
            with open(concentrators_path, 'r', encoding='utf-8') as f:
                data = json.load(f)
            if gid in data and data[gid].get('type') != 'main':
                del data[gid]
                with open(concentrators_path, 'w', encoding='utf-8') as f:
                    json.dump(data, f, indent=2)
        except:
            pass

    return jsonify({'success': True, 'message': f'Concentrator {gid} removed'})


@app.route('/api/lora/concentrators/ping', methods=['POST'])
def api_lora_concentrators_ping():
    req = request.get_json(silent=True) or {}
    ip = req.get('ip', '').strip()
    if not ip or ip in ('127.0.0.1', '0.0.0.0', '--'):
        return jsonify({'success': True, 'reachable': True, 'latency': '< 0.1 ms'})
    try:
        res = subprocess.run(['ping', '-c', '1', '-W', '2', ip], capture_output=True, text=True)
        reachable = (res.returncode == 0)
        latency = '--'
        if reachable and 'time=' in res.stdout:
            latency = res.stdout.split('time=')[1].split()[0] + ' ms'
        return jsonify({'success': True, 'reachable': reachable, 'latency': latency})
    except Exception as e:
        return jsonify({'error': str(e)}), 500


@app.route('/api/lora/concentrators/simulate', methods=['POST'])
def api_lora_concentrators_simulate():
    req = request.get_json(silent=True) or {}
    sat_id = req.get('gateway_id', 'A840411F49824810').upper()
    try:
        token = b'\x12\x34'
        try:
            eui_bytes = bytes.fromhex(sat_id)
        except:
            eui_bytes = b'\xa8\x40\x41\x1f\x49\x82\x48\x10'
        if len(eui_bytes) != 8:
            eui_bytes = (eui_bytes + b'\x00' * 8)[:8]

        pkt_json = json.dumps({
            "rxpk": [{
                "time": datetime.utcnow().strftime("%H:%M:%S"),
                "tmst": int(time.time()),
                "chan": 2,
                "rfch": 0,
                "freq": 868.3,
                "stat": 1,
                "modu": "LORA",
                "datr": "SF12BW125",
                "codr": "4/5",
                "rssi": -41.4,
                "lsnr": 5.5,
                "size": 39,
                "data": "yv6WuEDrAQIBSgJxAAgAGQQkA2cBBASIAAAAAAAAAAAABQBIBgCH"
            }]
        }).encode('utf-8')

        datagram = b'\x02' + token + b'\x00' + eui_bytes + pkt_json
        sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        sock.sendto(datagram, ('127.0.0.1', 1700))
        sock.close()
        return jsonify({'success': True, 'message': f'Injected test uplink from Satellite Concentrator [{sat_id}]'})
    except Exception as e:
        return jsonify({'error': str(e)}), 500


# ==================== REMOTE GATEWAY CONFIGURATION & CONTROL ====================

@app.route('/api/lora/gateways/<gateway_id>/config', methods=['GET', 'POST'])
def api_lora_gateway_config(gateway_id):
    concentrators_path = '/tmp/lora_concentrators.json'
    gid = gateway_id.strip().upper()
    main_eui = "0016C001F1500B48"

    target_ip = None
    target_port = 5556

    if os.path.exists(concentrators_path):
        try:
            with open(concentrators_path, 'r', encoding='utf-8') as f:
                cdata = json.load(f)
            if gid in cdata:
                target_ip = cdata[gid].get('ip')
                target_port = cdata[gid].get('config', {}).get('port_down', cdata[gid].get('port_down', 5556))
        except:
            pass

    if not target_ip:
        return jsonify({'success': False, 'error': 'Gateway is not present in the fleet registry'}), 404

    if request.method == 'GET':
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.settimeout(2.5)
        try:
            request_id = "web-" + uuid.uuid4().hex
            s.sendto(json.dumps({"v": 1, "msg_type": "control", "cmd": "get_config", "request_id": request_id}, separators=(',', ':')).encode('utf-8'), (target_ip, target_port))
            data, _ = s.recvfrom(2048)
            cfg = json.loads(data.decode('utf-8'))
            if cfg.get('request_id') and cfg.get('request_id') != request_id:
                return jsonify({'success': False, 'error': 'Mismatched gateway response'}), 502
            return jsonify({'success': True, 'config': cfg, 'ip': target_ip, 'port': target_port})
        except Exception as e:
            if gid == main_eui or target_ip == '127.0.0.1':
                try:
                    with open('/etc/lora/config.json', 'r') as f:
                        lcfg = json.load(f)
                    return jsonify({'success': True, 'config': {
                        'rf0_freq': lcfg.get('rf0_freq', 867500000),
                        'rf1_freq': lcfg.get('rf1_freq', 868500000),
                        'sync_word': lcfg.get('sync_word', 'private'),
                        'tx_power': lcfg.get('tx_default_power', 27)
                    }, 'ip': target_ip, 'port': target_port})
                except:
                    pass
            return jsonify({'success': False, 'error': f"Could not reach gateway daemon on {target_ip}:{target_port} ({e})"}), 504
        finally:
            s.close()

    # POST: set_config
    req = request.get_json(silent=True) or {}
    new_cfg = {}
    if 'rf0_freq' in req:
        new_cfg['rf0_freq'] = int(float(req['rf0_freq']) * (1e6 if float(req['rf0_freq']) < 1e6 else 1))
    if 'rf1_freq' in req:
        new_cfg['rf1_freq'] = int(float(req['rf1_freq']) * (1e6 if float(req['rf1_freq']) < 1e6 else 1))
    if 'sync_word' in req:
        new_cfg['sync_word'] = str(req['sync_word']).lower()
    if 'tx_power' in req:
        new_cfg['tx_default_power'] = int(req['tx_power'])
    if 'tx_default_freq' in req:
        new_cfg['tx_default_freq'] = int(float(req['tx_default_freq']) * (1e6 if float(req['tx_default_freq']) < 1e6 else 1))

    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.settimeout(8.0)
    try:
        request_id = "web-" + uuid.uuid4().hex
        cmd_pkt = json.dumps({"v": 1, "msg_type": "control", "cmd": "set_config", "request_id": request_id, "config": new_cfg}, separators=(',', ':')).encode('utf-8')
        s.sendto(cmd_pkt, (target_ip, target_port))
        data, _ = s.recvfrom(2048)
        ack = json.loads(data.decode('utf-8'))
        if ack.get('request_id') and ack.get('request_id') != request_id:
            return jsonify({'success': False, 'error': 'Mismatched gateway acknowledgement'}), 502
        if ack.get('status') == 'error':
            return jsonify({'success': False, 'ack': ack, 'error': ack.get('message', 'Gateway rejected configuration')}), 502
        return jsonify({'success': True, 'ack': ack, 'message': 'Configuration applied and SX1302 restarted in-process!'})
    except socket.timeout:
        return jsonify({'success': False, 'error': f"Timed out waiting for confirmation from gateway on {target_ip}:{target_port}"}), 504
    except Exception as e:
        return jsonify({'success': False, 'error': str(e)}), 500
    finally:
        s.close()


@app.route('/api/lora/udp_stream', methods=['GET', 'POST'])
def api_lora_udp_stream():
    cfg_path = '/etc/lora/config.json'
    cfg = {}
    if os.path.exists(cfg_path):
        try:
            with open(cfg_path, 'r', encoding='utf-8') as f:
                cfg = json.load(f)
        except:
            pass

    if request.method == 'GET':
        udp_cfg = cfg.get('udp_stream', {
            'enabled': True,
            'dest_ip': '192.168.1.13',
            'dest_port': 9999,
            'broadcast': False
        })
        return jsonify({'success': True, 'udp_stream': udp_cfg})

    # POST
    req = request.get_json(silent=True) or {}
    udp_cfg = cfg.get('udp_stream', {})
    try:
        if 'enabled' in req:
            if not isinstance(req['enabled'], bool): raise ValueError('enabled must be a boolean')
            udp_cfg['enabled'] = req['enabled']
        if 'dest_ip' in req:
            udp_cfg['dest_ip'] = str(ipaddress.IPv4Address(req['dest_ip'].strip()))
        if 'dest_port' in req:
            port = int(req['dest_port'])
            if not 1 <= port <= 65535: raise ValueError('port must be between 1 and 65535')
            udp_cfg['dest_port'] = port
        if 'broadcast' in req:
            if not isinstance(req['broadcast'], bool): raise ValueError('broadcast must be a boolean')
            udp_cfg['broadcast'] = req['broadcast']
    except (ValueError, TypeError, AttributeError) as e:
        return jsonify({'success': False, 'error': str(e)}), 400
    cfg['udp_stream'] = udp_cfg

    try:
        with open(cfg_path, 'w', encoding='utf-8') as f:
            json.dump(cfg, f, indent=2)
        return jsonify({'success': True, 'message': 'UDP Stream settings saved!', 'udp_stream': udp_cfg})
    except Exception as e:
        return jsonify({'success': False, 'error': str(e)}), 500


@app.route('/api/lora/udp_stream/test', methods=['POST'])
def api_lora_udp_stream_test():
    req = request.get_json(silent=True) or {}
    try:
        with open('/etc/lora/config.json', 'r', encoding='utf-8') as f:
            saved = json.load(f).get('udp_stream', {})
    except (OSError, ValueError):
        saved = {}
    try:
        dest_ip = str(ipaddress.IPv4Address(req.get('dest_ip', saved.get('dest_ip', '192.168.1.13'))))
        dest_port = int(req.get('dest_port', saved.get('dest_port', 9999)))
        if not 1 <= dest_port <= 65535: raise ValueError('port must be between 1 and 65535')
        is_bcast = req.get('broadcast', saved.get('broadcast', False))
        if not isinstance(is_bcast, bool): raise ValueError('broadcast must be a boolean')
    except (ValueError, TypeError) as e:
        return jsonify({'success': False, 'error': str(e)}), 400

    sample_event = {
        "v": 1,
        "event": "uplink_joined",
        "seq": int(time.time() * 1000) & 0xFFFFFFFF,
        "event_id": "web-test-%s" % uuid.uuid4().hex,
        "timestamp": datetime.utcnow().isoformat() + "Z",
        "node_id": "CAFE",
        "deduplicated": True,
        "gateways_count": 2,
        "best_gateway": {
            "gateway_id": "0016C001F1500B48",
            "gateway_name": "Bobcat Main Concentrator",
            "rssi": -34.5,
            "snr": 8.2
        },
        "gateways": [
            {
                "gateway_id": "0016C001F1500B48",
                "gateway_name": "Bobcat Main Concentrator",
                "rssi": -34.5,
                "snr": 8.2,
                "freq": 868.5,
                "datr": "SF12BW125"
            },
            {
                "gateway_id": "A840411F49824810",
                "gateway_name": "Satellite LPS8",
                "rssi": -78.1,
                "snr": -1.5,
                "freq": 868.5,
                "datr": "SF12BW125"
            }
        ],
        "raw_hex": "CAFE96B840EB0102014A0271000000190429036701040488000000000000000000050048060095",
        "telemetry": {
            "node_id": "CAFE",
            "temperature": 26.0,
            "battery": 3.3,
            "accel_x": 0.0,
            "accel_y": 0.025,
            "accel_z": 1.065,
            "ch5_digital_in": 72,
            "ch6_digital_in": 149
        }
    }

    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        if is_bcast:
            s.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
        s.sendto(json.dumps(sample_event, separators=(',', ':')).encode('utf-8'), (dest_ip, dest_port))
        s.close()
        return jsonify({'success': True, 'message': f'Test UDP datagram sent to {dest_ip}:{dest_port}', 'payload': sample_event})
    except Exception as e:
        return jsonify({'success': False, 'error': str(e)}), 500

# ==================== NODES REGISTRY & MESSAGES ====================

@app.route('/api/lora/nodes', methods=['GET', 'POST'])
@app.route('/api/nodes', methods=['GET', 'POST'])
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

    with open('/etc/lora/config.json', encoding='utf-8') as f:
        cfg = json.load(f)
    rules = cfg.get('downlinks', {})
    rx = dict(rules.get('defaults', {}))
    rx.update(rules.get('types', {}).get(node_id.split('-')[0], {}))
    rx.update(rules.get('devices', {}).get(node_id, {}))
    power = int(data.get('power', rx.get('power', cfg.get('tx_default_power', 14))))
    sf = int(data.get('sf', rx.get('sf', cfg.get('tx_default_sf', 7))))
    freq = float(data.get('freq', rx.get('freq', cfg.get('tx_default_freq', 868100000)/1e6)))

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
        if op not in ('>', '>=', '<', '<=', '==', '!=', 'always') or delay_ms < 0 or cooldown < 0:
            return jsonify(error='Invalid operator, turnaround delay or cooldown'), 400

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

        from bobcat_lora_bridge import dispatch_lora_downlink
        if not dispatch_lora_downlink(target, payload):
            return jsonify(error='Downlink dispatch failed'), 502

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
