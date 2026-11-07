#!/usr/bin/env node
/**
 * web_server.js — Node.js Standalone LoRa Studio, Home Assistant Bridge & MQTT Gateway
 * Zero npm dependencies — standard Node.js (http, net, fs, path, url).
 */

const http = require('http');
const net = require('net');
const fs = require('fs');
const path = require('path');
const url = require('url');

const PORT = parseInt(process.argv[2] || process.env.PORT || '8080', 10);
const DIR = __dirname;
const WEB_DIR = fs.existsSync(path.join(DIR, 'web')) ? path.join(DIR, 'web') : DIR;
const CONFIG_PATH = path.join(DIR, 'config.json');
const DECODERS_PATH = path.join(DIR, 'decoders.json');
const PACKETS_BUFFER = '/tmp/lora_packets.json';

const DEFAULT_CONFIG = {
    mqtt: {
        host: "192.168.1.13",
        port: 1883,
        user: "admin",
        password: "admin",
        ha_prefix: "homeassistant",
        state_prefix: "lora",
        retain: true,
        auto_enroll: false
    }
};

function loadConfig() {
    if (fs.existsSync(CONFIG_PATH)) {
        try {
            return JSON.parse(fs.readFileSync(CONFIG_PATH, 'utf-8'));
        } catch(e) {}
    }
    return JSON.parse(JSON.stringify(DEFAULT_CONFIG));
}

function saveConfig(cfg) {
    fs.writeFileSync(CONFIG_PATH, JSON.stringify(cfg, null, 2), 'utf-8');
}

