/**
 * lora_decoder.js — LoRa Payload Multi-Scheme Decoding & Node ID Extraction Engine
 * Compatible with Dragino LPS8 (SX1302) & LG01/LG02 (SX1276)
 * 
 * Features:
 * - Multi-Way Node ID Extraction:
 *     1. NetID + SenderID (e.g. Byte 0 NetID 0xAA + Byte 1 SenderID 0x0C -> "AA0C", "0C", or "12")
 *     2. Custom Byte Offset & Length (e.g. Offset 1, Length 1 or Offset 0, Length 2)
 *     3. From Decoded Output Property (e.g. `senderId`, `node_id`, `id`)
 *     4. LoRaWAN DevAddr (4 Bytes at Offset 1)
 *     5. Smart Auto-Detect Cascade
 * - Multi-Scheme Decoders:
 *     - Channel-Type-Value (CTV / TLV) Parser (e.g. AA 0C 64 00 01 11 09 C4 02 05 0C E4)
 *     - Visual Field Slicer (No-Code multi-byte extractor)
 *     - JavaScript Functions (TTN / ChirpStack style)
 *     - Cayenne LPP Standard (IPSO channels)
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
    // Node ID Extraction Engine
    // -------------------------------------------------------------------------

    LoraDecoder.extractNodeId = function(bytes, hex, scheme, decodedData, globalRule) {
        if (!hex || hex.length === 0) {
            return { id: "UNKNOWN", method: "None" };
        }
        bytes = bytes || LoraDecoder.hexToBytes(hex);
        
        var rule = (scheme && scheme.nodeId) || globalRule || LoraDecoder.globalNodeId || { source: "auto" };
        var src = rule.source || "auto";
        var offset = parseInt(rule.offset, 10);
        if (isNaN(offset)) offset = 0;
        var length = parseInt(rule.length, 10) || 1;
        var format = rule.format || "net_hex"; // "hex", "decimal", "net_hex", "sender_only", "ascii"
        var pfx = rule.prefix || "";
        var fieldName = rule.fieldName || "senderId";

        // 1. From Decoded Field
        if (src === "field" || (src === "auto" && decodedData)) {
            if (decodedData) {
                var cand = decodedData[fieldName] || decodedData.senderId || decodedData.sender_id || 
                           decodedData.node_id || decodedData.dev_id || decodedData.id || 
                           decodedData.nodeId || decodedData.address;
                if (cand !== undefined && cand !== null && String(cand).trim() !== "") {
                    var strVal = String(cand).trim().toUpperCase();
                    return { id: pfx + strVal, method: "Field '" + (fieldName || "senderId") + "'" };
                }
            }
        }

        // 2. 2-Byte Node ID (Bytes 0..1 in HEX, e.g. 12 34 -> "1234")
        if (src === "node_2b" || src === "node_id_2b" || (src === "auto" && bytes.length >= 2 && bytes[0] !== 0xAA)) {
            var b0 = (bytes[0] < 16 ? "0" : "") + bytes[0].toString(16).toUpperCase();
            var b1 = (bytes[1] < 16 ? "0" : "") + bytes[1].toString(16).toUpperCase();
            if (format === "decimal") {
                var dVal = (bytes[0] * 256) + bytes[1];
                return { id: pfx + dVal.toString(10), method: "2-Byte Node ID (Decimal " + dVal + ")" };
            }
            return { id: pfx + b0 + b1, method: "2-Byte Node ID (" + b0 + b1 + ")" };
        }

        // 3. NetID + SenderID (e.g. Byte 0 is NetID 0xAA, Byte 1 is SenderID 0x0C)
        if (src === "net_sender" || (src === "auto" && bytes.length >= 2 && bytes[0] === 0xAA)) {
            var netHex = (bytes[0] < 16 ? "0" : "") + bytes[0].toString(16).toUpperCase();
            var senderHex = (bytes[1] < 16 ? "0" : "") + bytes[1].toString(16).toUpperCase();
            if (format === "decimal") {
                return { id: pfx + bytes[1].toString(10), method: "NetID+SenderID (Decimal " + bytes[1] + ")" };
            } else if (format === "sender_only" || src === "sender_only" || rule.senderOnly) {
                return { id: pfx + senderHex, method: "SenderID Only (Byte 1: " + senderHex + ")" };
            }
            return { id: pfx + netHex + senderHex, method: "NetID (0x" + netHex + ") + SenderID (0x" + senderHex + ")" };
        }

        // 3. SenderID Only (Byte 1)
        if (src === "sender_only" && bytes.length >= 2) {
            var sHex = (bytes[1] < 16 ? "0" : "") + bytes[1].toString(16).toUpperCase();
            if (format === "decimal") {
                return { id: pfx + bytes[1].toString(10), method: "SenderID Decimal (Byte 1: " + bytes[1] + ")" };
            }
            return { id: pfx + sHex, method: "SenderID (Byte 1: 0x" + sHex + ")" };
        }

        // 4. Custom Byte Offset & Length
        if (src === "offset" && bytes.length > offset) {
            var sliceLen = Math.min(length, bytes.length - offset);
            if (format === "decimal") {
                var num = 0;
                for (var i = 0; i < sliceLen; i++) {
                    num = (num * 256) + bytes[offset + i];
                }
                return { id: pfx + num.toString(10), method: "Offset " + offset + " Len " + sliceLen + " (Decimal)" };
            } else if (format === "ascii") {
                var str = "";
                for (var i = 0; i < sliceLen; i++) {
                    var b = bytes[offset + i];
                    if (b >= 32 && b <= 126) str += String.fromCharCode(b);
                }
                return { id: pfx + (str || "UNKNOWN"), method: "Offset " + offset + " Len " + sliceLen + " (ASCII)" };
            } else if (format === "net_hex" && rule.netIdOffset !== undefined) {
                var nOff = parseInt(rule.netIdOffset, 10) || 0;
                var netByte = bytes[nOff] || 0;
                var nHex = (netByte < 16 ? "0" : "") + netByte.toString(16).toUpperCase();
                var sHex = "";
                for (var i = 0; i < sliceLen; i++) {
                    var b = bytes[offset + i];
                    sHex += (b < 16 ? "0" : "") + b.toString(16).toUpperCase();
                }
                return { id: pfx + nHex + sHex, method: "NetID (Offset " + nOff + ") + Offset " + offset };
            } else {
                var h = "";
                for (var i = 0; i < sliceLen; i++) {
                    var b = bytes[offset + i];
                    h += (b < 16 ? "0" : "") + b.toString(16).toUpperCase();
                }
                return { id: pfx + h, method: "Offset " + offset + " Len " + sliceLen + " (Hex)" };
            }
        }

        // 5. Header / First 2 Bytes
        if (src === "header" && bytes.length >= 2) {
            var h = hex.substring(0, 4).toUpperCase();
            return { id: pfx + h, method: "Header (First 2 Bytes)" };
        }

        // 6. Single Byte (Offset 0)
        if (src === "single" && bytes.length >= 1) {
            var s = hex.substring(0, 2).toUpperCase();
            if (format === "decimal") {
                return { id: pfx + bytes[0].toString(10), method: "First Byte (Decimal " + bytes[0] + ")" };
            }
            return { id: pfx + s, method: "First Byte (Hex 0x" + s + ")" };
        }

        // 7. LoRaWAN DevAddr (4 Bytes at Offset 1)
        if (src === "devaddr" && bytes.length >= 5) {
            var addrHex = hex.substring(2, 10).toUpperCase();
            return { id: pfx + addrHex, method: "LoRaWAN DevAddr (4B)" };
        }

        // 8. Fallback
        if (hex.length >= 4) {
            return { id: pfx + hex.substring(0, 4).toUpperCase(), method: "Fallback (First 2B)" };
        }
        return { id: pfx + hex.toUpperCase(), method: "Raw Payload" };
    };

    // -------------------------------------------------------------------------
    // Channel-Type-Value (CTV / TLV) Decoder Engine
    // Decodes schemas like: AA 0C 64 00 01 11 09 C4 02 05 0C E4
    // -------------------------------------------------------------------------

    LoraDecoder.decodeCtv = function(bytes, hex, dataOffset) {
        dataOffset = (dataOffset !== undefined) ? parseInt(dataOffset, 10) : 4;
        var out = {};

        if (bytes.length >= 4) {
            if (bytes[0] === 0xAA) {
                out.net_id = "0x" + (bytes[0] < 16 ? "0" : "") + bytes[0].toString(16).toUpperCase();
                out.sender_id = bytes[1];
                out.target_id = bytes[2];
                out.seq = bytes[3];
            } else {
                var b0 = (bytes[0] < 16 ? "0" : "") + bytes[0].toString(16).toUpperCase();
                var b1 = (bytes[1] < 16 ? "0" : "") + bytes[1].toString(16).toUpperCase();
                out.node_id = b0 + b1;
                var devType = bytes[2];
                out.device_type = "0x" + (devType < 16 ? "0" : "") + devType.toString(16).toUpperCase();
                var classCode = Math.floor(devType / 16);
                var capCode = devType % 16;
                out.node_class = (classCode === 1) ? "A" : ((classCode === 2) ? "B" : ((classCode === 3) ? "C" : "Unknown"));
                var capNames = { 1: "Sensor", 2: "Actuator", 3: "Combo", 4: "Meter", 5: "Security", 6: "Dimmer" };
                out.capability = capNames[capCode] || "Generic";
                out.seq = bytes[3];
            }
        }

        var idx = dataOffset;
        while (idx < bytes.length) {
            var ch = bytes[idx++];
            if (idx >= bytes.length) break;
            var typeCode = bytes[idx++];

            if (typeCode === 0x11) {
                // 2-byte Generic Integer / Temperature
                if (idx + 1 >= bytes.length) break;
                var raw = (bytes[idx++] << 8) | bytes[idx++];
                if (raw & 0x8000) raw -= 0x10000;
                // Auto scale: if raw > 500 or raw < -200, scale 0.01 (e.g. 2500 -> 25.00°C), else 0.1
                var temp = (Math.abs(raw) > 500) ? +(raw * 0.01).toFixed(2) : +(raw * 0.1).toFixed(1);
                out.temperature = temp;
                out["ch" + ch + "_val"] = raw;
                out.val = temp;
            } else if (typeCode === 0x05) {
                // 2-byte Battery in mV
                if (idx + 1 >= bytes.length) break;
                var mv = (bytes[idx++] << 8) | bytes[idx++];
                out.battery = +(mv / 1000).toFixed(2);
                out.battery_mv = mv;
            } else if (typeCode === 0x01 || typeCode === 0x10) {
                // 1-byte Digital / Switch State
                if (idx >= bytes.length) break;
                var stateVal = bytes[idx++];
                out["ch" + ch + "_state"] = (stateVal === 1) ? "ON" : "OFF";
                out.state = (stateVal === 1) ? "ON" : "OFF";
            } else if (typeCode === 0x02 || typeCode === 0x12) {
                // 2-byte Analog Input
                if (idx + 1 >= bytes.length) break;
                var aRaw = (bytes[idx++] << 8) | bytes[idx++];
                if (aRaw & 0x8000) aRaw -= 0x10000;
                out["ch" + ch + "_analog"] = +(aRaw * 0.01).toFixed(2);
            } else if (typeCode === 0x67) {
                // Cayenne Temperature (0.1 °C signed)
                if (idx + 1 >= bytes.length) break;
                var cTemp = (bytes[idx++] << 8) | bytes[idx++];
                if (cTemp & 0x8000) cTemp -= 0x10000;
                out.temperature = +(cTemp * 0.1).toFixed(1);
                out.val = out.temperature;
            } else if (typeCode === 0x68) {
                // Cayenne Humidity (0.5 %)
                if (idx >= bytes.length) break;
                out.humidity = +(bytes[idx++] * 0.5).toFixed(1);
            } else {
                // Unknown type: advance to prevent loop lock
                break;
            }
        }

        return out;
    };

    // -------------------------------------------------------------------------
    // Visual Byte Segmentation & Inspector Engine
    // -------------------------------------------------------------------------

    LoraDecoder.segmentBytes = function(bytes, hex, result) {
        if (!bytes || !bytes.length) return [];
        var segments = [];
        var schemeId = (result && result.schemeId) || "";
        var data = (result && result.data) || {};

        if (schemeId === "scheme_2b_node_tlv" || (bytes.length >= 4 && bytes[0] !== 0xAA && data.node_id)) {
            // Segment 1: 2-Byte Node ID (Bytes 0..1)
            segments.push({
                start: 0,
                end: 1,
                name: "Node ID",
                desc: "16-Bit Device ID: " + (data.node_id || ""),
                color: "#2563eb", // Blue
                textColor: "#ffffff"
            });
            // Segment 2: Device Type (Byte 2)
            if (bytes.length >= 3) {
                var cls = data.node_class ? ("Class " + data.node_class) : "";
                var cap = data.capability || "";
                var typeLabel = (cls || cap) ? (cls + " " + cap).trim() : "Device Type";
                segments.push({
                    start: 2,
                    end: 2,
                    name: "Device Type",
                    desc: typeLabel + " (" + (data.device_type || ("0x" + (bytes[2]<16?"0":"") + bytes[2].toString(16).toUpperCase())) + ")",
                    color: "#7c3aed", // Purple
                    textColor: "#ffffff"
                });
            }
            // Segment 3: Sequence Counter (Byte 3)
            if (bytes.length >= 4) {
                segments.push({
                    start: 3,
                    end: 3,
                    name: "Sequence",
                    desc: "Sequence Counter #" + (data.seq !== undefined ? data.seq : bytes[3]),
                    color: "#d97706", // Amber
                    textColor: "#ffffff"
                });
            }
            // Dynamic TLV Channels (Bytes 4+)
            var idx = 4;
            while (idx < bytes.length) {
                var startIdx = idx;
                var ch = bytes[idx++];
                if (idx >= bytes.length) break;
                var typeCode = bytes[idx++];
                var endIdx = idx - 1;
                var chName = "Ch " + ch;
                var chDesc = "";
                var color = "#059669"; // Emerald

                if (typeCode === 0x11) {
                    if (idx + 1 < bytes.length) {
                        endIdx = idx + 1;
                        idx += 2;
                        chName += " Temp";
                        chDesc = (data.temperature !== undefined) ? (data.temperature + " °C") : "2-Byte Temperature";
                        color = "#059669";
                    } else break;
                } else if (typeCode === 0x05) {
                    if (idx + 1 < bytes.length) {
                        endIdx = idx + 1;
                        idx += 2;
                        chName += " Battery";
                        chDesc = (data.battery !== undefined) ? (data.battery + " V (" + (data.battery_mv || "") + "mV)") : "2-Byte Battery";
                        color = "#0891b2"; // Cyan
                    } else break;
                } else if (typeCode === 0x01 || typeCode === 0x10) {
                    if (idx < bytes.length) {
                        endIdx = idx;
                        idx += 1;
                        chName += " State";
                        chDesc = (data.state !== undefined) ? ("State: " + data.state) : "1-Byte Switch";
                        color = "#ea580c"; // Orange
                    } else break;
                } else if (typeCode === 0x02 || typeCode === 0x12) {
                    if (idx + 1 < bytes.length) {
                        endIdx = idx + 1;
                        idx += 2;
                        chName += " Analog";
                        chDesc = "2-Byte Analog Input";
                        color = "#4f46e5"; // Indigo
                    } else break;
                } else {
                    break;
                }

                segments.push({
                    start: startIdx,
                    end: endIdx,
                    name: chName,
                    desc: chDesc,
                    color: color,
                    textColor: "#ffffff"
                });
            }
        } else if (schemeId === "scheme_universal_tlv" || (bytes.length >= 4 && bytes[0] === 0xAA)) {
            // NetID (Byte 0)
            segments.push({
                start: 0,
                end: 0,
                name: "NetID",
                desc: "Network Identifier (0xAA)",
                color: "#334155",
                textColor: "#ffffff"
            });
            // SenderID (Byte 1)
            segments.push({
                start: 1,
                end: 1,
                name: "Sender ID",
                desc: "Node ID: " + bytes[1],
                color: "#2563eb",
                textColor: "#ffffff"
            });
            // TargetID (Byte 2)
            segments.push({
                start: 2,
                end: 2,
                name: "Gateway ID",
                desc: "Destination GW: " + bytes[2],
                color: "#64748b",
                textColor: "#ffffff"
            });
            // Seq (Byte 3)
            segments.push({
                start: 3,
                end: 3,
                name: "Sequence",
                desc: "Sequence Counter #" + bytes[3],
                color: "#d97706",
                textColor: "#ffffff"
            });
            // Dynamic TLVs
            var idx = 4;
            while (idx < bytes.length) {
                var startIdx = idx;
                var ch = bytes[idx++];
                if (idx >= bytes.length) break;
                var typeCode = bytes[idx++];
                var endIdx = idx - 1;
                var chName = "Ch " + ch;
                var chDesc = "";
                var color = "#059669";

                if (typeCode === 0x11) {
                    if (idx + 1 < bytes.length) {
                        endIdx = idx + 1;
                        idx += 2;
                        chName += " Temp";
                        chDesc = (data.temperature !== undefined) ? (data.temperature + " °C") : "Temperature";
                        color = "#059669";
                    } else break;
                } else if (typeCode === 0x05) {
                    if (idx + 1 < bytes.length) {
                        endIdx = idx + 1;
                        idx += 2;
                        chName += " Battery";
                        chDesc = (data.battery !== undefined) ? (data.battery + " V") : "Battery";
                        color = "#0891b2";
                    } else break;
                } else if (typeCode === 0x01 || typeCode === 0x10) {
                    if (idx < bytes.length) {
                        endIdx = idx;
                        idx += 1;
                        chName += " State";
                        chDesc = "Switch State";
                        color = "#ea580c";
                    } else break;
                } else {
                    break;
                }
                segments.push({
                    start: startIdx,
                    end: endIdx,
                    name: chName,
                    desc: chDesc,
                    color: color,
                    textColor: "#ffffff"
                });
            }
        }

        // Fill any unsegmented trailing bytes
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
                    segments.push({
                        start: uncovStart,
                        end: i - 1,
                        name: "Payload",
                        desc: (i - uncovStart) + " Bytes",
                        color: "#94a3b8",
                        textColor: "#ffffff"
                    });
                    uncovStart = null;
                }
            }
        }

        segments.sort(function(a, b) { return a.start - b.start; });
        return segments;
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
                out[pfx + "illuminance"] = (bytes[i++] << 8) | bytes[i++];
                parsedAny = true;
            } else if (type === 0x66) { // Presence (1B)
                if (i >= bytes.length) break;
                out[pfx + "presence"] = bytes[i++];
                parsedAny = true;
            } else if (type === 0x67) { // Temperature (2B, 0.1 °C signed)
                if (i + 1 >= bytes.length) break;
                var val = (bytes[i++] << 8) | bytes[i++];
                if (val & 0x8000) val -= 0x10000;
                out.temperature = +(val * 0.1).toFixed(1);
                out[pfx + "temperature"] = out.temperature;
                parsedAny = true;
            } else if (type === 0x68) { // Humidity (1B, 0.5 %)
                if (i >= bytes.length) break;
                out.humidity = +(bytes[i++] * 0.5).toFixed(1);
                out[pfx + "humidity"] = out.humidity;
                parsedAny = true;
            } else if (type === 0x73) { // Barometer (2B, 0.1 hPa)
                if (i + 1 >= bytes.length) break;
                out[pfx + "barometer"] = +(((bytes[i++] << 8) | bytes[i++]) * 0.1).toFixed(1);
                parsedAny = true;
            } else {
                break;
            }
        }

        return parsedAny ? out : null;
    };

    // -------------------------------------------------------------------------
    // Visual Field Slicer
    // -------------------------------------------------------------------------

    LoraDecoder.decodeFields = function(bytes, fields) {
        var out = {};
        if (!fields || !fields.length) return out;

        for (var i = 0; i < fields.length; i++) {
            var f = fields[i];
            var off = parseInt(f.offset, 10) || 0;
            var len = parseInt(f.length, 10) || 1;
            var scale = parseFloat(f.scale);
            if (isNaN(scale)) scale = 1.0;
            var add = parseFloat(f.add) || 0.0;
            var unit = f.unit ? (" " + f.unit) : "";

            if (off >= bytes.length) continue;

            var type = f.type || 'uint8';

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
            out[f.name] = unit ? (computed + unit) : computed;
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
            if (decType === 'ctv' || decType === 'tlv') {
                var ctvRes = LoraDecoder.decodeCtv(bytes, hex, scheme.dataOffset || 4);
                if (ctvRes && Object.keys(ctvRes).length > 0) {
                    return { success: true, data: ctvRes, error: null };
                }
            }

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

            if (decType === 'js' || scheme.jsCode) {
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
        } catch(err) {
            return {
                success: false,
                data: null,
                error: err.message || String(err)
            };
        }

        // Intelligent Fallback: if packet has at least 4 bytes, decode via CTV
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
        var hex = (packet.hex || '').trim();
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
                id: 'scheme_2b_node_tlv',
                name: '2-Byte Node ID + Device Type + TLV (12 34 11 00 ...)',
                description: 'Matches 2-byte Node ID with 1-byte Device Type (Class/Capability), Seq and dynamic Channel-Type-Value sensors (e.g. 12 34 11 00 01 11 09 C4 02 05 0C E4)',
                enabled: true,
                matchType: 'condition',
                matchCondition: '// Match if at least 4 bytes and byte 0 is not legacy 0xAA\nreturn bytes.length >= 4 && bytes[0] !== 0xAA;',
                nodeId: {
                    source: 'offset',
                    offset: 0,
                    length: 2,
                    format: 'hex',
                    prefix: ''
                },
                type: 'ctv',
                dataOffset: 4,
                jsCode: [
                    '// 2-Byte Node ID + Device Type + TLV Decoder (e.g. 12341100011109c402050ce4)',
                    'var nodeId = ((bytes[0] < 16 ? "0" : "") + bytes[0].toString(16) + (bytes[1] < 16 ? "0" : "") + bytes[1].toString(16)).toUpperCase();',
                    'var devType = bytes[2];',
                    'var classCode = Math.floor(devType / 16);',
                    'var capCode = devType % 16;',
                    'var className = (classCode === 1) ? "A" : ((classCode === 2) ? "B" : ((classCode === 3) ? "C" : "Unknown"));',
                    'var capMap = {1: "Sensor", 2: "Actuator", 3: "Combo", 4: "Meter", 5: "Security", 6: "Dimmer"};',
                    'var capName = capMap[capCode] || "Generic";',
                    'var seq = bytes[3];',
                    '',
                    'var out = {',
                    '    node_id: nodeId,',
                    '    device_type: "0x" + (devType < 16 ? "0" : "") + devType.toString(16).toUpperCase(),',
                    '    node_class: className,',
                    '    capability: capName,',
                    '    seq: seq',
                    '};',
                    '',
                    'var i = 4;',
                    'while (i < bytes.length) {',
                    '    var ch = bytes[i++];',
                    '    if (i >= bytes.length) break;',
                    '    var type = bytes[i++];',
                    '    if (type === 0x11) { // 2-byte generic / temp',
                    '        if (i + 1 >= bytes.length) break;',
                    '        var raw = (bytes[i++] << 8) | bytes[i++];',
                    '        if (raw & 0x8000) raw -= 0x10000;',
                    '        var temp = (Math.abs(raw) > 500) ? +(raw * 0.01).toFixed(2) : +(raw * 0.1).toFixed(1);',
                    '        out["temperature"] = temp;',
                    '        out["ch" + ch + "_val"] = raw;',
                    '    } else if (type === 0x05) { // 2-byte battery in mV',
                    '        if (i + 1 >= bytes.length) break;',
                    '        var mv = (bytes[i++] << 8) | bytes[i++];',
                    '        out["battery"] = +(mv / 1000).toFixed(2);',
                    '        out["battery_mv"] = mv;',
                    '    } else if (type === 0x01 || type === 0x10) { // 1-byte digital',
                    '        if (i >= bytes.length) break;',
                    '        out["ch" + ch + "_state"] = (bytes[i++] === 1) ? "ON" : "OFF";',
                    '        out["state"] = out["ch" + ch + "_state"];',
                    '    } else if (type === 0x02 || type === 0x12) { // 2-byte analog',
                    '        if (i + 1 >= bytes.length) break;',
                    '        var aRaw = (bytes[i++] << 8) | bytes[i++];',
                    '        if (aRaw & 0x8000) aRaw -= 0x10000;',
                    '        out["ch" + ch + "_analog"] = +(aRaw * 0.01).toFixed(2);',
                    '    } else {',
                    '        break;',
                    '    }',
                    '}',
                    'return out;'
                ].join('\n')
            },
            {
                id: 'scheme_universal_tlv',
                name: 'Universal NetID + SenderID + TLV (AA 0C 64 ...)',
                description: 'Matches NetID 0xAA packets with SenderID, Target Gateway, Seq and dynamic Channel-Type-Value sensors',
                enabled: true,
                matchType: 'prefix',
                matchValue: 'aa',
                nodeId: {
                    source: 'net_sender',
                    format: 'net_hex'
                },
                type: 'ctv',
                dataOffset: 4,
                jsCode: [
                    '// Universal NetID + SenderID + TLV Decoder (e.g. aa0c6400011109c402050ce4)',
                    'var netId = "0x" + hex.substring(0, 2).toUpperCase();',
                    'var senderId = bytes[1];',
                    'var targetId = bytes[2];',
                    'var seq = bytes[3];',
                    '',
                    'var out = {',
                    '    net_id: netId,',
                    '    sender_id: senderId,',
                    '    node_id: hex.substring(0, 4).toUpperCase(),',
                    '    target_id: targetId,',
                    '    seq: seq',
                    '};',
                    '',
                    'var i = 4;',
                    'while (i < bytes.length) {',
                    '    var ch = bytes[i++];',
                    '    if (i >= bytes.length) break;',
                    '    var type = bytes[i++];',
                    '    if (type === 0x11) { // 2-byte generic / temp',
                    '        if (i + 1 >= bytes.length) break;',
                    '        var raw = (bytes[i++] << 8) | bytes[i++];',
                    '        if (raw & 0x8000) raw -= 0x10000;',
                    '        var temp = (Math.abs(raw) > 500) ? +(raw * 0.01).toFixed(2) : +(raw * 0.1).toFixed(1);',
                    '        out["temperature"] = temp;',
                    '        out["ch" + ch + "_val"] = raw;',
                    '    } else if (type === 0x05) { // 2-byte battery in mV',
                    '        if (i + 1 >= bytes.length) break;',
                    '        var mv = (bytes[i++] << 8) | bytes[i++];',
                    '        out["battery"] = +(mv / 1000).toFixed(2);',
                    '        out["battery_mv"] = mv;',
                    '    } else if (type === 0x01 || type === 0x10) { // 1-byte digital',
                    '        if (i >= bytes.length) break;',
                    '        out["ch" + ch + "_state"] = (bytes[i++] === 1) ? "ON" : "OFF";',
                    '    } else if (type === 0x02 || type === 0x12) { // 2-byte analog',
                    '        if (i + 1 >= bytes.length) break;',
                    '        var aRaw = (bytes[i++] << 8) | bytes[i++];',
                    '        if (aRaw & 0x8000) aRaw -= 0x10000;',
                    '        out["ch" + ch + "_analog"] = +(aRaw * 0.01).toFixed(2);',
                    '    } else {',
                    '        break;',
                    '    }',
                    '}',
                    'return out;'
                ].join('\n')
            },
            {
                id: 'scheme_aa0b',
                name: 'Sensor Node AA0B (Temp / Volt / Seq)',
                description: 'Matches incoming payloads starting with AA0B header',
                enabled: true,
                matchType: 'prefix',
                matchValue: 'aa0b',
                nodeId: {
                    source: 'net_sender',
                    format: 'net_hex'
                },
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
                id: 'scheme_ascii_ping',
                name: 'ASCII Text & Test Pings',
                description: 'Auto-decodes printable text strings (e.g. PING_FROM_LPS8)',
                enabled: true,
                matchType: 'condition',
                nodeId: {
                    source: 'auto'
                },
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
                nodeId: {
                    source: 'auto'
                },
                type: 'cayenne_lpp'
            }
        ];
    };

    // -------------------------------------------------------------------------
    // REST API Integration
    // -------------------------------------------------------------------------

    LoraDecoder.globalNodeId = {
        source: 'auto',
        format: 'net_hex',
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
                        if (parsed && parsed.globalNodeId) {
                            LoraDecoder.globalNodeId = parsed.globalNodeId;
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
            globalNodeId: globalNodeId || LoraDecoder.globalNodeId,
            schemes: schemesList
        });
        xhr.send(payload);
    };

    // Initialize activeSchemes with defaults
    LoraDecoder.activeSchemes = LoraDecoder.getDefaultSchemes();

    window.LoraDecoder = LoraDecoder;

})(window);
