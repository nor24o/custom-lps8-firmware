import requests, time, json

IP = '192.168.1.15'
s = requests.Session()
r_auth = s.post(f'http://{IP}/cgi-bin/luci/', data={'luci_username': 'root', 'luci_password': 'root'})
assert r_auth.status_code == 200, f"Login failed: {r_auth.status_code}"

# Test 1: Get current config
r_cfg = s.get(f'http://{IP}/cgi-bin/luci/admin/lora/api_config')
print("Current config from device:")
print(json.dumps(r_cfg.json(), indent=2))

# Test 2: Save new config (US915 preset with custom power)
new_cfg = {
    "target_ip": "192.168.1.8",
    "gateway_id": "A84041FFFF16C21C",
    "port_up": 5555,
    "port_down": 5556,
    "status_port": 5557,
    "heartbeat_interval_s": 10,
    "rx_freq": 902320000,
    "rx_sf": 7,
    "rx_bw": 125,
    "rx_cr": 5,
    "rx_prlen": 8,
    "rx_syncword": 52,
    "tx_freq": 923300000,
    "tx_sf": 9,
    "tx_bw": 125,
    "tx_cr": 5,
    "tx_power": 17,
    "tx_prlen": 8,
    "tx_syncword": 52,
    "tx_invert": True,
    "led_rx": "dragino2:green:lan4",
    "led_tx": "dragino2:red:wan"
}

print("\nSaving new US915 configuration...")
r_save = s.post(f'http://{IP}/cgi-bin/luci/admin/lora/api_config', json=new_cfg)
print("Save response:", r_save.status_code, r_save.text)

print("\nWaiting 6 seconds for forwarder to apply and restart...")
time.sleep(6)

# Test 3: Verify new telemetry from status API
r_stat = s.get(f'http://{IP}/cgi-bin/luci/admin/lora/api_status')
print("\nUpdated status API response:")
print(json.dumps(r_stat.json(), indent=2))
