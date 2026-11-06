-- ==============================================================================
-- pipeline.lua — LoRa Decoder Pipeline & Condition Evaluator
-- ==============================================================================
-- Part of the Standalone LoRa Decoder & Home Assistant Pipeline
-- Handles:
--   1. Raw packet intake (hex, status, metadata)
--   2. Strict Hardware CRC gate (drops CRC_BAD, CRC_ERR, NO_CRC)
--   3. Decoder scheme matching & metric extraction
--   4. Condition filtering & node validation
-- ==============================================================================

local LoraDecoder = require "lora_decoder"

local Pipeline = {
    _VERSION = "2.1.0"
}

-- ------------------------------------------------------------------------------
-- Pipeline Execution
-- ------------------------------------------------------------------------------
-- Takes a raw packet table:
--   pkt = {
--       hex    = "CAFE96B840EB0102...",
--       status = "CRC_OK",
--       rssi   = -28.4,
--       snr    = 6.0,
--       freq   = 868.5,
--       datr   = "SF12BW125",
--       size   = 39,
--       tmst   = 12345678
--   }
-- Returns:
--   success (boolean), result (table or error string)
function Pipeline.process_packet(pkt, config, condition_fn)
    if not pkt or not pkt.hex then
        return false, "MISSING_PAYLOAD"
    end

    -- 1. STRICT HARDWARE CRC INTEGRITY GATE
    -- Drop any frame with bit flips or failed checksum
    local status = tostring(pkt.status or ""):upper()
    if status ~= "" and status ~= "CRC_OK" then
        return false, "CORRUPTED_CRC_" .. status
    end

    -- 2. RUN STANDALONE DECODER ENGINE
    local dec_res, dec_err = LoraDecoder.decode_packet(pkt, config)
    if not dec_res or not dec_res.metrics then
        return false, dec_err or "DECODE_FAILED"
    end

    local metrics = dec_res.metrics
    local node_id = dec_res.node_id or metrics.node_id or "UNKNOWN"

    -- 3. EVALUATE PIPELINE CONDITIONS
    -- Optional condition callback: function(node_id, metrics, pkt) -> bool, reason
    if condition_fn and type(condition_fn) == "function" then
        local allowed, reason = condition_fn(node_id, metrics, pkt)
        if not allowed then
            return false, reason or "CONDITION_CHECK_FAILED"
        end
    end

    return true, {
        node_id     = node_id,
        scheme_id   = dec_res.scheme_id,
        scheme_name = dec_res.scheme_name,
        metrics     = metrics,
        raw_hex     = dec_res.raw_hex,
        size        = dec_res.size,
        timestamp   = metrics.last_seen or os.date("!%Y-%m-%dT%H:%M:%SZ")
    }
end

-- Process raw hex string directly through the pipeline
function Pipeline.process_hex(hex, config, condition_fn)
    local pkt = {
        hex    = hex,
        status = "CRC_OK",
        size   = #LoraDecoder.hex_to_bytes(hex)
    }
    return Pipeline.process_packet(pkt, config, condition_fn)
end

return Pipeline
