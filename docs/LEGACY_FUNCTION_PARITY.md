# Legacy function audit

This checklist compares the original `web/templates/index.html` with the native
console. A link to `/legacy` does not count as migration. Browser tests isolate
configuration writes and cancel disruptive hardware actions; those actions are
not claimed as RF/reboot/network-switch tests on the real device.

## Native workflows

- Overview: gateway/device counts, host CPU/RAM, radio RX/TX and channel activity.
- Latest activity: decoded fields when collapsed; raw payload and full event
  metadata when expanded; open rows survive periodic refresh.
- Live traffic: filtering, pause, per-gateway reception inspection and workbench.
- Gateways: saved satellite registration/edit/removal, reachability check and
  daemon RF configuration dialog.
- Packet profiles: native priority/type/serial/counter/checksum editor, selected
  byte ranges, live matching, duplication, enable/disable and decoder assignment.
- Decoders: samples, live packets, preserved candidate payload, segmentation,
  byte values, auto-slicing, automatic channel offset, field presets, signed and
  unsigned integer/float/ASCII/HEX/bool fields, scaling, units, JavaScript parser
  generation, live/server previews, import/export/reset, duplicate/delete and
  profile assignment. Scheme changes use explicit Save rather than legacy
  continuous autosave.
- Devices: enrollment, display name, role/class, model/group, discovery setting,
  TX power, registration removal and per-device history.
- Automations: rule create/edit/delete, threshold/operator, source/target,
  payload, turnaround/cooldown, manual test and audit log. The inherited engine
  action is a LoRa downlink; no nonfunctional HTTP/MQTT action is advertised.
- Transmit studio: HEX/text, frequency/SF/BW/power/coding rate/RF chain/preamble/
  IQ, default configuration and session history with calculated airtime.
- Radio: all saved HAL options plus optional HAL defaults, IF/radio arrays,
  calculated channels, legacy center presets, gain tables and explicit restart.
- MQTT/Home Assistant and UDP: native controls, destination tests, independent
  activation, preserved credentials and per-device discovery control.
- Network: live Ethernet/Wi-Fi information, scan/connect/disconnect and hostname.
- Hardware: power/test controls, temporary LED colors/sequence, temperature and
  G285 pin reference. Static chip labels are not presented as live measurements.
- System: uptime/CPU/RAM/disk, daemon status/autostart, start/stop/restart/enable/
  disable, service journal, hostname, reboot and poweroff confirmation dialogs.

## Intentional behavior changes from the old console

- Configuring settings no longer requires editing JSON.
- Network identity is defined by the packet profile's type plus serial, rather
  than a decoder's two-byte Node ID heuristic. Legacy profiles can omit serial.
- Recognized unknowns are marked and forwarded with a 300-entry rotating RAM
  registry. The old strict gate and automatic flash enrollment are superseded
  by the user's agreed policy.
- Arbitrary JavaScript is executed in a resource-limited server context, not
  merely in a browser preview.
- Gateway liveness and automation cooldowns use UTC consistently.
- LoRa submission is labeled dispatched/queued, not falsely device-acknowledged.
- Hardware and service-changing actions require an explicit user action; the
  migration/QA does not reboot, disconnect Wi-Fi or transmit test RF frames.