function mqttPublish(host, port, user, password, topic, payload, retain, callback) {
    const s = new net.Socket();
    s.setTimeout(4000);
    
    s.connect(port, host, () => {
        const clientId = Buffer.from('node_studio_' + (Date.now() % 100000));
        let flags = 0x02;
        const pList = [];
        
        const cLenBuf = Buffer.alloc(2);
        cLenBuf.writeUInt16BE(clientId.length);
        pList.push(cLenBuf, clientId);
        
        if (user) {
            flags |= 0x80;
            const uBuf = Buffer.from(user, 'utf-8');
            const uLen = Buffer.alloc(2);
            uLen.writeUInt16BE(uBuf.length);
            pList.push(uLen, uBuf);
        }
        if (password) {
            flags |= 0x40;
            const pwBuf = Buffer.from(password, 'utf-8');
            const pwLen = Buffer.alloc(2);
            pwLen.writeUInt16BE(pwBuf.length);
            pList.push(pwLen, pwBuf);
        }
        
        const payloadBuf = Buffer.concat(pList);
        const varHeader = Buffer.from([0x00, 0x04, 0x4d, 0x51, 0x54, 0x54, 0x04, flags, 0x00, 0x3c]);
        const connBody = Buffer.concat([varHeader, payloadBuf]);
        
        const header = Buffer.from([0x10, connBody.length]);
        s.write(Buffer.concat([header, connBody]));
    });

    let connected = false;
    s.on('data', (data) => {
        if (!connected && data.length >= 4 && data[0] === 0x20) {
            if (data[3] !== 0) {
                s.destroy();
                return callback && callback(new Error('MQTT Connack rejected: ' + data[3]));
            }
            connected = true;
            
            // Send publish
            const topBuf = Buffer.from(topic, 'utf-8');
            const payBuf = Buffer.from(typeof payload === 'string' ? payload : JSON.stringify(payload), 'utf-8');
            const topLen = Buffer.alloc(2);
            topLen.writeUInt16BE(topBuf.length);
            const pubBody = Buffer.concat([topLen, topBuf, payBuf]);
            
            const pubFlags = 0x30 | (retain ? 0x01 : 0x00);
            
            // Encode rem len
            const remBytes = [];
            let l = pubBody.length;
            do {
                let eb = l % 128;
                l = Math.floor(l / 128);
                if (l > 0) eb |= 128;
                remBytes.push(eb);
            } while (l > 0);
            
            const pubHeader = Buffer.from([pubFlags, ...remBytes]);
            s.write(Buffer.concat([pubHeader, pubBody]));
            
            // Send disconnect
            s.write(Buffer.from([0xe0, 0x00]));
            s.end();
            if (callback) callback(null, true);
        }
    });

    s.on('timeout', () => {
        s.destroy();
        if (callback) callback(new Error('Connection timed out'));
    });

    s.on('error', (err) => {
        if (callback) callback(err);
    });
}

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

        if (reqPath === '/api/config' || reqPath === '/api/mqtt') {
            res.writeHead(200, { 'Content-Type': 'application/json; charset=utf-8' });
            return res.end(JSON.stringify(loadConfig()));
        }

        if (reqPath === '/api/decoders') {
            res.writeHead(200, { 'Content-Type': 'application/json; charset=utf-8' });
            if (fs.existsSync(DECODERS_PATH)) {
                return fs.createReadStream(DECODERS_PATH).pipe(res);
            }
            return res.end('{"version": 1, "schemes": []}');
        }

        if (reqPath === '/api/nodes') {
            res.writeHead(200, { 'Content-Type': 'application/json; charset=utf-8' });
            return res.end(JSON.stringify({
                nodes: [
                    {
                        node_id: "CAFE",
                        name: "Node CAFE (Multi-Sensor)",
                        scheme: "Node CAFE (Multi-Sensor LPP)",
                        serial: "96B840EB",
                        sensors: ["Temperature", "Battery", "Acceleration X/Y/Z"],
                        enrolled: true,
                        last_seen: "Just now"
                    },
                    {
                        node_id: "AA0B",
                        name: "Node AA0B (Sensor)",
                        scheme: "Standard 2-Byte Node ID + TLV",
                        serial: "64B20111",
                        sensors: ["Temperature", "Battery", "Sequence"],
                        enrolled: true,
                        last_seen: "3 minutes ago"
                    }
                ]
            }));
        }

        if (reqPath === '/api/packets') {
            res.writeHead(200, { 'Content-Type': 'application/json; charset=utf-8' });
            if (fs.existsSync(PACKETS_BUFFER)) {
                try { return fs.createReadStream(PACKETS_BUFFER).pipe(res); } catch(e) {}
            }
            return res.end(JSON.stringify([
                {
                    hex: "CAFE96B840EB010201490271FFFB00180421036700B404880000000000000000",
                    status: "CRC_OK",
                    rssi: -28.4,
                    snr: 6.0,
                    freq: 868.5,
                    size: 32,
                    time: "2026-11-07 13:45:00",
                    decoded: "Temp: 18.0°C | Batt: 3.29V | Accel Z: 1.057g"
                },
                {
                    hex: "AA0B64B2011107AA02050FA5",
                    status: "CRC_OK",
                    rssi: -42.1,
                    snr: 7.5,
                    freq: 868.1,
                    size: 12,
                    time: "2026-11-07 13:42:15",
                    decoded: "Temp: 19.5°C | Batt: 4.01V | Seq: 170"
                }
            ]));
        }

        const staticFile = path.join(WEB_DIR, reqPath);
        if (fs.existsSync(staticFile) && fs.statSync(staticFile).isFile()) {
            return fs.createReadStream(staticFile).pipe(res);
        }

        res.writeHead(404);
        return res.end('Not Found');
    }

    if (req.method === 'POST') {
        let body = '';
        req.on('data', chunk => { body += chunk; });
        req.on('end', () => {
            let data = {};
            try { data = JSON.parse(body); } catch(e) {}

            if (reqPath === '/api/config' || reqPath === '/api/mqtt') {
                const cfg = loadConfig();
                if (data.mqtt) Object.assign(cfg.mqtt, data.mqtt);
                else Object.assign(cfg.mqtt, data);
                saveConfig(cfg);
                res.writeHead(200, { 'Content-Type': 'application/json' });
                return res.end(JSON.stringify({ status: 'saved', config: cfg }));
            }

            if (reqPath === '/api/mqtt/test') {
                const cfg = loadConfig();
                const m = (data.host ? data : cfg.mqtt) || {};
                const t0 = Date.now();
                mqttPublish(m.host || '127.0.0.1', m.port || 1883, m.user, m.password, 'lora/_ping', 'pong', false, (err) => {
                    res.writeHead(200, { 'Content-Type': 'application/json' });
                    if (err) {
                        return res.end(JSON.stringify({ success: false, message: err.message }));
                    }
                    const latency = Date.now() - t0;
                    return res.end(JSON.stringify({ success: true, message: `Connected to ${m.host}:${m.port} (${latency} ms)` }));
                });
                return;
            }

            if (reqPath === '/api/nodes/telemetry') {
                const cfg = loadConfig();
                const m = cfg.mqtt || {};
                const nodeId = (data.node_id || 'CAFE').toUpperCase();
                const topic = `${m.state_prefix || 'lora'}/${nodeId}/state`;
                const metrics = data.metrics || { node_id: nodeId, temperature: 18.5, battery: 3.29, accel_x: -0.004, accel_y: 0.024, accel_z: 1.055, device_serial: "96B840EB" };
                mqttPublish(m.host || '127.0.0.1', m.port || 1883, m.user, m.password, topic, JSON.stringify(metrics), true, (err) => {
                    res.writeHead(200, { 'Content-Type': 'application/json' });
                    if (err) return res.end(JSON.stringify({ success: false, error: err.message }));
                    return res.end(JSON.stringify({ success: true, topic: topic, message: `Dispatched live telemetry to ${topic}` }));
                });
                return;
            }

            if (reqPath === '/api/nodes/enroll') {
                const cfg = loadConfig();
                const m = cfg.mqtt || {};
                const nodeId = (data.node_id || 'CAFE').toUpperCase();
                const discTopic = `${m.ha_prefix || 'homeassistant'}/sensor/${nodeId}_temperature/config`;
                const payload = {
                    name: `LoRa Node ${nodeId} Temperature`,
                    state_topic: `${m.state_prefix || 'lora'}/${nodeId}/state`,
                    value_template: "{{ value_json.temperature }}",
                    unique_id: `lora_${nodeId}_temperature`,
                    unit_of_measurement: "°C",
                    device_class: "temperature"
                };
                mqttPublish(m.host || '127.0.0.1', m.port || 1883, m.user, m.password, discTopic, JSON.stringify(payload), true, (err) => {
                    res.writeHead(200, { 'Content-Type': 'application/json' });
                    if (err) return res.end(JSON.stringify({ success: false, error: err.message }));
                    return res.end(JSON.stringify({ success: true, message: `Enrolled Node ${nodeId} in Home Assistant` }));
                });
                return;
            }

            if (reqPath === '/api/decoders') {
                fs.writeFileSync(DECODERS_PATH, JSON.stringify(data, null, 2), 'utf-8');
                res.writeHead(200, { 'Content-Type': 'application/json' });
                return res.end(JSON.stringify({ status: 'saved', count: (data.schemes || []).length }));
            }

            res.writeHead(404);
            return res.end();
        });
        return;
    }

    res.writeHead(404);
    res.end();
});

server.listen(PORT, '0.0.0.0', () => {
    const cfg = loadConfig();
    const m = cfg.mqtt || {};
    console.log("==============================================================");
    console.log(" LoRa Studio, Home Assistant Bridge & MQTT Gateway");
    console.log("==============================================================");
    console.log(` Local Web UI:    http://localhost:${PORT}`);
    console.log(` Target HA MQTT:  ${m.host}:${m.port} (User: ${m.user})`);
    console.log(` Decoders Doc:    ${DECODERS_PATH}`);
    console.log(" Press Ctrl+C to terminate");
    console.log("==============================================================");
});
