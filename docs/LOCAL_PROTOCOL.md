# Local LoRa Protocol v1

This document defines the JSON contract between `raw_lora_app`,
`bobcat_lora_bridge.py`, and consumers of the final telemetry stream.

## Transport

| Path | Direction | Transport | Purpose |
| --- | --- | --- | --- |
| 5555/UDP | gateway -> bridge | JSON datagrams | status and uplinks |
| 1700/UDP | Semtech gateway -> bridge | Semtech UDP | `PUSH_DATA` and `PULL_DATA` |
| 5556/UDP | bridge/web -> gateway | JSON datagrams | TX and configuration commands |
| configured `udp_stream` port | bridge -> consumer | JSON datagrams | joined telemetry |

UDP is intentionally low-latency and at-most-once. It cannot guarantee zero
packet loss. Every JSON message therefore carries `v`, `gateway_id`, `seq`, and
`ts_ms`; consumers can detect gaps and decide whether to alarm, discard, or
request a fresh status snapshot. Configuration commands are acknowledged with
the same `request_id`.

All numeric radio frequencies are expressed in Hz in configuration/status and
MHz in Semtech `rxpk` records, matching the Semtech packet-forwarder format.

## Gateway status

```json
{
  "v": 1,
  "msg_type": "gateway_status",
  "gateway_id": "0016C001F1500B48",
  "seq": 42,
  "ts_ms": 1730000000123,
  "gateway_status": {
    "uptime_s": 812,
    "rf0_freq": 867500000,
    "rf1_freq": 868500000,
    "sync_word": "private",
    "tx_power": 27,
    "rx": 91,
    "tx": 3,
    "crc_err": 1,
    "tx_err": 0,
    "temp_c": 41.2,
    "port_down": 5556
  }
}
```

The bridge accepts the legacy `gateway_status` shape as well.

## Uplink ingress

The gateway uses the familiar Semtech `rxpk` array so that satellite forwarders
and the local concentrator share one decoder path:

```json
{
  "v": 1,
  "msg_type": "uplink",
  "gateway_id": "0016C001F1500B48",
  "seq": 9001,
  "ts_ms": 1730000000123,
  "rxpk": [{
    "tmst": 123456789,
    "freq": 868.1,
    "stat": 1,
    "modu": "LORA",
    "datr": "SF7BW125",
    "codr": "4/5",
    "rssis": -83.0,
    "lsnr": 9.5,
    "size": 8,
    "data": "qgsBAgMEBQY="
  }]
}
```

The bridge deduplicates on payload, exact-ish RF frequency, modulation,
datarate, and payload size inside a 150 ms rolling window. The same gateway is
only counted once per joined event.

## Configuration commands

```json
{
  "v": 1,
  "msg_type": "control",
  "cmd": "set_config",
  "request_id": "web-01JABC123",
  "config": {
    "rf0_freq": 867500000,
    "rf1_freq": 868500000,
    "sync_word": "private",
    "tx_default_power": 27
  }
}
```

The gateway replies to the sender:

```json
{
  "v": 1,
  "msg_type": "config_ack",
  "gateway_id": "0016C001F1500B48",
  "request_id": "web-01JABC123",
  "status": "ok",
  "applied": {"rf0_freq": 867500000, "rf1_freq": 868500000}
}
```

`get_config` uses the same envelope and returns `config_resp`. Keep UDP 5556
reachable only from the bridge/web host using the host firewall; the protocol
does not pretend that unauthenticated LAN UDP is secure.

## Final custom UDP stream

The bridge emits one event after deduplication and decoding:

```json
{
  "v": 1,
  "event": "uplink_joined",
  "stream_id": "1234-672A4D10",
  "event_id": "bridge-0000002A",
  "timestamp": "2026-11-08T12:00:00.123Z",
  "node_id": "CAFE",
  "raw_hex": "CAFE01020304",
  "deduplicated": true,
  "gateways_count": 2,
  "best_gateway": {"gateway_id": "0016C001F1500B48", "rssi": -83, "snr": 9.5},
  "gateways": [],
  "telemetry": {}
}
```

Consumers should use `event_id` for idempotency and monitor `seq` when it is
present. A UDP receiver must not block the socket loop on database or network
work; enqueue events to a worker if processing is non-trivial.
