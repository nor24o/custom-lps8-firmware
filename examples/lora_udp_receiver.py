#!/usr/bin/env python3
"""Minimal receiver for the bridge's custom UDP JSON stream.

Usage:
    python3 examples/lora_udp_receiver.py --bind 0.0.0.0 --port 9999
"""

import argparse
import json
import socket
import sys


def main():
    parser = argparse.ArgumentParser(description="Receive joined LoRa telemetry")
    parser.add_argument("--bind", default="0.0.0.0")
    parser.add_argument("--port", type=int, default=9999)
    args = parser.parse_args()

    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    sock.bind((args.bind, args.port))
    print("listening on %s:%d" % (args.bind, args.port))

    last_seq = None
    last_stream = None
    while True:
        try:
            data, address = sock.recvfrom(65535)
            event = json.loads(data.decode("utf-8"))
            stream_id = event.get("stream_id")
            if stream_id and stream_id != last_stream:
                last_stream = stream_id
                last_seq = None
            sequence = event.get("seq")
            if sequence is not None and last_seq is not None:
                expected = (last_seq + 1) & 0xFFFFFFFF
                if sequence != expected:
                    print("sequence gap: expected %d, received %d" % (expected, sequence), file=sys.stderr)
            if sequence is not None:
                last_seq = int(sequence)

            telemetry = event.get("telemetry") or {}
            print(json.dumps({
                "event_id": event.get("event_id"),
                "node_id": event.get("node_id"),
                "temperature": telemetry.get("temperature"),
                "battery": telemetry.get("battery"),
                "gateways": event.get("gateways_count", 0),
                "source": "%s:%d" % address,
            }, separators=(",", ":")))
        except KeyboardInterrupt:
            break
        except (UnicodeDecodeError, json.JSONDecodeError, ValueError) as exc:
            print("ignored invalid datagram: %s" % exc, file=sys.stderr)
        except OSError as exc:
            print("socket error: %s" % exc, file=sys.stderr)
            break

    sock.close()


if __name__ == "__main__":
    main()
