/**
 * lora_decoder.js — LoRa Payload Multi-Scheme Decoding & Node ID Extraction Engine
 * Compatible with Dragino LPS8 (SX1302) & LG01/LG02 (SX1276)
 *
 * Features:
 * - Multi-Way Node ID Extraction:
 *     1. 2-Byte Node ID (Bytes 0..1, e.g. "1234", "CAFE")
 *     2. 4-Byte Serial after 2B Prefix (Bytes 2..5, e.g. "96B840EB")
 *     3. 6-Byte Header / MAC (Bytes 0..5, e.g. "CAFE96B840EB")
 *     4. Custom Byte Offset & Length (Hex, Decimal, or ASCII)
 *     5. From Decoded Output Property (e.g. `node_id`, `senderId`, `id`)
 *     6. Single Byte (Byte 0)
 * - Multi-Scheme Decoders:
 *     - Channel-Type-Value (CTV / TLV) Parser with auto-offset detection
 *     - Standard Cayenne LPP (IPSO) with header offset & full sensor suite (Temp, Hum, Analog, Accel 0x71, Baro 0x73, GPS 0x88, Digital, Lux)
 *     - Visual Byte Field Slicer (No-Code multi-byte extractor)
 *     - Custom JavaScript Functions (TTN / ChirpStack style)
 *     - Plain ASCII String Auto-Decode
 * - Persistence with /etc/lora/decoders.json via LuCI REST API
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
                str += '\n';
            } else if (b === 13) {
                str += '\r';
            } else if (b === 9) {
                str += '\t';
            } else {
                str += '.';
            }
        }
        return str;
    };

    // -------------------------------------------------------------------------
    // Node ID Extraction Engine
    // -------------------------------------------------------------------------

    LoraDecoder.getNodeIdByteRange = function(bytes, scheme, globalRule) {
        var rule = (scheme && scheme.nodeId) || globalRule || LoraDecoder.globalNodeId || { source: "node_2b" };
        var src = rule.source || "node_2b";
        if (src === "node_2b" || src === "node_id_2b" || src === "auto" || src === "header") {
            return { start: 0, end: Math.min(1, bytes.length - 1), label: "Node ID" };
        }
        if (src === "serial_4b") {
            if (bytes.length >= 6) return { start: 2, end: 5, label: "Node Serial (4B)" };
            return { start: 0, end: Math.min(3, bytes.length - 1), label: "Node Serial" };
        }
        if (src === "mac_6b") {
            return { start: 0, end: Math.min(5, bytes.length - 1), label: "Node MAC (6B)" };
        }
        if (src === "single") {
            return { start: 0, end: 0, label: "Node ID (1B)" };
        }
        if (src === "devaddr" && bytes.length >= 5) {
            return { start: 1, end: 4, label: "DevAddr (4B)" };
        }
        if (src === "offset") {
            var off = parseInt(rule.offset, 10);
            if (isNaN(off) || off < 0) off = 0;
            var len = parseInt(rule.length, 10);
            if (isNaN(len) || len < 1) len = 2;
            if (off < bytes.length) {
                return { start: off, end: Math.min(off + len - 1, bytes.length - 1), label: "Node ID" };
            }
        }
        return { start: 0, end: Math.min(1, bytes.length - 1), label: "Node ID" };
    };

    LoraDecoder.extractNodeId = function(bytes, hex, scheme, decodedData, globalRule) {
        if (!hex || hex.length === 0) {
            return { id: "UNKNOWN", method: "None" };
        }
        bytes = bytes || LoraDecoder.hexToBytes(hex);

        var rule = (scheme && scheme.nodeId) || globalRule || LoraDecoder.globalNodeId || { source: "auto" };
        var src = rule.source || "auto";
        var offset = parseInt(rule.offset, 10);
        if (isNaN(offset)) offset = 0;
        var length = parseInt(rule.length, 10);
        if (isNaN(length) || length < 1) length = 2;
        var format = rule.format || "hex";
        var pfx = rule.prefix || "";
        var fieldName = rule.fieldName || "node_id";

        // 1. From Decoded Field
        if (src === "field") {
            if (decodedData) {
                var cand = decodedData[fieldName] || decodedData.node_id || decodedData.senderId ||
                           decodedData.sender_id || decodedData.dev_id || decodedData.id ||
                           decodedData.nodeId || decodedData.address;
                if (cand !== undefined && cand !== null && String(cand).trim() !== "") {
                    var strVal = String(cand).trim().toUpperCase();
                    return { id: pfx + strVal, method: "Field '" + fieldName + "'" };
                }
            }
        }

        // 2. Preset: 4-Byte Serial at Bytes 2..5 (e.g. CA FE [96 B8 40 EB])
        if (src === "serial_4b" && bytes.length >= 6) {
            offset = 2;
            length = 4;
            src = "offset";
        }

        // 3. Preset: 6-Byte Full Header / MAC at Bytes 0..5 (e.g. [CA FE 96 B8 40 EB])
        if (src === "mac_6b" && bytes.length >= 6) {
            offset = 0;
            length = 6;
            src = "offset";
        }

        // 4. 2-Byte Node ID (Bytes 0..1 in HEX, e.g. 12 34 -> "1234", CA FE -> "CAFE")
        if (src === "node_2b" || src === "node_id_2b" || src === "auto") {
            if (bytes.length >= 2) {
                var b0 = (bytes[0] < 16 ? "0" : "") + bytes[0].toString(16).toUpperCase();
                var b1 = (bytes[1] < 16 ? "0" : "") + bytes[1].toString(16).toUpperCase();
                if (format === "decimal") {
                    var dVal = (bytes[0] * 256) + bytes[1];
                    return { id: pfx + dVal.toString(10), method: "2-Byte Node ID (Dec " + dVal + ")" };
                }
                return { id: pfx + b0 + b1, method: "2-Byte Node ID (" + b0 + b1 + ")" };
            } else if (bytes.length === 1) {
                var sHex = (bytes[0] < 16 ? "0" : "") + bytes[0].toString(16).toUpperCase();
                return { id: pfx + sHex, method: "1-Byte Node ID (" + sHex + ")" };
            }
        }

        // 5. Custom Byte Offset & Length
        if (src === "offset" && bytes.length > offset) {
            var sliceLen = Math.min(length, bytes.length - offset);
            if (format === "decimal") {
                var num = 0;
                for (var i = 0; i < sliceLen; i++) {
                    num = (num * 256) + bytes[offset + i];
                }
                return { id: pfx + num.toString(10), method: "Offset " + offset + " Len " + sliceLen + " (Dec)" };
            } else if (format === "ascii") {
                var str = "";
                for (var i = 0; i < sliceLen; i++) {
                    var b = bytes[offset + i];
                    if (b >= 32 && b <= 126) str += String.fromCharCode(b);
                }
                return { id: pfx + (str || "UNKNOWN"), method: "Offset " + offset + " Len " + sliceLen + " (ASCII)" };
            } else {
                var h = "";
                for (var i = 0; i < sliceLen; i++) {
                    var b = bytes[offset + i];
                    h += (b < 16 ? "0" : "") + b.toString(16).toUpperCase();
                }
                return { id: pfx + h, method: "Offset " + offset + ".." + (offset + sliceLen - 1) + " (Hex)" };
            }
        }

        // 6. Header / First 2 Bytes
        if (src === "header" && bytes.length >= 2) {
            var hdr = hex.substring(0, 4).toUpperCase();
            return { id: pfx + hdr, method: "Header (First 2 Bytes)" };
        }

        // 7. Single Byte (Offset 0)
        if (src === "single" && bytes.length >= 1) {
            var s = hex.substring(0, 2).toUpperCase();
            if (format === "decimal") {
                return { id: pfx + bytes[0].toString(10), method: "Byte 0 (Dec " + bytes[0] + ")" };
            }
            return { id: pfx + s, method: "Byte 0 (Hex 0x" + s + ")" };
        }

        // 8. LoRaWAN DevAddr (4 Bytes at Offset 1)
        if (src === "devaddr" && bytes.length >= 5) {
            var addrHex = hex.substring(2, 10).toUpperCase();
            return { id: pfx + addrHex, method: "LoRaWAN DevAddr (4B)" };
        }

        // 9. Fallback
        if (hex.length >= 4) {
            return { id: pfx + hex.substring(0, 4).toUpperCase(), method: "Fallback (First 2B)" };
        }
        return { id: pfx + hex.toUpperCase(), method: "Raw Payload" };
    };

    // -------------------------------------------------------------------------
    // Unified Channel Stream Detector & Parser (Supports TLV + Cayenne LPP / IPSO)
    // -------------------------------------------------------------------------

    var CHANNEL_TYPE_SPECS = {
        0x00: { size: 1, name: "Digital In", color: "#0284c7" },
        0x01: { size: 1, name: "State / Switch", color: "#ea580c" },
        0x02: { size: 2, name: "Analog In", color: "#4f46e5" },
        0x03: { size: 2, name: "Analog Out", color: "#6366f1" },
        0x05: { size: 2, name: "Battery", color: "#0891b2" },
        0x10: { size: 1, name: "Switch State", color: "#ea580c" },
        0x11: { size: 2, name: "Temperature", color: "#059669" },
        0x12: { size: 2, name: "Analog", color: "#4f46e5" },
        0x65: { size: 2, name: "Illuminance", color: "#d97706" },
        0x66: { size: 1, name: "Presence", color: "#7c3aed" },
        0x67: { size: 2, name: "Temperature", color: "#059669" },
        0x68: { size: 1, name: "Humidity", color: "#0891b2" },
        0x71: { size: 6, name: "Accelerometer", color: "#7c3aed" },
        0x73: { size: 2, name: "Barometer", color: "#6d28d9" },
        0x88: { size: 9, name: "GPS Location", color: "#0d9488" }
    };

    LoraDecoder.probeChannelStreamAt = function(bytes, startOffset) {
        if (!bytes || startOffset < 0 || startOffset >= bytes.length - 2) {
            return { valid: false, count: 0, channels: [] };
        }
        var idx = startOffset;
        var channels = [];
        while (idx < bytes.length) {
            // Allow trailing zero-padding at the end of fixed-size radio buffers
            if (bytes[idx] === 0x00 && channels.length > 0) {
                var allZero = true;
                for (var z = idx; z < bytes.length; z++) {
                    if (bytes[z] !== 0) { allZero = false; break; }
                }
                if (allZero) break;
            }
            var ch = bytes[idx];
            if (ch < 1 || ch > 32) break;
            if (idx + 1 >= bytes.length) break;
            var typeCode = bytes[idx + 1];
            var spec = CHANNEL_TYPE_SPECS[typeCode];
            if (!spec) break;
            var actualSize = spec.size;
            // Allow 0x88 GPS at the tail of a 32B buffer if truncated to 8 bytes
            if (typeCode === 0x88 && (idx + 2 + actualSize === bytes.length + 1)) {
                actualSize = 8;
            }
            if (idx + 2 + actualSize > bytes.length) break;

            channels.push({
                start: idx,
                end: idx + 1 + actualSize,
                ch: ch,
                type: typeCode,
                spec: spec
            });
            idx += 2 + actualSize;
        }
        return {
            valid: channels.length > 0,
            count: channels.length,
            offset: startOffset,
            endOffset: idx,
            channels: channels
        };
    };

    LoraDecoder.detectChannelStream = function(bytes, preferredOffset) {
        var candidates = [];
        if (preferredOffset !== undefined && preferredOffset !== null && !isNaN(parseInt(preferredOffset, 10))) {
            candidates.push(parseInt(preferredOffset, 10));
        }
        var fallbacks = [6, 4, 2, 0];
        for (var i = 0; i < fallbacks.length; i++) {
            if (candidates.indexOf(fallbacks[i]) === -1) candidates.push(fallbacks[i]);
        }

        var best = { valid: false, count: 0, offset: (candidates[0] || 0), channels: [] };
        for (var c = 0; c < candidates.length; c++) {
            var probe = LoraDecoder.probeChannelStreamAt(bytes, candidates[c]);
            if (probe.valid && probe.count > best.count) {
                best = probe;
                // If preferredOffset itself yielded at least 2 valid channels or consumed the packet, use it immediately
                if (c === 0 && (probe.count >= 2 || probe.endOffset >= bytes.length - 1)) {
                    return probe;
                }
            }
        }
        return best;
    };

    LoraDecoder.parseChannelStream = function(bytes, startOffset, includeHeaderMeta) {
        var stream = LoraDecoder.detectChannelStream(bytes, startOffset);
        var effOffset = stream.valid ? stream.offset : (startOffset !== undefined ? parseInt(startOffset, 10) : 4);
        var out = {};
        var segments = [];

        if (includeHeaderMeta && bytes.length >= 4 && effOffset === 4) {
            var b0 = (bytes[0] < 16 ? "0" : "") + bytes[0].toString(16).toUpperCase();
            var b1 = (bytes[1] < 16 ? "0" : "") + bytes[1].toString(16).toUpperCase();
            out.node_id = b0 + b1;
            var devType = bytes[2];
            out.device_type = "0x" + (devType < 16 ? "0" : "") + devType.toString(16).toUpperCase();
            var classCode = Math.floor(devType / 16);
            var capCode = devType % 16;
            out.node_class = (classCode === 1) ? "A" : ((classCode === 2) ? "B" : ((classCode === 3) ? "C" : "A"));
            var capNames = { 1: "Sensor", 2: "Actuator", 3: "Combo", 4: "Meter", 5: "Security", 6: "Dimmer" };
            out.capability = capNames[capCode] || "Sensor";
            out.seq = bytes[3];
        } else if (includeHeaderMeta && bytes.length >= 6 && effOffset === 6) {
            var h0 = (bytes[0] < 16 ? "0" : "") + bytes[0].toString(16).toUpperCase();
            var h1 = (bytes[1] < 16 ? "0" : "") + bytes[1].toString(16).toUpperCase();
            out.node_id = h0 + h1;
            var serialHex = "";
            for (var sIdx = 2; sIdx < 6; sIdx++) {
                serialHex += (bytes[sIdx] < 16 ? "0" : "") + bytes[sIdx].toString(16).toUpperCase();
            }
            out.device_serial = serialHex;
            out.node_class = "A";
            out.capability = "Sensor";
        }

        if (!stream.valid) {
            return { parsedAny: false, offset: effOffset, data: out, segments: segments };
        }

        for (var i = 0; i < stream.channels.length; i++) {
            var item = stream.channels[i];
            var ch = item.ch;
            var typeCode = item.type;
            var pfx = "ch" + ch + "_";
            var valIdx = item.start + 2;
            var segLabel = "Ch" + ch + " " + item.spec.name;
            var segDesc = "";

            if (typeCode === 0x00) {
                var dIn = bytes[valIdx];
                out[pfx + "digital_in"] = dIn;
                segLabel = "Ch" + ch + " Din: " + dIn;
                segDesc = "Channel " + ch + " Digital Input: " + dIn;
            } else if (typeCode === 0x01 || typeCode === 0x10) {
                var stVal = bytes[valIdx];
                var stStr = (stVal === 1) ? "ON" : ((stVal === 0) ? "OFF" : String(stVal));
                out[pfx + "state"] = stStr;
                out.state = stStr;
                segLabel = "Ch" + ch + " State: " + stStr;
                segDesc = "Channel " + ch + " Switch State: " + stStr;
            } else if (typeCode === 0x02 || typeCode === 0x12) {
                var aRaw = (bytes[valIdx] << 8) | bytes[valIdx + 1];
                if (aRaw & 0x8000) aRaw -= 0x10000;
                var aVal = +(aRaw * 0.01).toFixed(2);
                out[pfx + "analog_in"] = aVal;
                // If Ch 1 Analog is in typical battery range (2.00V .. 4.50V) and battery is not yet set, expose as battery voltage too
                if (ch === 1 && aVal >= 1.8 && aVal <= 5.5 && out.battery === undefined) {
                    out.battery = aVal;
                    segLabel = "Ch" + ch + " Batt/Analog: " + aVal + "V";
                } else {
                    segLabel = "Ch" + ch + " Analog: " + aVal;
                }
                segDesc = "Channel " + ch + " Analog Input: " + aVal;
            } else if (typeCode === 0x03) {
                var aoRaw = (bytes[valIdx] << 8) | bytes[valIdx + 1];
                if (aoRaw & 0x8000) aoRaw -= 0x10000;
                var aoVal = +(aoRaw * 0.01).toFixed(2);
                out[pfx + "analog_out"] = aoVal;
                segLabel = "Ch" + ch + " AOut: " + aoVal;
                segDesc = "Channel " + ch + " Analog Output: " + aoVal;
            } else if (typeCode === 0x05) {
                var mv = (bytes[valIdx] << 8) | bytes[valIdx + 1];
                var v = +(mv / 1000).toFixed(2);
                out.battery = v;
                out.battery_mv = mv;
                segLabel = "Ch" + ch + " Batt: " + v + "V";
                segDesc = "Channel " + ch + " Battery: " + v + " V (" + mv + " mV)";
            } else if (typeCode === 0x11) {
                var tRaw = (bytes[valIdx] << 8) | bytes[valIdx + 1];
                if (tRaw & 0x8000) tRaw -= 0x10000;
                var temp11 = (Math.abs(tRaw) > 500) ? +(tRaw * 0.01).toFixed(2) : +(tRaw * 0.1).toFixed(1);
                out.temperature = temp11;
                out[pfx + "val"] = tRaw;
                segLabel = "Ch" + ch + " Temp: " + temp11 + "°C";
                segDesc = "Channel " + ch + " Temperature: " + temp11 + " °C";
            } else if (typeCode === 0x65) {
                var lux = (bytes[valIdx] << 8) | bytes[valIdx + 1];
                out.illuminance = lux;
                out[pfx + "illuminance"] = lux;
                segLabel = "Ch" + ch + " Lux: " + lux + " lx";
                segDesc = "Channel " + ch + " Illuminance: " + lux + " lux";
            } else if (typeCode === 0x66) {
                var pres = bytes[valIdx];
                out.presence = pres;
                out[pfx + "presence"] = pres;
                segLabel = "Ch" + ch + " Presence: " + pres;
                segDesc = "Channel " + ch + " Presence: " + pres;
            } else if (typeCode === 0x67) {
                var cTemp = (bytes[valIdx] << 8) | bytes[valIdx + 1];
                if (cTemp & 0x8000) cTemp -= 0x10000;
                var temp67 = +(cTemp * 0.1).toFixed(1);
                out.temperature = temp67;
                out[pfx + "temperature"] = temp67;
                segLabel = "Ch" + ch + " Temp: " + temp67 + "°C";
                segDesc = "Channel " + ch + " Temperature (0x67): " + temp67 + " °C";
            } else if (typeCode === 0x68) {
                var hum = +(bytes[valIdx] * 0.5).toFixed(1);
                out.humidity = hum;
                out[pfx + "humidity"] = hum;
                segLabel = "Ch" + ch + " Hum: " + hum + "%";
                segDesc = "Channel " + ch + " Humidity (0x68): " + hum + " %";
            } else if (typeCode === 0x71) {
                var ax = (bytes[valIdx] << 8) | bytes[valIdx + 1];
                var ay = (bytes[valIdx + 2] << 8) | bytes[valIdx + 3];
                var az = (bytes[valIdx + 4] << 8) | bytes[valIdx + 5];
                if (ax & 0x8000) ax -= 0x10000;
                if (ay & 0x8000) ay -= 0x10000;
                if (az & 0x8000) az -= 0x10000;
                out.accel_x = +(ax * 0.001).toFixed(3);
                out.accel_y = +(ay * 0.001).toFixed(3);
                out.accel_z = +(az * 0.001).toFixed(3);
                segLabel = "Ch" + ch + " Accel (" + out.accel_z + "g)";
                segDesc = "Channel " + ch + " Accelerometer X:" + out.accel_x + "g Y:" + out.accel_y + "g Z:" + out.accel_z + "g";
            } else if (typeCode === 0x73) {
                var baro = +(((bytes[valIdx] << 8) | bytes[valIdx + 1]) * 0.1).toFixed(1);
                out.pressure = baro;
                out[pfx + "barometer"] = baro;
                segLabel = "Ch" + ch + " Baro: " + baro + " hPa";
                segDesc = "Channel " + ch + " Barometer: " + baro + " hPa";
            } else if (typeCode === 0x88) {
                var latRaw = (bytes[valIdx] << 16) | (bytes[valIdx + 1] << 8) | (bytes[valIdx + 2] || 0);
                if (latRaw & 0x800000) latRaw -= 0x1000000;
                var lonRaw = (bytes[valIdx + 3] << 16) | (bytes[valIdx + 4] << 8) | (bytes[valIdx + 5] || 0);
                if (lonRaw & 0x800000) lonRaw -= 0x1000000;
                var altRaw = ((bytes[valIdx + 6] || 0) << 16) | ((bytes[valIdx + 7] || 0) << 8) | (bytes[valIdx + 8] || 0);
                if (altRaw & 0x800000) altRaw -= 0x1000000;
                out.latitude = +(latRaw * 0.0001).toFixed(4);
                out.longitude = +(lonRaw * 0.0001).toFixed(4);
                out.altitude = +(altRaw * 0.01).toFixed(2);
                segLabel = "Ch" + ch + " GPS (" + out.latitude + "," + out.longitude + ")";
                segDesc = "Channel " + ch + " GPS Lat:" + out.latitude + " Lon:" + out.longitude + " Alt:" + out.altitude + "m";
            }

            segments.push({
                start: item.start,
                end: item.end,
                name: segLabel,
                desc: segDesc,
                color: item.spec.color,
                textColor: "#ffffff"
            });
        }

        return {
            parsedAny: stream.channels.length > 0,
            offset: effOffset,
            data: out,
            segments: segments
        };
    };

    // -------------------------------------------------------------------------
    // Channel-Type-Value (CTV / TLV) Decoder Engine
    // -------------------------------------------------------------------------

    LoraDecoder.decodeCtv = function(bytes, hex, dataOffset) {
        var parsed = LoraDecoder.parseChannelStream(bytes, dataOffset, true);
        return parsed.data;
    };

    // -------------------------------------------------------------------------
    // Standard Cayenne LPP (IPSO) Decoder
    // -------------------------------------------------------------------------

    LoraDecoder.decodeCayenneLpp = function(bytes, dataOffset) {
        var pref = (dataOffset !== undefined && dataOffset !== null) ? parseInt(dataOffset, 10) : 0;
        var parsed = LoraDecoder.parseChannelStream(bytes, pref, pref >= 4);
        return parsed.parsedAny ? parsed.data : null;
    };

    // -------------------------------------------------------------------------
    // Visual Byte Segmentation & Inspector Engine (Scheme-Aware)
    // -------------------------------------------------------------------------

    var FIELD_SLICE_COLORS = [
        "#059669", // Emerald
        "#0891b2", // Cyan
        "#7c3aed", // Purple
        "#ea580c", // Orange
        "#4f46e5", // Indigo
        "#d97706", // Amber
        "#be185d", // Pink
        "#0d9488"  // Teal
    ];

    LoraDecoder.segmentBytes = function(bytes, hex, result) {
        if (typeof bytes === "string") {
            result = hex;
            hex = bytes;
            bytes = LoraDecoder.hexToBytes(hex);
        } else if (!bytes || !bytes.length) {
            bytes = LoraDecoder.hexToBytes(hex || '');
        }
        if (!bytes || !bytes.length) return [];

        var segments = [];
        var scheme = (result && result.scheme) || null;
        var schemeId = (result && (result.schemeId || (scheme && scheme.id))) || "";
        var data = (result && (result.data || result)) || {};

        if (!scheme && schemeId && LoraDecoder.activeSchemes) {
            for (var sIdx = 0; sIdx < LoraDecoder.activeSchemes.length; sIdx++) {
                if (LoraDecoder.activeSchemes[sIdx].id === schemeId) {
                    scheme = LoraDecoder.activeSchemes[sIdx];
                    break;
                }
            }
        }

        var decType = (scheme && scheme.type) ? scheme.type : (schemeId === "fallback_ascii" ? "ascii" : "ctv");

        // 1. ASCII Mode
        if (decType === "ascii") {
            segments.push({
                start: 0,
                end: bytes.length - 1,
                name: 'ASCII: "' + LoraDecoder.bytesToAscii(bytes) + '"',
                desc: "Printable ASCII Text (" + bytes.length + " Bytes)",
                color: "#d97706",
                textColor: "#ffffff"
            });
            return segments;
        }

        // 2. Determine Node ID Byte Segment from Scheme
        var nodeRange = LoraDecoder.getNodeIdByteRange(bytes, scheme, LoraDecoder.globalNodeId);
        if (nodeRange && nodeRange.start < bytes.length && (!scheme || !scheme.nodeId || scheme.nodeId.source !== "field")) {
            var nHex = "";
            for (var nb = nodeRange.start; nb <= nodeRange.end && nb < bytes.length; nb++) {
                nHex += (bytes[nb] < 16 ? "0" : "") + bytes[nb].toString(16).toUpperCase();
            }
            segments.push({
                start: nodeRange.start,
                end: nodeRange.end,
                name: nodeRange.label + " (" + nHex + ")",
                desc: nodeRange.label + ": " + nHex,
                color: "#2563eb", // Blue
                textColor: "#ffffff"
            });
        }

        // 3. Field Slicer Mode: Segment every configured byte slice!
        if (decType === "fields" && scheme && scheme.fields && scheme.fields.length > 0) {
            for (var fIdx = 0; fIdx < scheme.fields.length; fIdx++) {
                var f = scheme.fields[fIdx];
                if (!f || !f.name) continue;
                var fOff = parseInt(f.offset, 10);
                if (isNaN(fOff) || fOff < 0 || fOff >= bytes.length) continue;
                var fLen = LoraDecoder.getFieldTypeByteLength(f.type, f.length);
                var fEnd = Math.min(fOff + fLen - 1, bytes.length - 1);
                var fVal = (data && data[f.name] !== undefined) ? (": " + data[f.name]) : "";
                var col = FIELD_SLICE_COLORS[fIdx % FIELD_SLICE_COLORS.length];

                // Remove any overlapping default Node ID segment if user explicitly sliced byte 0
                for (var rem = segments.length - 1; rem >= 0; rem--) {
                    if (!(fEnd < segments[rem].start || fOff > segments[rem].end)) {
                        segments.splice(rem, 1);
                    }
                }

                segments.push({
                    start: fOff,
                    end: fEnd,
                    name: f.name + fVal,
                    desc: "Field '" + f.name + "' (" + (f.type || "uint8") + " at offset " + fOff + ")" + fVal,
                    color: col,
                    textColor: "#ffffff"
                });
            }
        } else if (decType === "ctv" || decType === "tlv" || decType === "cayenne_lpp" || decType === "js") {
            // 4. Channel Stream Segmentation (TLV / Cayenne LPP)
            var prefOffset = (scheme && scheme.dataOffset !== undefined) ? parseInt(scheme.dataOffset, 10) : (decType === "cayenne_lpp" ? 0 : 4);
            var streamParsed = LoraDecoder.parseChannelStream(bytes, prefOffset, true);

            if (streamParsed.parsedAny) {
                var chStart = streamParsed.offset;
                if (chStart === 4 && bytes.length >= 4 && nodeRange.end < 2) {
                    var cls = data.node_class ? ("Class " + data.node_class) : "";
                    var cap = data.capability || "";
                    var typeLabel = (cls || cap) ? (cls + " " + cap).trim() : "Device Type";
                    segments.push({
                        start: 2,
                        end: 2,
                        name: typeLabel,
                        desc: typeLabel + " (0x" + (bytes[2] < 16 ? "0" : "") + bytes[2].toString(16).toUpperCase() + ")",
                        color: "#7c3aed",
                        textColor: "#ffffff"
                    });
                    segments.push({
                        start: 3,
                        end: 3,
                        name: "Seq #" + bytes[3],
                        desc: "Sequence Counter #" + bytes[3],
                        color: "#d97706",
                        textColor: "#ffffff"
                    });
                } else if (chStart === 6 && bytes.length >= 6 && nodeRange.end < 2) {
                    var serHex = "";
                    for (var s = 2; s < 6; s++) {
                        serHex += (bytes[s] < 16 ? "0" : "") + bytes[s].toString(16).toUpperCase();
                    }
                    segments.push({
                        start: 2,
                        end: 5,
                        name: "Serial (" + serHex + ")",
                        desc: "4-Byte Device Serial / Address: " + serHex,
                        color: "#7c3aed",
                        textColor: "#ffffff"
                    });
                }

                for (var cIdx = 0; cIdx < streamParsed.segments.length; cIdx++) {
                    var chSeg = streamParsed.segments[cIdx];
                    // Avoid colliding with Node ID segment if Cayenne LPP starts at 0
                    if (chSeg.start <= nodeRange.end && chStart === 0) {
                        segments = [];
                    }
                    segments.push(chSeg);
                }
            } else if (bytes.length >= 4 && nodeRange.end < 2 && decType === "ctv") {
                segments.push({
                    start: 2,
                    end: 2,
                    name: "Header[2]",
                    desc: "Byte 2 (0x" + (bytes[2] < 16 ? "0" : "") + bytes[2].toString(16).toUpperCase() + ")",
                    color: "#7c3aed",
                    textColor: "#ffffff"
                });
                segments.push({
                    start: 3,
                    end: 3,
                    name: "Header[3]",
                    desc: "Byte 3 (0x" + (bytes[3] < 16 ? "0" : "") + bytes[3].toString(16).toUpperCase() + ")",
                    color: "#d97706",
                    textColor: "#ffffff"
                });
            }
        }

        // Fill any unsegmented bytes
        var covered = {};
        segments.forEach(function(s) {
            for (var j = s.start; j <= s.end; j++) covered[j] = true;
        });

        var uncovStart = null;
        for (var i = 0; i <= bytes.length; i++) {
            if (i < bytes.length && !covered[i]) {
                if (uncovStart === null) uncovStart = i;
            } else {
                if (uncovStart !== null) {
                    // Check if uncovStart..i-1 is all 0x00 padding at end
                    var isZeroPad = (i === bytes.length);
                    for (var zIdx = uncovStart; zIdx < i; zIdx++) {
                        if (bytes[zIdx] !== 0) { isZeroPad = false; break; }
                    }
                    segments.push({
                        start: uncovStart,
                        end: i - 1,
                        name: isZeroPad ? "Zero Pad" : "Payload",
                        desc: (i - uncovStart) + " Bytes" + (isZeroPad ? " (Trailing Zero Padding)" : ""),
                        color: isZeroPad ? "#cbd5e1" : "#64748b",
                        textColor: isZeroPad ? "#334155" : "#ffffff"
                    });
                    uncovStart = null;
                }
            }
        }

        segments.sort(function(a, b) { return a.start - b.start; });
        return segments;
    };

    // -------------------------------------------------------------------------
    // Visual Field Slicer & Auto-Slicer Generator
    // -------------------------------------------------------------------------

    LoraDecoder.getFieldTypeByteLength = function(type, customLen) {
        if (type === 'uint8' || type === 'int8' || type === 'bool') return 1;
        if (type === 'uint16_be' || type === 'int16_be' || type === 'uint16_le' || type === 'int16_le') return 2;
        if (type === 'int24_be' || type === 'uint24_be') return 3;
        if (type === 'uint32_be' || type === 'int32_be' || type === 'uint32_le' || type === 'int32_le') return 4;
        var parsed = parseInt(customLen, 10);
        return (!isNaN(parsed) && parsed >= 1) ? parsed : 2;
    };

    LoraDecoder.autoGenerateFieldsFromBytes = function(bytes) {
        if (!bytes || !bytes.length) return [];
        var fields = [];
        var stream = LoraDecoder.detectChannelStream(bytes, 4);
        if (stream.valid && stream.channels.length > 0) {
            if (stream.offset === 6 && bytes.length >= 6) {
                fields.push({ name: "device_serial", offset: 2, length: 4, type: "hex", scale: 1, unit: "" });
            } else if (stream.offset === 4 && bytes.length >= 4) {
                fields.push({ name: "seq", offset: 3, length: 1, type: "uint8", scale: 1, unit: "" });
            }
            for (var i = 0; i < stream.channels.length; i++) {
                var ch = stream.channels[i];
                var vOff = ch.start + 2;
                if (ch.type === 0x02 || ch.type === 0x12) {
                    fields.push({ name: (ch.ch === 1 ? "battery" : ("ch" + ch.ch + "_analog")), offset: vOff, length: 2, type: "int16_be", scale: 0.01, unit: (ch.ch === 1 ? "V" : "") });
                } else if (ch.type === 0x05) {
                    fields.push({ name: "battery", offset: vOff, length: 2, type: "uint16_be", scale: 0.001, unit: "V" });
                } else if (ch.type === 0x11 || ch.type === 0x67) {
                    fields.push({ name: "temperature", offset: vOff, length: 2, type: "int16_be", scale: (ch.type === 0x67 ? 0.1 : 0.01), unit: "°C" });
                } else if (ch.type === 0x68) {
                    fields.push({ name: "humidity", offset: vOff, length: 1, type: "uint8", scale: 0.5, unit: "%" });
                } else if (ch.type === 0x01 || ch.type === 0x10) {
                    fields.push({ name: "state", offset: vOff, length: 1, type: "uint8", scale: 1, unit: "" });
                } else if (ch.type === 0x71) {
                    fields.push({ name: "accel_x", offset: vOff, length: 2, type: "int16_be", scale: 0.001, unit: "g" });
                    fields.push({ name: "accel_y", offset: vOff + 2, length: 2, type: "int16_be", scale: 0.001, unit: "g" });
                    fields.push({ name: "accel_z", offset: vOff + 4, length: 2, type: "int16_be", scale: 0.001, unit: "g" });
                } else if (ch.type === 0x73) {
                    fields.push({ name: "pressure", offset: vOff, length: 2, type: "uint16_be", scale: 0.1, unit: "hPa" });
                } else if (ch.type === 0x88) {
                    fields.push({ name: "latitude", offset: vOff, length: 3, type: "int24_be", scale: 0.0001, unit: "°" });
                    fields.push({ name: "longitude", offset: vOff + 3, length: 3, type: "int24_be", scale: 0.0001, unit: "°" });
                    fields.push({ name: "altitude", offset: vOff + 6, length: 3, type: "int24_be", scale: 0.01, unit: "m" });
                }
            }
            return fields;
        }

        // Generic fallback slices for arbitrary packets
        if (bytes.length >= 4) {
            fields.push({ name: "field_1", offset: 2, length: 2, type: "uint16_be", scale: 1, unit: "" });
        }
        if (bytes.length >= 6) {
            fields.push({ name: "field_2", offset: 4, length: 2, type: "int16_be", scale: 0.1, unit: "" });
        }
        return fields;
    };

    LoraDecoder.decodeFields = function(bytes, fields) {
        var out = {};
        if (!fields || !fields.length) return out;

        for (var i = 0; i < fields.length; i++) {
            var f = fields[i];
            if (!f || !f.name) continue;
            var off = parseInt(f.offset, 10);
            if (isNaN(off) || off < 0 || off >= bytes.length) continue;

            var type = f.type || 'uint8';
            var len = LoraDecoder.getFieldTypeByteLength(type, f.length);
            var scale = parseFloat(f.scale);
            if (isNaN(scale)) scale = 1.0;
            var add = parseFloat(f.add) || 0.0;

            if (type === 'hex') {
                var h = '';
                for (var j = 0; j < len && (off + j) < bytes.length; j++) {
                    var b = (bytes[off + j] & 0xFF).toString(16);
                    h += (b.length < 2 ? '0' : '') + b;
                }
                out[f.name] = h.toUpperCase();
                continue;
            }

            if (type === 'ascii') {
                var s = '';
                for (var j = 0; j < len && (off + j) < bytes.length; j++) {
                    var chCode = bytes[off + j];
                    if (chCode >= 32 && chCode <= 126) s += String.fromCharCode(chCode);
                }
                out[f.name] = s;
                continue;
            }

            if (type === 'bool') {
                out[f.name] = (bytes[off] !== 0) ? "ON" : "OFF";
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
            } else if (type === 'uint24_be') {
                rawVal = (bytes[off] << 16) | ((bytes[off + 1] || 0) << 8) | (bytes[off + 2] || 0);
            } else if (type === 'int24_be') {
                rawVal = (bytes[off] << 16) | ((bytes[off + 1] || 0) << 8) | (bytes[off + 2] || 0);
                if (rawVal & 0x800000) rawVal -= 0x1000000;
            } else if (type === 'uint32_be') {
                rawVal = ((bytes[off] << 24) >>> 0) + ((bytes[off + 1] || 0) << 16) + ((bytes[off + 2] || 0) << 8) + (bytes[off + 3] || 0);
            } else if (type === 'int32_be') {
                rawVal = (bytes[off] << 24) | ((bytes[off + 1] || 0) << 16) | ((bytes[off + 2] || 0) << 8) | (bytes[off + 3] || 0);
            } else if (type === 'uint32_le') {
                rawVal = (bytes[off]) + ((bytes[off + 1] || 0) << 8) + ((bytes[off + 2] || 0) << 16) + (((bytes[off + 3] || 0) << 24) >>> 0);
            }

            var computed = (rawVal * scale) + add;
            if (scale < 1) {
                var decPlaces = (scale <= 0.0001) ? 4 : ((scale <= 0.001) ? 3 : ((scale <= 0.01) ? 2 : 1));
                computed = +computed.toFixed(decPlaces);
            } else {
                computed = +computed.toFixed(2);
            }
            out[f.name] = computed;
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
        var decType = scheme.type || (scheme.jsCode ? 'js' : 'ctv');

        try {
            if (decType === 'fields') {
                var fList = (scheme.fields && scheme.fields.length) ? scheme.fields : LoraDecoder.autoGenerateFieldsFromBytes(bytes);
                var fResult = LoraDecoder.decodeFields(bytes, fList);
                return { success: true, data: fResult, error: null };
            }

            if (decType === 'cayenne_lpp') {
                var cOffset = (scheme.dataOffset !== undefined) ? scheme.dataOffset : 0;
                var cResult = LoraDecoder.decodeCayenneLpp(bytes, cOffset);
                if (cResult && Object.keys(cResult).length > 0) {
                    return { success: true, data: cResult, error: null };
                } else {
                    return {
                        success: false,
                        data: { raw_hex: hex },
                        error: "No valid Cayenne LPP / IPSO channels found at offset " + cOffset
                    };
                }
            }

            if (decType === 'ascii') {
                return {
                    success: true,
                    data: { text: LoraDecoder.bytesToAscii(bytes) },
                    error: null
                };
            }

            if (decType === 'js') {
                var jsCode = scheme.jsCode || '';
                if (jsCode.trim()) {
                    var fn = new Function('bytes', 'hex', 'pkt', jsCode);
                    var res = fn(bytes, hex, packetInfo || {});
                    if (typeof res !== 'object' || res === null) {
                        res = { result: res };
                    }
                    return { success: true, data: res, error: null };
                }
            }

            if (decType === 'ctv' || decType === 'tlv') {
                var ctvRes = LoraDecoder.decodeCtv(bytes, hex, scheme.dataOffset !== undefined ? scheme.dataOffset : 4);
                if (ctvRes && Object.keys(ctvRes).length > 0) {
                    return { success: true, data: ctvRes, error: null };
                }
            }
        } catch(err) {
            return {
                success: false,
                data: null,
                error: err.message || String(err)
            };
        }

        // Intelligent Fallback: if packet has at least 4 bytes, decode via CTV/LPP auto-detect
        if (bytes && bytes.length >= 4) {
            var autoCtv = LoraDecoder.decodeCtv(bytes, hex, 4);
            if (autoCtv && Object.keys(autoCtv).length > 0) {
                return {
                    success: true,
                    data: autoCtv,
                    error: null
                };
            }
        }

        return {
            success: true,
            data: { raw_hex: hex },
            error: null
        };
    };

    // -------------------------------------------------------------------------
    // Top-Level Packet Decoder (Multi-Scheme Pipeline & Node ID Detection)
    // -------------------------------------------------------------------------

    LoraDecoder.decodePacket = function(packet, schemes) {
        if (!packet) return null;
        var hex = (typeof packet === "string" ? packet : (packet.hex || packet.payload_hex || '')).trim();
        var bytes = LoraDecoder.hexToBytes(hex);
        var activeSchemes = schemes || LoraDecoder.activeSchemes || LoraDecoder.getDefaultSchemes();

        for (var i = 0; i < activeSchemes.length; i++) {
            var s = activeSchemes[i];
            if (LoraDecoder.matchScheme(s, bytes, hex, packet)) {
                var execRes = LoraDecoder.executeScheme(s, bytes, hex, packet);
                var nodeRes = LoraDecoder.extractNodeId(bytes, hex, s, execRes.data, LoraDecoder.globalNodeId);
                return {
                    schemeId: s.id,
                    schemeName: s.name,
                    scheme: s,
                    matchType: s.matchType,
                    matchValue: s.matchValue,
                    success: execRes.success,
                    data: execRes.data,
                    error: execRes.error,
                    nodeId: nodeRes.id,
                    nodeIdMethod: nodeRes.method,
                    summary: LoraDecoder.formatSummary(execRes.data)
                };
            }
        }

        // Fallback: If payload is printable ASCII, format as ASCII; otherwise hex
        var fallbackNode = LoraDecoder.extractNodeId(bytes, hex, null, null, LoraDecoder.globalNodeId);
        if (LoraDecoder.isAscii(bytes) && bytes.length >= 2) {
            return {
                schemeId: 'fallback_ascii',
                schemeName: 'ASCII Text',
                matchType: 'auto',
                success: true,
                data: { text: LoraDecoder.bytesToAscii(bytes) },
                nodeId: fallbackNode.id,
                nodeIdMethod: fallbackNode.method,
                summary: '"' + LoraDecoder.bytesToAscii(bytes) + '"'
            };
        }

        return {
            schemeId: 'none',
            schemeName: 'Raw Payload',
            matchType: 'none',
            success: true,
            data: { hex: hex },
            nodeId: fallbackNode.id,
            nodeIdMethod: fallbackNode.method,
            summary: hex
        };
    };

    LoraDecoder.formatSummary = function(data) {
        if (!data) return '—';
        if (typeof data !== 'object') return String(data);
        var parts = [];
        for (var k in data) {
            if (!data.hasOwnProperty(k)) continue;
            if (['node_id', 'device_type', 'node_class', 'capability', 'raw_hex'].indexOf(k) !== -1) continue;
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
    // Node Decoder Association Checker
    // -------------------------------------------------------------------------

    LoraDecoder.hasDefinedDecoder = function(packet, dec) {
        if (!packet) return false;
        var hex = (typeof packet === "string" ? packet : (packet.hex || packet.payload_hex || '')).trim().toLowerCase().replace(/[^0-9a-f]/g, '');
        var directNodeId = (typeof packet === "object" ? (packet.nodeId || packet.node_id || packet.node || '') : '').trim().toUpperCase();
        if ((!hex || hex.length < 2) && (!directNodeId || directNodeId.length < 2)) return false;

        var schemes = LoraDecoder.activeSchemes || [];
        if (!schemes || !schemes.length) return false;

        var bytes = (packet && packet.bytes) ? packet.bytes : LoraDecoder.hexToBytes(hex);
        var packetInfo = (typeof packet === "object" && packet.size) ? packet : { hex: hex, size: bytes.length };

        if (!dec && LoraDecoder.decodePacket && hex && hex.length >= 2) {
            dec = LoraDecoder.decodePacket(packetInfo, schemes);
        }

        var nodeId = directNodeId || ((dec && dec.nodeId && dec.nodeId !== "UNKNOWN") ? String(dec.nodeId).trim().toUpperCase() : "");
        if (!nodeId && hex.length >= 4) {
            nodeId = hex.substring(0, 4).toUpperCase();
        }

        var hexPfx4 = hex.length >= 4 ? hex.substring(0, 4).toLowerCase() : hex.toLowerCase();

        for (var i = 0; i < schemes.length; i++) {
            var s = schemes[i];
            if (!s || s.enabled === false) continue;

            var isBuiltinGeneric = (s.id === "scheme_2b_node_tlv" || s.id === "scheme_cayenne_lpp" || s.id === "scheme_ascii_ping");

            // A. Prefix match (e.g. s.matchValue = "cafe", "1234")
            if (s.matchType === "prefix" && s.matchValue) {
                var pfx = String(s.matchValue).trim().toLowerCase().replace(/[^0-9a-f]/g, '');
                if (pfx && (hex.indexOf(pfx) === 0 || (nodeId && nodeId.toLowerCase().indexOf(pfx) === 0))) {
                    return true;
                }
            }

            // B. Custom scheme that specifically matches this packet / node
            if (!isBuiltinGeneric) {
                if (dec && dec.schemeId === s.id && dec.success) {
                    return true;
                }
                if (LoraDecoder.matchScheme(s, bytes, hex, packetInfo)) {
                    return true;
                }
                if (nodeId && (
                    (s.name && s.name.toUpperCase().indexOf(nodeId) !== -1) ||
                    (s.id && s.id.toUpperCase().indexOf(nodeId) !== -1)
                )) {
                    return true;
                }
                if (s.sampleHex) {
                    var sClean = String(s.sampleHex).trim().toLowerCase().replace(/[^0-9a-f]/g, '');
                    if (sClean.indexOf(hexPfx4) === 0 || (nodeId && sClean.indexOf(nodeId.toLowerCase()) === 0)) {
                        return true;
                    }
                }
            }
        }

        // C. Direct Node ID match to custom scheme
        if (nodeId) {
            var nidUpper = nodeId.toUpperCase();
            for (var k = 0; k < schemes.length; k++) {
                var sc = schemes[k];
                if (!sc || sc.enabled === false) continue;
                var isBg = (sc.id === "scheme_2b_node_tlv" || sc.id === "scheme_cayenne_lpp" || sc.id === "scheme_ascii_ping");
                if (!isBg) {
                    var scVal = String(sc.matchValue || "").trim().toUpperCase();
                    var scName = String(sc.name || "").toUpperCase();
                    var scId = String(sc.id || "").toUpperCase();
                    if (scVal === nidUpper || scName.indexOf(nidUpper) !== -1 || scId.indexOf(nidUpper) !== -1) {
                        return true;
                    }
                }
            }
        }

        return false;
    };

    // -------------------------------------------------------------------------
    // Default Schemes Built-in
    // -------------------------------------------------------------------------

    LoraDecoder.getDefaultSchemes = function() {
        return [
            {
                id: 'scheme_node_cafe',
                name: 'Node CAFE (Multi-Sensor LPP)',
                description: 'Created directly from packet payload cafe96b840eb0102... (32B)',
                enabled: true,
                matchType: 'prefix',
                matchValue: 'cafe',
                nodeId: {
                    source: 'node_2b',
                    offset: 0,
                    length: 2,
                    format: 'hex',
                    prefix: ''
                },
                type: 'cayenne_lpp',
                dataOffset: 6,
                sampleHex: 'cafe96b840eb010201490271fffb000c0425036700bb04880000000000000000',
                fields: [
                    { name: 'device_serial', offset: 2, length: 4, type: 'hex', scale: 1, unit: '' },
                    { name: 'battery', offset: 8, length: 2, type: 'int16_be', scale: 0.01, unit: 'V' },
                    { name: 'accel_x', offset: 12, length: 2, type: 'int16_be', scale: 0.001, unit: 'g' },
                    { name: 'accel_y', offset: 14, length: 2, type: 'int16_be', scale: 0.001, unit: 'g' },
                    { name: 'accel_z', offset: 16, length: 2, type: 'int16_be', scale: 0.001, unit: 'g' },
                    { name: 'temperature', offset: 20, length: 2, type: 'int16_be', scale: 0.1, unit: '°C' }
                ]
            },
            {
                id: 'scheme_2b_node_tlv',
                name: 'Standard 2-Byte Node ID + TLV / IPSO Channels',
                description: 'Decodes 2-Byte Node ID (0..1) + Header + dynamic TLV / Cayenne LPP sensor channels (Temp, Batt, Hum, Accel, GPS, Switch)',
                enabled: true,
                matchType: 'condition',
                matchCondition: '// Match standard 4+ byte header\nreturn bytes.length >= 4;',
                nodeId: {
                    source: 'node_2b',
                    offset: 0,
                    length: 2,
                    format: 'hex',
                    prefix: ''
                },
                type: 'ctv',
                dataOffset: 4
            },
            {
                id: 'scheme_cayenne_lpp',
                name: 'Cayenne LPP Standard Sensors',
                description: 'Decodes standard IPSO/Cayenne LPP sensors (temp, hum, analog, accel, GPS)',
                enabled: true,
                matchType: 'condition',
                matchCondition: '// Match Cayenne LPP channels\nreturn bytes.length >= 3 && (bytes[1] === 0x67 || bytes[1] === 0x68 || bytes[1] === 0x02 || bytes[1] === 0x01 || bytes[1] === 0x71 || bytes[1] === 0x88);',
                nodeId: {
                    source: 'node_2b',
                    offset: 0,
                    length: 2,
                    format: 'hex',
                    prefix: ''
                },
                type: 'cayenne_lpp',
                dataOffset: 0
            },
            {
                id: 'scheme_ascii_ping',
                name: 'ASCII Text & Test Pings',
                description: 'Auto-decodes printable text strings (e.g. PING_FROM_LPS8)',
                enabled: true,
                matchType: 'condition',
                nodeId: {
                    source: 'node_2b',
                    offset: 0,
                    length: 2,
                    format: 'hex',
                    prefix: ''
                },
                matchCondition: [
                    '// Match if all bytes are printable ASCII chars',
                    'if (bytes.length < 2) return false;',
                    'return bytes.every(function(b) {',
                    '    return (b >= 32 && b <= 126) || b === 10 || b === 13;',
                    '});'
                ].join('\n'),
                type: 'ascii'
            }
        ];
    };

    // -------------------------------------------------------------------------
    // REST API Integration
    // -------------------------------------------------------------------------

    LoraDecoder.globalNodeId = {
        source: 'node_2b',
        offset: 0,
        length: 2,
        format: 'hex',
        prefix: ''
    };

    LoraDecoder.loadSchemes = function(apiEndpoint, callback) {
        var url = apiEndpoint || '/cgi-bin/luci/admin/lora/api_decoders';
        var xhr = new XMLHttpRequest();
        xhr.open('GET', url, true);
        xhr.onreadystatechange = function() {
            if (xhr.readyState === 4) {
                if (xhr.status === 200) {
                    try {
                        var parsed = JSON.parse(xhr.responseText);
                        var list = (parsed && parsed.schemes && parsed.schemes.length) ? parsed.schemes : LoraDecoder.getDefaultSchemes();
                        LoraDecoder.activeSchemes = list;
                        try { localStorage.setItem('lora_cached_schemes', JSON.stringify(list)); } catch(ce) {}
                        if (parsed && parsed.globalNodeId) {
                            LoraDecoder.globalNodeId = parsed.globalNodeId;
                            try { localStorage.setItem('lora_cached_global_node', JSON.stringify(parsed.globalNodeId)); } catch(ge) {}
                        }
                        if (callback) callback(null, list, LoraDecoder.globalNodeId);
                    } catch(e) {
                        var d = LoraDecoder.getDefaultSchemes();
                        LoraDecoder.activeSchemes = d;
                        if (callback) callback(e, d, LoraDecoder.globalNodeId);
                    }
                } else {
                    var dflt = LoraDecoder.getDefaultSchemes();
                    LoraDecoder.activeSchemes = dflt;
                    if (callback) callback(new Error('HTTP ' + xhr.status), dflt, LoraDecoder.globalNodeId);
                }
            }
        };
        xhr.send();
    };

    LoraDecoder.saveSchemes = function(apiEndpoint, schemesList, globalNodeId, callback) {
        if (typeof globalNodeId === 'function') {
            callback = globalNodeId;
            globalNodeId = LoraDecoder.globalNodeId;
        }
        var url = apiEndpoint || '/cgi-bin/luci/admin/lora/api_decoders';
        var xhr = new XMLHttpRequest();
        xhr.open('POST', url, true);
        xhr.setRequestHeader('Content-Type', 'application/json');
        xhr.onreadystatechange = function() {
            if (xhr.readyState === 4) {
                if (xhr.status === 200) {
                    try {
                        var resp = JSON.parse(xhr.responseText);
                        LoraDecoder.activeSchemes = schemesList;
                        LoraDecoder.globalNodeId = globalNodeId || LoraDecoder.globalNodeId;
                        try { localStorage.setItem('lora_cached_schemes', JSON.stringify(schemesList)); } catch(ce) {}
                        if (callback) callback(null, resp);
                    } catch(e) {
                        try { localStorage.setItem('lora_cached_schemes', JSON.stringify(schemesList)); } catch(ce) {}
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
            globalNodeId: globalNodeId || LoraDecoder.globalNodeId,
            schemes: schemesList
        });
        xhr.send(payload);
    };

    // Initialize activeSchemes from localStorage cache or defaults immediately
    try {
        var cached = localStorage.getItem('lora_cached_schemes');
        if (cached) {
            var cParsed = JSON.parse(cached);
            if (cParsed && cParsed.length) LoraDecoder.activeSchemes = cParsed;
        }
    } catch(e) {}
    if (!LoraDecoder.activeSchemes || !LoraDecoder.activeSchemes.length) {
        LoraDecoder.activeSchemes = LoraDecoder.getDefaultSchemes();
    }

    if (typeof window !== 'undefined') {
        window.LoraDecoder = LoraDecoder;
    }
    if (typeof module !== 'undefined' && module.exports) {
        module.exports = LoraDecoder;
    }

})(typeof window !== 'undefined' ? window : (typeof global !== 'undefined' ? global : this));
