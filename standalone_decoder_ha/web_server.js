#!/usr/bin/env node
/**
 * web_server.js — Zero-Dependency Node.js Web Server for LoRa Decoder Studio
 */

const http = require('http');
const fs = require('fs');
const path = require('path');
const url = require('url');

const PORT = parseInt(process.argv[2] || process.env.PORT || '8080', 10);
const DIR = __dirname;
const WEB_DIR = fs.existsSync(path.join(DIR, 'web')) ? path.join(DIR, 'web') : DIR;
const DECODERS_PATH = path.join(DIR, 'decoders.json');
const PACKETS_BUFFER = '/tmp/lora_packets.json';

const server = http.createServer((req, res) => {
    const parsed = url.parse(req.url, true);
    const reqPath = parsed.pathname;

    res.setHeader('Access-Control-Allow-Origin', '*');
    res.setHeader('Access-Control-Allow-Methods', 'GET, POST, OPTIONS');
    res.setHeader('Access-Control-Allow-Headers', 'Content-Type');

    if (req.method === 'OPTIONS') {
        res.writeHead(204);
        return res.end();
    }

    if (req.method === 'GET') {
        if (reqPath === '/' || reqPath === '/index.html') {
            const file = fs.existsSync(path.join(WEB_DIR, 'index.html')) ? path.join(WEB_DIR, 'index.html') : path.join(DIR, 'index.html');
            res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' });
            return fs.createReadStream(file).pipe(res);
        }

        if (reqPath === '/lora_decoder.js') {
            const file = fs.existsSync(path.join(WEB_DIR, 'lora_decoder.js')) ? path.join(WEB_DIR, 'lora_decoder.js') : path.join(DIR, 'lora_decoder.js');
            res.writeHead(200, { 'Content-Type': 'application/javascript; charset=utf-8' });
            return fs.createReadStream(file).pipe(res);
        }

        if (reqPath === '/api/decoders') {
            res.writeHead(200, { 'Content-Type': 'application/json; charset=utf-8' });
            if (fs.existsSync(DECODERS_PATH)) {
                return fs.createReadStream(DECODERS_PATH).pipe(res);
            }
            return res.end('{"version": 1, "schemes": []}');
        }

        if (reqPath === '/api/packets') {
            res.writeHead(200, { 'Content-Type': 'application/json; charset=utf-8' });
            if (fs.existsSync(PACKETS_BUFFER)) {
                try {
                    return fs.createReadStream(PACKETS_BUFFER).pipe(res);
                } catch(e) {}
            }
            const samplePkts = [
                {
                    hex: "CAFE96B840EB010201490271FFFB00180421036700B404880000000000000000",
                    status: "CRC_OK",
                    rssi: -28.4,
                    snr: 6.0,
                    freq: 868.5,
                    size: 32,
                    time: "2026-11-07 13:30:00"
                },
                {
                    hex: "AA0B64B2011107AA02050FA5",
                    status: "CRC_OK",
                    rssi: -42.1,
                    snr: 7.5,
                    freq: 868.1,
                    size: 12,
                    time: "2026-11-07 13:28:15"
                }
            ];
            return res.end(JSON.stringify(samplePkts));
        }

        if (reqPath === '/api/nodes') {
            res.writeHead(200, { 'Content-Type': 'application/json; charset=utf-8' });
            return res.end(JSON.stringify({
                nodes: [
                    { node_id: "CAFE", name: "Node CAFE (Multi-Sensor)", scheme: "scheme_node_cafe" },
                    { node_id: "AA0B", name: "Node AA0B (Sensor)", scheme: "scheme_1793991750048" }
                ]
            }));
        }

        // Static fallback
        const staticFile = path.join(WEB_DIR, reqPath);
        if (fs.existsSync(staticFile) && fs.statSync(staticFile).isFile()) {
            return fs.createReadStream(staticFile).pipe(res);
        }

        res.writeHead(404, { 'Content-Type': 'text/plain' });
        return res.end('Not Found');
    }

    if (req.method === 'POST' && reqPath === '/api/decoders') {
        let body = '';
        req.on('data', chunk => { body += chunk; });
        req.on('end', () => {
            try {
                const data = JSON.parse(body);
                fs.writeFileSync(DECODERS_PATH, JSON.stringify(data, null, 2), 'utf-8');
                const count = (data.schemes || []).length;
                res.writeHead(200, { 'Content-Type': 'application/json; charset=utf-8' });
                res.end(JSON.stringify({ status: 'saved', count: count }));
                console.log(`[HTTP] Saved ${count} decoder schemes to ${DECODERS_PATH}`);
            } catch(e) {
                res.writeHead(400, { 'Content-Type': 'application/json' });
                res.end(JSON.stringify({ error: e.message }));
            }
        });
        return;
    }

    res.writeHead(404);
    res.end();
});

server.listen(PORT, '0.0.0.0', () => {
    console.log("==============================================================");
    console.log(" LoRa Payload Decoder Studio — Node.js Web Server");
    console.log("==============================================================");
    console.log(` Local Web UI:    http://localhost:${PORT}`);
    console.log(` Network Address: http://0.0.0.0:${PORT}`);
    console.log(` Decoders File:   ${DECODERS_PATH}`);
    console.log(" Press Ctrl+C to terminate");
    console.log("==============================================================");
});
