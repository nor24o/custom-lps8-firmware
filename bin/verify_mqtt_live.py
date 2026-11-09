#!/usr/bin/env python3
"""Verify receipt of a marked, identified uplink from the configured broker."""
import json
import time
import paho.mqtt.client as mqtt

with open('/etc/lora/config.json') as f:
    settings = json.load(f).get('mqtt', {})
client = mqtt.Client(client_id='bobcat-console-verification')
user = settings.get('user', settings.get('username', ''))
if user:
    client.username_pw_set(user, settings.get('password', ''))
received = []


def on_connect(connection, userdata, flags, rc):
    if rc != 0:
        print('MQTT connection rejected:', rc)
    if rc == 0:
        connection.subscribe(settings.get('state_prefix', 'lora') + '/+/state')


def on_message(connection, userdata, message):
    try:
        event = json.loads(message.payload)
        if event.get('identity') and event.get('registration_status') in ('registered', 'unknown'):
            received.append(event)
    except (ValueError, AttributeError):
        pass


client.on_connect = on_connect
client.on_message = on_message
client.connect(settings.get('server', '127.0.0.1'), int(settings.get('port', 1883)), 30)
deadline = time.monotonic() + 12
while time.monotonic() < deadline and not received:
    client.loop(timeout=1)
client.disconnect()
if not received:
    raise SystemExit('No identified MQTT state received during verification')
event = received[0]
print('OK MQTT JSON received:', event['identity']['device_id'], event['registration_status'])
print('Gateway receptions:', len(event.get('gateways', [])))
