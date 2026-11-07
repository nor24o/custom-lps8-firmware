-- ==============================================================================
-- benchmark_pipeline.lua - High-Precision Pipeline Latency & Throughput Benchmark
-- ==============================================================================
local LoraDecoder = require "lora_decoder"
local Pipeline    = require "pipeline"

local pkt = {
    hex    = "CAFE96B840EB010201490271FFFB00180421036700B404880000000000000000",
    status = "CRC_OK",
    rssi   = -28.4,
    snr    = 6.0,
    freq   = 868.5,
    size   = 32
}

-- Detect architecture
local f = io.popen("uname -m 2>/dev/null")
local arch = f and f:read("*l") or "Unknown"
if f then f:close() end

-- Warmup
for _ = 1, 100 do Pipeline.process_packet(pkt) end

local N = 5000
local t0 = os.clock()
for _ = 1, N do
    local ok, res = Pipeline.process_packet(pkt)
end
local t1 = os.clock()
local total_sec = t1 - t0
local us_per_pkt = (total_sec / N) * 1e6
local pkts_per_sec = N / total_sec

print("==============================================================")
print(string.format(" PIPELINE BENCHMARK: %s Architecture", arch:upper()))
print("==============================================================")
print(string.format("Iterations:                  %d packets", N))
print(string.format("Total CPU Time:              %.4f seconds", total_sec))
print(string.format("Per-Packet Pipeline Latency: %.2f us (%.3f ms)", us_per_pkt, us_per_pkt / 1000.0))
print(string.format("Throughput:                  %.1f packets / second", pkts_per_sec))
print("==============================================================")
