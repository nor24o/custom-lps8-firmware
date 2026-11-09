# Native console

The console at `/` uses native forms and modal editors. The older interface
remains at `/legacy` as a fallback, but is not embedded in the new workflows.

## Packet profiles

Open **Packet profiles**, then **Create profile** or **Edit & inspect**. Select
the type, serial, optional counter, checksum and decoder. In the byte inspector,
click a start byte and Shift-click an end byte, then apply that range to a
header field. Live identification uses the server's actual profile matcher.

## Payload schemes

Open **Payload decoders** or inspect a live packet and choose **Open in decoder
workbench**. Use the byte inspector, channel segmentation, auto-slicer and field
presets to create a scheme. Edit names, endian/type, offsets, lengths, scaling,
additive correction and units directly in the field table. Save the scheme and
assign it to a packet profile using the assignment dialog.

Custom JavaScript function bodies use `bytes`, `hex`, and `pkt`. Server preview
and live decoding share the same runtime. Each execution gets a fresh context,
a 50 ms CPU limit, a 4 MB memory limit and no exported Python/OS bindings. The
runtime dependency is `quickjs-ng==0.18.0.1`, installed under `/opt/lora-python`.
See the [runtime API](https://github.com/genotrance/quickjs-ng) for its limit and
context semantics. Script failures retain the raw payload and produce a decoder
error rather than terminating the bridge.

## Integration and hardware settings

MQTT, UDP, pipeline, receive-frequency overrides and radio settings use native
form controls. Radio channel and gain-table arrays are editable as rows.
Downlink overrides inherit in the order defaults → type → device. Radio options
take effect after the explicitly selected concentrator restart. Scheme and
profile changes take effect on subsequent packets.

The profiler's canonical type/serial identity supersedes legacy per-scheme
Node ID heuristics for network registration. Existing saved schemes and
Home Assistant topic aliases are retained.
