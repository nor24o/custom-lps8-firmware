#!/usr/bin/env python3
"""Read-only health checks plus an explicitly addressed loopback UDP test."""
import json
import socket
import urllib.request
import urllib.error
import time


def api(path, body=None):
    data = None if body is None else json.dumps(body).encode()
    request = urllib.request.Request('http://127.0.0.1' + path, data=data,
                                     headers={'Content-Type': 'application/json'})
    with urllib.request.urlopen(request, timeout=8) as response:
        return json.load(response)


deadline = time.monotonic() + 10
while True:
    try:
        api('/api/lora/profiles')
        break
    except urllib.error.URLError:
        if time.monotonic() >= deadline:
            raise
        time.sleep(.25)

for path in ['/api/lora/profiles', '/api/lora/unknown', '/api/lora/concentrators',
             '/api/lora/nodes', '/api/lora/pipeline', '/api/lora/downlink_settings']:
    api(path)
    print('OK', path)
identity = api('/api/lora/profiles/test', {'hex':'CAFE96B840EB0102014A',
    'profiles':[{'id':'verify','type_id':{'value':'CAFE'},'serial_id':{'offset':2,'length':4}}]})
assert identity['identity']['device_id'] == 'CAFE-96B840EB'
script = api('/api/lora/decoders/test', {'hex':'0104', 'scheme':{
    'id':'verification_js', 'name':'Verification', 'type':'js',
    'jsCode':'return {temperature: ((bytes[0]<<8)|bytes[1])/10};'}})
assert script['decoded']['temperature'] == 26
print('OK custom JavaScript decoder executed in server engine')
with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as receiver:
    receiver.bind(('127.0.0.1', 0))
    receiver.settimeout(5)
    api('/api/lora/udp_stream/test', {'dest_ip':'127.0.0.1',
        'dest_port':receiver.getsockname()[1], 'broadcast':False})
    event = json.loads(receiver.recvfrom(65535)[0])
    assert event['event'] == 'uplink_joined'
    assert event['gateways_count'] == 2
    print('OK UDP JSON delivered to loopback receiver')
packets = api('/api/lora/packets')
fresh = [p for p in packets if p.get('identity')]
print('Live identified packets:', len(fresh))
print('Joined multi-gateway packets:', sum(p.get('gateways_count', 0) > 1 for p in fresh))
