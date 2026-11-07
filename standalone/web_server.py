#!/usr/bin/env python3
"""
web_server.py — Zero-Dependency Standalone Web Server for LoRa Decoder Studio
Works seamlessly across Python 3.6, 3.7, 3.8, 3.9, 3.10, 3.11, 3.12, 3.13+.
"""

import os
import sys
import json
import argparse
from http.server import HTTPServer, SimpleHTTPRequestHandler
import urllib.parse

DIR = os.path.dirname(os.path.abspath(__file__))
WEB_DIR = os.path.join(DIR, "web") if os.path.exists(os.path.join(DIR, "web")) else DIR
DECODERS_PATH = os.path.join(DIR, "decoders.json")
PACKETS_BUFFER = "/tmp/lora_packets.json"

class DecoderStudioHandler(SimpleHTTPRequestHandler):
    def translate_path(self, path):
        # Override to serve files from WEB_DIR
        parsed = urllib.parse.urlparse(path)
        clean_path = parsed.path.lstrip('/')
        target = os.path.join(WEB_DIR, clean_path)
        if os.path.exists(target):
            return target
        # Fallback to DIR
        target_dir = os.path.join(DIR, clean_path)
        if os.path.exists(target_dir):
            return target_dir
        return os.path.join(WEB_DIR, clean_path)

    def do_GET(self):
        parsed = urllib.parse.urlparse(self.path)
        path = parsed.path

        if path == "/" or path == "/index.html":
            index_path = os.path.join(WEB_DIR, "index.html")
            if not os.path.exists(index_path):
                index_path = os.path.join(DIR, "index.html")
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Cache-Control", "no-cache")
            self.end_headers()
            with open(index_path, "rb") as f:
                self.wfile.write(f.read())
            return

        if path == "/lora_decoder.js":
            js_path = os.path.join(WEB_DIR, "lora_decoder.js")
            if not os.path.exists(js_path):
                js_path = os.path.join(DIR, "lora_decoder.js")
            self.send_response(200)
            self.send_header("Content-Type", "application/javascript; charset=utf-8")
            self.end_headers()
            with open(js_path, "rb") as f:
                self.wfile.write(f.read())
            return

        if path == "/api/decoders":
            self.send_response(200)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Access-Control-Allow-Origin", "*")
            self.send_header("Cache-Control", "no-cache")
            self.end_headers()
            if os.path.exists(DECODERS_PATH):
                with open(DECODERS_PATH, "rb") as f:
                    self.wfile.write(f.read())
            else:
                self.wfile.write(b'{"version": 1, "schemes": []}')
            return

        if path == "/api/packets":
            self.send_response(200)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Access-Control-Allow-Origin", "*")
            self.send_header("Cache-Control", "no-cache")
            self.end_headers()
            if os.path.exists(PACKETS_BUFFER):
                try:
                    with open(PACKETS_BUFFER, "rb") as f:
                        self.wfile.write(f.read())
                    return
                except Exception:
                    pass
            # Default sample packets for interactive testing
            sample_pkts = [
                {
                    "hex": "CAFE96B840EB010201490271FFFB00180421036700B404880000000000000000",
                    "status": "CRC_OK",
                    "rssi": -28.4,
                    "snr": 6.0,
                    "freq": 868.5,
                    "size": 32,
                    "time": "2026-11-07 13:30:00"
                },
                {
                    "hex": "AA0B64B2011107AA02050FA5",
                    "status": "CRC_OK",
                    "rssi": -42.1,
                    "snr": 7.5,
                    "freq": 868.1,
                    "size": 12,
                    "time": "2026-11-07 13:28:15"
                },
                {
                    "hex": "50494E475F46524F4D5F4C505338",
                    "status": "CRC_OK",
                    "rssi": -35.0,
                    "snr": 8.0,
                    "freq": 868.3,
                    "size": 14,
                    "time": "2026-11-07 13:25:00"
                }
            ]
            self.wfile.write(json.dumps(sample_pkts).encode("utf-8"))
            return

        if path == "/api/nodes":
            self.send_response(200)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Access-Control-Allow-Origin", "*")
            self.send_header("Cache-Control", "no-cache")
            self.end_headers()
            nodes = [
                { "node_id": "CAFE", "name": "Node CAFE (Multi-Sensor)", "scheme": "scheme_node_cafe" },
                { "node_id": "AA0B", "name": "Node AA0B (Sensor)", "scheme": "scheme_1793991750048" }
            ]
            self.wfile.write(json.dumps({ "nodes": nodes }).encode("utf-8"))
            return

        super().do_GET()

    def do_POST(self):
        parsed = urllib.parse.urlparse(self.path)
        path = parsed.path

        if path == "/api/decoders":
            content_len = int(self.headers.get("Content-Length", 0))
            body = self.rfile.read(content_len)
            try:
                data = json.loads(body.decode("utf-8"))
                with open(DECODERS_PATH, "w", encoding="utf-8") as f:
                    json.dump(data, f, indent=2)
                schemes_cnt = len(data.get("schemes", []))
                resp = { "status": "saved", "count": schemes_cnt }
                self.send_response(200)
                self.send_header("Content-Type", "application/json; charset=utf-8")
                self.send_header("Access-Control-Allow-Origin", "*")
                self.end_headers()
                self.wfile.write(json.dumps(resp).encode("utf-8"))
                print(f"[HTTP] Successfully saved {schemes_cnt} decoder schemes to {DECODERS_PATH}")
            except Exception as e:
                self.send_response(400)
                self.send_header("Content-Type", "application/json; charset=utf-8")
                self.end_headers()
                self.wfile.write(json.dumps({ "error": str(e) }).encode("utf-8"))
            return

        self.send_response(404)
        self.end_headers()

def main():
    parser = argparse.ArgumentParser(description="Standalone LoRa Decoder Studio Web Server")
    parser.add_argument("-p", "--port", type=int, default=8080, help="HTTP Port (default: 8080)")
    parser.add_argument("-b", "--bind", type=str, default="0.0.0.0", help="Bind Address (default: 0.0.0.0)")
    args = parser.parse_args()

    server_address = (args.bind, args.port)
    httpd = HTTPServer(server_address, DecoderStudioHandler)

    print("==============================================================")
    print(" LoRa Payload Decoder Studio — Standalone Web Edition")
    print("==============================================================")
    print(f" Local Web UI:    http://localhost:{args.port}")
    print(f" Bind Address:    http://{args.bind}:{args.port}")
    print(f" Decoders File:   {DECODERS_PATH}")
    print(f" Web Root:        {WEB_DIR}")
    print(" Press Ctrl+C to terminate server")
    print("==============================================================")

    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        print("\\n[INFO] Server stopped by user.")

if __name__ == "__main__":
    main()
