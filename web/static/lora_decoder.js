/**
 * lora_decoder.js — LoRa Payload Multi-Scheme Decoding Engine for Dragino LuCI
 * 
 * Supports:
 * - Rule-based scheme matching: Prefix (header), Payload Size, Regex Pattern, Custom Condition, Default/Fallback
 * - Decoding methods: JavaScript Code (TTN/ChirpStack format), Visual Field Slicer, ASCII String, Cayenne LPP
 * - Bidirectional persistence with /etc/lora/decoders.json via LuCI REST API
 */

(function(window) {
    'use strict';

    var LoraDecoder = {};

    // -------------------------------------------------------------------------
    // Utility functions: Hex, Bytes, ASCII
    // -------------------------------------------------------------------------

    LoraDecoder.hexToBytes = function(hex) {
        if (!hex || typeof hex !== 'string') return [];
        var clean = hex.replace(/[^0-9a-fA-F]/g, '');
        if (clean.length % 2 !== 0) clean = '0' + clean;
        var bytes = [];
        for (var i = 0; i < clean.length; i += 2) {
            bytes.push(parseInt(clean.substr(i, 2), 16));
        }
        return bytes;
    };

    LoraDecoder.bytesToHex = function(bytes) {
        if (!bytes || !bytes.length) return '';
        var hex = '';
        for (var i = 0; i < bytes.length; i++) {
            var b = (bytes[i] & 0xFF).toString(16);
            hex += (b.length < 2 ? '0' : '') + b;
        }
        return hex;
    };

    LoraDecoder.isAscii = function(bytes) {
        if (!bytes || bytes.length === 0) return false;
        for (var i = 0; i < bytes.length; i++) {
            var b = bytes[i];
            // Printable ASCII: space (32) to tilde (126), plus CR, LF, TAB
            if ((b < 32 || b > 126) && b !== 10 && b !== 13 && b !== 9) {
                return false;
            }
        }
        return true;
    };

    LoraDecoder.bytesToAscii = function(bytes) {
        var str = '';
        for (var i = 0; i < bytes.length; i++) {
            var b = bytes[i];
            if (b >= 32 && b <= 126) {
                str += String.fromCharCode(b);
            } else if (b === 10) {
                str += '\\n';
            } else if (b === 13) {
                str += '\\r';
            } else if (b === 9) {
                str += '\\t';
            } else {
                str += '.';
            }
        }
        return str;
    };

    // -------------------------------------------------------------------------
    // Standard Cayenne LPP (IPSO) Decoder
    // -------------------------------------------------------------------------

    LoraDecoder.decodeCayenneLpp = function(bytes) {
        var out = {};
        var i = 0;
        var parsedAny = false;

        while (i < bytes.length) {
            var ch = bytes[i++];
            if (i >= bytes.length) break;
            var type = bytes[i++];
            var pfx = "ch" + ch + "_";

            if (type === 0x00) { // Digital Input (1B)
                if (i >= bytes.length) break;
                out[pfx + "digital_in"] = bytes[i++];
                parsedAny = true;
            } else if (type === 0x01) { // Digital Output (1B)
                if (i >= bytes.length) break;
                out[pfx + "digital_out"] = bytes[i++];
                parsedAny = true;
            } else if (type === 0x02) { // Analog Input (2B, 0.01 signed)
                if (i + 1 >= bytes.length) break;
                var val = (bytes[i++] << 8) | bytes[i++];
                if (val & 0x8000) val -= 0x10000;
                out[pfx + "analog_in"] = +(val * 0.01).toFixed(2);
                parsedAny = true;
            } else if (type === 0x03) { // Analog Output (2B, 0.01 signed)
                if (i + 1 >= bytes.length) break;
                var val = (bytes[i++] << 8) | bytes[i++];
                if (val & 0x8000) val -= 0x10000;
                out[pfx + "analog_out"] = +(val * 0.01).toFixed(2);
                parsedAny = true;
            } else if (type === 0x65) { // Illuminance (2B, 1 Lux)
                if (i + 1 >= bytes.length) break;
                out[pfx + "illuminance_lux"] = (bytes[i++] << 8) | bytes[i++];
                parsedAny = true;
            } else if (type === 0x66) { // Presence (1B)
                if (i >= bytes.length) break;
                out[pfx + "presence"] = bytes[i++];
                parsedAny = true;
            } else if (type === 0x67) { // Temperature (2B, 0.1 °C signed)
                if (i + 1 >= bytes.length) break;
                var val = (bytes[i++] << 8) | bytes[i++];
                if (val & 0x8000) val -= 0x10000;
                out[pfx + "temperature_c"] = +(val * 0.1).toFixed(1);
                parsedAny = true;
            } else if (type === 0x68) { // Humidity (1B, 0.5 %)
                if (i >= bytes.length) break;
                out[pfx + "humidity_pct"] = +(bytes[i++] * 0.5).toFixed(1);
                parsedAny = true;
            } else if (type === 0x71) { // Accelerometer (6B, 0.001 G signed)
                if (i + 5 >= bytes.length) break;
                var ax = (bytes[i++] << 8) | bytes[i++]; if (ax & 0x8000) ax -= 0x10000;
                var ay = (bytes[i++] << 8) | bytes[i++]; if (ay & 0x8000) ay -= 0x10000;
                var az = (bytes[i++] << 8) | bytes[i++]; if (az & 0x8000) az -= 0x10000;
                out[pfx + "accel_g"] = { x: +(ax*0.001).toFixed(3), y: +(ay*0.001).toFixed(3), z: +(az*0.001).toFixed(3) };
                parsedAny = true;
            } else if (type === 0x73) { // Barometer (2B, 0.1 hPa)
                if (i + 1 >= bytes.length) break;
                var val = (bytes[i++] << 8) | bytes[i++];
                out[pfx + "barometer_hpa"] = +(val * 0.1).toFixed(1);
                parsedAny = true;
            } else if (type === 0x88) { // GPS (9B)
                if (i + 8 >= bytes.length) break;
                var lat = (bytes[i++] << 16) | (bytes[i++] << 8) | bytes[i++]; if (lat & 0x800000) lat -= 0x1000000;
                var lon = (bytes[i++] << 16) | (bytes[i++] << 8) | bytes[i++]; if (lon & 0x800000) lon -= 0x1000000;
                var alt = (bytes[i++] << 16) | (bytes[i++] << 8) | bytes[i++]; if (alt & 0x800000) alt -= 0x1000000;
                out[pfx + "gps"] = { latitude: +(lat * 0.0001).toFixed(4), longitude: +(lon * 0.0001).toFixed(4), altitude_m: +(alt * 0.01).toFixed(2) };
                parsedAny = true;
            } else {
                break;
            }
        }

        return parsedAny ? out : null;
    };

    // -------------------------------------------------------------------------
    // Visual Field Slicer Decoder (No-Code mapping)
    // -------------------------------------------------------------------------

    LoraDecoder.decodeFields = function(bytes, fields) {
        var out = {};
        if (!fields || !fields.length) return out;

        for (var k = 0; k < fields.length; k++) {
            var f = fields[k];
            if (!f.name) continue;

            var off = parseInt(f.offset, 10) || 0;
            var len = parseInt(f.length, 10) || 1;
            var scale = (f.scale !== undefined && f.scale !== '') ? parseFloat(f.scale) : 1;
            var add = (f.add !== undefined && f.add !== '') ? parseFloat(f.add) : 0;
            var unit = f.unit ? (' ' + f.unit) : '';

            if (off >= bytes.length) continue;

            var type = f.type || 'uint8';

            if (type === 'hex') {
                var h = '';
                for (var j = 0; j < len && (off + j) < bytes.length; j++) {
                    var b = (bytes[off + j] & 0xFF).toString(16);
                    h += (b.length < 2 ? '0' : '') + b;
                }
                out[f.name] = h;
                continue;
            }

            if (type === 'ascii') {
                var s = '';
                for (var j = 0; j < len && (off + j) < bytes.length; j++) {
                    s += String.fromCharCode(bytes[off + j]);
                }
                out[f.name] = s;
                continue;
            }

            var rawVal = 0;
            if (type === 'uint8') {
                rawVal = bytes[off];
            } else if (type === 'int8') {
                rawVal = bytes[off];
                if (rawVal & 0x80) rawVal -= 0x100;
            } else if (type === 'uint16_be') {
                rawVal = (bytes[off] << 8) | (bytes[off + 1] || 0);
            } else if (type === 'uint16_le') {
                rawVal = bytes[off] | ((bytes[off + 1] || 0) << 8);
            } else if (type === 'int16_be') {
                rawVal = (bytes[off] << 8) | (bytes[off + 1] || 0);
                if (rawVal & 0x8000) rawVal -= 0x10000;
            } else if (type === 'int16_le') {
                rawVal = bytes[off] | ((bytes[off + 1] || 0) << 8);
                if (rawVal & 0x8000) rawVal -= 0x10000;
            } else if (type === 'uint32_be') {
                rawVal = ((bytes[off] << 24) >>> 0) | (bytes[off + 1] << 16) | (bytes[off + 2] << 8) | (bytes[off + 3] || 0);
            } else if (type === 'uint32_le') {
                rawVal = (bytes[off]) | (bytes[off + 1] << 8) | (bytes[off + 2] << 16) | ((bytes[off + 3] || 0) << 24);
            }

            var computed = (rawVal * scale) + add;
            if (scale < 1) {
                computed = +computed.toFixed(3);
            }
            out[f.name] = computed + unit;
        }

        return out;
    };

    // -------------------------------------------------------------------------
    // Rule Matching Engine
    // -------------------------------------------------------------------------

    LoraDecoder.matchScheme = function(scheme, bytes, hex, packetInfo) {
        if (!scheme || scheme.enabled === false) return false;

        var mType = scheme.matchType || 'default';
        var mVal = scheme.matchValue ? String(scheme.matchValue).trim() : '';

        if (mType === 'prefix') {
            if (!mVal) return false;
            var cleanPrefix = mVal.toLowerCase().replace(/[^0-9a-f]/g, '');
            var cleanHex = hex.toLowerCase().replace(/[^0-9a-f]/g, '');
            return (cleanHex.indexOf(cleanPrefix) === 0);
        }

        if (mType === 'size') {
            var targetSize = parseInt(mVal, 10);
            return (bytes.length === targetSize);
        }

        if (mType === 'regex') {
            if (!mVal) return false;
            try {
                var re = new RegExp(mVal, 'i');
                return re.test(hex);
            } catch(e) {
                return false;
            }
        }

        if (mType === 'condition') {
            var condCode = scheme.matchCondition || '';
            if (!condCode) return false;
            try {
                var fn = new Function('bytes', 'hex', 'pkt', condCode);
                return !!fn(bytes, hex, packetInfo || {});
            } catch(e) {
                return false;
            }
        }

        if (mType === 'default') {
            return true;
        }

        return false;
    };

    // -------------------------------------------------------------------------
    // Decoder Execution
    // -------------------------------------------------------------------------

    LoraDecoder.executeScheme = function(scheme, bytes, hex, packetInfo) {
        var decType = scheme.type || 'js';

        try {
            if (decType === 'ascii') {
                return {
                    success: true,
                    data: { text: LoraDecoder.bytesToAscii(bytes) },
                    error: null
                };
            }

            if (decType === 'cayenne_lpp') {
                var cResult = LoraDecoder.decodeCayenneLpp(bytes);
                if (cResult) {
                    return { success: true, data: cResult, error: null };
                } else {
                    return {
                        success: false,
                        data: { raw_hex: hex },
                        error: "Not valid Cayenne LPP structure"
                    };
                }
            }

            if (decType === 'fields') {
                var fResult = LoraDecoder.decodeFields(bytes, scheme.fields || []);
                return { success: true, data: fResult, error: null };
            }

            if (decType === 'js') {
                var jsCode = scheme.jsCode || '';
                var fn = new Function('bytes', 'hex', 'pkt', jsCode);
                var res = fn(bytes, hex, packetInfo || {});
                if (typeof res !== 'object' || res === null) {
                    res = { result: res };
                }
                return { success: true, data: res, error: null };
            }
        } catch(err) {
            return {
                success: false,
                data: null,
                error: err.message || String(err)
            };
        }

        return {
            success: true,
            data: { raw_hex: hex },
            error: null
        };
    };

    // -------------------------------------------------------------------------
    // Top-Level Packet Decoder (Multi-Scheme Pipeline)
    // -------------------------------------------------------------------------

    LoraDecoder.decodePacket = function(packet, schemes) {
        if (!packet) return null;
        var hex = (packet.hex || '').trim();
        var bytes = LoraDecoder.hexToBytes(hex);
        var activeSchemes = schemes || LoraDecoder.activeSchemes || LoraDecoder.getDefaultSchemes();

        for (var i = 0; i < activeSchemes.length; i++) {
            var s = activeSchemes[i];
            if (LoraDecoder.matchScheme(s, bytes, hex, packet)) {
                var execRes = LoraDecoder.executeScheme(s, bytes, hex, packet);
                return {
                    schemeId: s.id,
                    schemeName: s.name,
                    matchType: s.matchType,
                    matchValue: s.matchValue,
                    success: execRes.success,
                    data: execRes.data,
                    error: execRes.error,
                    summary: LoraDecoder.formatSummary(execRes.data)
                };
            }
        }

        // Fallback: If payload is printable ASCII, format as ASCII; otherwise hex
        if (LoraDecoder.isAscii(bytes) && bytes.length >= 2) {
            return {
                schemeId: 'fallback_ascii',
                schemeName: 'ASCII Text',
                matchType: 'auto',
                success: true,
                data: { text: LoraDecoder.bytesToAscii(bytes) },
                summary: '"' + LoraDecoder.bytesToAscii(bytes) + '"'
            };
        }

        return {
            schemeId: 'none',
            schemeName: 'Raw Payload',
            matchType: 'none',
            success: true,
            data: { hex: hex },
            summary: hex
        };
    };

    LoraDecoder.formatSummary = function(data) {
        if (!data) return '—';
        if (typeof data !== 'object') return String(data);
        var parts = [];
        for (var k in data) {
            if (!data.hasOwnProperty(k)) continue;
            var val = data[k];
            if (typeof val === 'object' && val !== null) {
                val = JSON.stringify(val);
            }
            parts.push(k + ': ' + val);
            if (parts.length >= 5) {
                parts.push('...');
                break;
            }
        }
        return parts.length ? parts.join(', ') : '—';
    };

    // -------------------------------------------------------------------------
    // Default Schemes Built-in
    // -------------------------------------------------------------------------

    LoraDecoder.getDefaultSchemes = function() {
        return [
            {
                id: 'scheme_aa0b',
                name: 'Sensor Node AA0B (Temp / Volt / Seq)',
                description: 'Matches incoming payloads starting with AA0B header',
                enabled: true,
                matchType: 'prefix',
                matchValue: 'aa0b',
                type: 'js',
                jsCode: [
                    '// Decoder for AA0B packets (e.g. aa0b64370111084002050fac)',
                    'var header = hex.substring(0, 4).toUpperCase();',
                    'var seq = (bytes[2] << 8) | bytes[3];',
                    'var temp_raw = (bytes[4] << 8) | bytes[5];',
                    'var volt_raw = (bytes[6] << 8) | bytes[7];',
                    '',
                    'return {',
                    '    node_type: header,',
                    '    seq: seq,',
                    '    temperature: +(temp_raw / 10).toFixed(1) + " °C",',
                    '    battery: +(volt_raw / 1000).toFixed(2) + " V",',
                    '    extra: hex.substring(16)',
                    '};'
                ].join('\n')
            },
            {
                id: 'scheme_aa0c',
                name: 'Sensor Node AA0C (Telemetry / Battery)',
                description: 'Matches incoming payloads starting with AA0C header',
                enabled: true,
                matchType: 'prefix',
                matchValue: 'aa0c',
                type: 'js',
                jsCode: [
                    '// Decoder for AA0C packets (e.g. aa0c6401011107c302051067)',
                    'var header = hex.substring(0, 4).toUpperCase();',
                    'var seq = (bytes[2] << 8) | bytes[3];',
                    'var sensor_raw = (bytes[4] << 8) | bytes[5];',
                    'var volt_raw = (bytes[6] << 8) | bytes[7];',
                    '',
                    'return {',
                    '    node_type: header,',
                    '    seq: seq,',
                    '    sensor_val: sensor_raw,',
                    '    battery: +(volt_raw / 1000).toFixed(2) + " V",',
                    '    extra: hex.substring(16)',
                    '};'
                ].join('\n')
            },
            {
                id: 'scheme_ascii_ping',
                name: 'ASCII Text & Test Pings',
                description: 'Auto-decodes printable text strings (e.g. PING_FROM_LPS8)',
                enabled: true,
                matchType: 'condition',
                matchCondition: [
                    '// Match if all bytes are printable ASCII chars',
                    'if (bytes.length < 2) return false;',
                    'return bytes.every(function(b) {',
                    '    return (b >= 32 && b <= 126) || b === 10 || b === 13;',
                    '});'
                ].join('\n'),
                type: 'ascii'
            },
            {
                id: 'scheme_cayenne_lpp',
                name: 'Cayenne LPP Standard Sensors',
                description: 'Decodes standard IPSO/Cayenne LPP sensors (temp, hum, analog, GPS)',
                enabled: true,
                matchType: 'default',
                type: 'cayenne_lpp'
            }
        ];
    };

    // -------------------------------------------------------------------------
    // REST API Integration
    // -------------------------------------------------------------------------

    LoraDecoder.loadSchemes = function(apiEndpoint, callback) {
        var url = apiEndpoint || '/api/lora/decoders';
        var xhr = new XMLHttpRequest();
        xhr.open('GET', url, true);
        xhr.onreadystatechange = function() {
            if (xhr.readyState === 4) {
                if (xhr.status === 200) {
                    try {
                        var parsed = JSON.parse(xhr.responseText);
                        var list = (parsed && parsed.schemes && parsed.schemes.length) ? parsed.schemes : LoraDecoder.getDefaultSchemes();
                        LoraDecoder.activeSchemes = list;
                        if (callback) callback(null, list);
                    } catch(e) {
                        var d = LoraDecoder.getDefaultSchemes();
                        LoraDecoder.activeSchemes = d;
                        if (callback) callback(e, d);
                    }
                } else {
                    var dflt = LoraDecoder.getDefaultSchemes();
                    LoraDecoder.activeSchemes = dflt;
                    if (callback) callback(new Error('HTTP ' + xhr.status), dflt);
                }
            }
        };
        xhr.send();
    };

    LoraDecoder.saveSchemes = function(apiEndpoint, schemesList, callback) {
        var url = apiEndpoint || '/api/lora/decoders';
        var xhr = new XMLHttpRequest();
        xhr.open('POST', url, true);
        xhr.setRequestHeader('Content-Type', 'application/json');
        xhr.onreadystatechange = function() {
            if (xhr.readyState === 4) {
                if (xhr.status === 200) {
                    try {
                        var resp = JSON.parse(xhr.responseText);
                        LoraDecoder.activeSchemes = schemesList;
                        if (callback) callback(null, resp);
                    } catch(e) {
                        if (callback) callback(null, { status: 'saved' });
                    }
                } else {
                    if (callback) callback(new Error('Failed to save (HTTP ' + xhr.status + ')'));
                }
            }
        };
        var payload = JSON.stringify({
            version: 1,
            updated: new Date().toISOString(),
            schemes: schemesList
        });
        xhr.send(payload);
    };

    // Initialize activeSchemes with defaults
    LoraDecoder.activeSchemes = LoraDecoder.getDefaultSchemes();

    window.LoraDecoder = LoraDecoder;

})(window);
