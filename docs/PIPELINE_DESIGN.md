# Custom LoRa server: staged design

Status: the light console and enforced uplink pipeline are deployed. Profiles,
canonical identity, optional counters/checksums, configurable joining, unknown
device rotation, enrollment and marked UDP/MQTT JSON are implemented. Tests
cover profile matching, rotation, rejection and joined receptions. Downlinks
currently dispatch through the local concentrator using default/type/device
frequency settings; listening-window scheduling and satellite downlink routing
remain outside this implementation.

## Agreed requirements

- The Bobcat runs the central server and its own concentrator. Satellite
  gateways send receptions over Semtech UDP or custom JSON UDP.
- Packets follow configurable custom protocols, not standard LoRaWAN frames.
  A profile defines how to extract the node type ID and serial ID. Their
  combination uniquely identifies a device; the type ID groups devices and
  can select a decoder.
- A valid unknown device can be decoded and forwarded with an explicit unknown
  registration status. Keep at most 300 unknown devices in RAM; evict the
  least recently seen when necessary. Registered devices persist separately.
- Nodes can transmit on multiple uplink frequencies. A node normally listens
  on a common downlink frequency, with per-type and per-device exceptions.
- MQTT and JSON UDP outputs are independently enabled and configurable.
- The management console is light themed and inspired by TTN, with clear
  gateway, device, live traffic, integration and settings navigation.

## Proposed processing stages

1. **Ingress:** receive local and satellite packets, preserving gateway ID,
   frequency, radio settings, signal strength, receive time and raw bytes.
   Validate the transport and report malformed or rejected input.
2. **Identify:** select a configurable header profile, validate its required
   fields and derive type ID plus serial ID. An unknown decoder must not
   automatically mean an invalid packet.
3. **Join receptions:** collect receptions of the same transmission across
   gateways and preserve each gateway's RF metadata. Elect a best reception
   by SNR, then RSSI. A collection window adds latency and must be configurable.
4. **Correlate repeated transmissions:** optionally group transmissions on
   different frequencies when a profile provides a reliable message identity.
   Preserve each transmission and its individual receptions within the group.
5. **Registry and decode:** look up the device, maintain the bounded unknown
   registry, and choose a type decoder or device override. Decode once for the
   resulting message; retain raw bytes if decoding fails.
6. **Store and dispatch:** show traffic and outcomes in the console and send
   structured JSON to independently configured UDP and MQTT destinations.
   Track delivery failures and queue limits; UDP does not guarantee delivery.
7. **Downlink:** use a device-specific listening profile, a queue and explicit
   scheduling/status feedback. Gateway choice must account for frequency,
   capability and availability, not signal quality alone.

## Open decisions before implementation

- Whether repeated transmissions on different frequencies should become one
  logical message, and whether profiles expose a common message counter.
- Collection/cooldown windows and behavior when no counter is available.
- Exact profile matching and validity rules, including ambiguous matches,
  optional checksums, and legacy formats that do not contain a serial ID.
- Device listening windows, downlink queue expiry and acknowledgements.
- Output JSON fields, MQTT topics and retention/QoS, UDP destinations, and
  the unknown-device marker.
- History retention and console layout/details for each section.

## Implementation sequence

1. Agree on packet profiles and identity, then implement and test extraction.
2. Agree on reception and repeat correlation, then implement and test with
   simulated multi-gateway and multi-frequency packets.
3. Implement the temporary unknown registry and persistent enrollment.
4. Agree on decoder selection and error handling, then implement and test.
5. Agree on JSON and integration settings, then implement and test outputs.
6. Agree on downlink behavior, then implement and test scheduling.
7. Agree on console navigation and page layouts, implement the light theme,
   and verify workflows on the Bobcat.

Existing behavior must be compared against this design before migration. Deploy
each completed stage with configuration and rollback preserved; validate on
the device before claiming that hardware-dependent behavior works.
