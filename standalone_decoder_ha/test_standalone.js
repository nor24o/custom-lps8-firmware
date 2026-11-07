/**
 * test_standalone.js — Node.js Standalone Test Runner
 */
const path = require('path');
const fs = require('fs');

// Load JS decoder engine
const decoderPath = path.join(__dirname, 'lora_decoder.js');
let LoraDecoder;
if (fs.existsSync(decoderPath)) {
    LoraDecoder = require(decoderPath);
} else {
    LoraDecoder = require('../gui/www/luci-static/resources/lora_decoder.js');
}

const sampleHex = "CAFE96B840EB010201490271FFFB00180421036700B404880000000000000000";

console.log("=== Node.js Standalone LoRa Decoder Test ===");
const res = LoraDecoder.decodePacket(sampleHex);

console.log("Matched Scheme:", res.schemeName || res.schemeId);
console.log("Extracted Node ID:", res.nodeId);
console.log("Decoded Metrics:");
console.log(JSON.stringify(res.data, null, 2));

if (res.nodeId === "CAFE" && res.data.temperature === 18 && res.data.battery === 3.29) {
    console.log("\n>>> Node.js Standalone Test: ALL CHECKS PASSED! <<<");
} else {
    console.error("\n>>> Node.js Standalone Test: FAILED <<<");
    process.exit(1);
}
