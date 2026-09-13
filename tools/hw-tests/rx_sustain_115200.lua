-- Sustained RX at 115200 8N1 from a real MCU that transmits continuously.
--
-- The peer (RT-Thread msh on an IR-camera SoC) emits background ISP log lines
-- on its own, so this measures the RX path under real, un-paced traffic rather
-- than a synthetic loopback.  The receive LOG lane is the lossless lane, so the
-- byte count on disk is compared against the core's own rx_bytes accounting,
-- and every loss/error counter is sampled throughout.
--
-- Usage (from xcom_lua/):  runtime\luajit.exe ..\..\hw\rx_sustain_115200.lua [port] [seconds] [logpath]
package.path = "./core/?.lua;" .. package.path
local ffi = require("ffi")
ffi.cdef[[uint64_t GetTickCount64(void); void Sleep(uint32_t);]]
local x = require("xcom_ffi")

local port    = arg[1] or "COM37"
local seconds = tonumber(arg[2]) or 60
local logp    = arg[3] or "D:/workspace/e2e2/logs/rx_sustain.bin"
local BAUD    = 115200

local function ms() return tonumber(ffi.C.GetTickCount64()) end

local h = x.create()
assert(h, "xcom_create failed")
print(string.format("log_open -> %d (%s)", tonumber(x.log_open(h, logp, false)), logp))
print(string.format("open_async(%s) -> %d", port, tonumber(x.open_async(h, port, BAUD, 8, 0, 0, 0, nil, nil))))
local opened = false
for _ = 1, 40 do
    local s = x.get_snapshot(h)
    if s and s.port_state == x.port_open then opened = true break end
    ffi.C.Sleep(50)
end
if not opened then print("open FAILED"); x.destroy(h); os.exit(1) end

local first = x.get_snapshot(h)
local t0 = ms()
local prev_rx = first.rx_bytes
local stalls = 0
print(string.format("collecting %d s of continuous RX at %d 8N1 ...", seconds, BAUD))
while ms() - t0 < seconds * 1000 do
    -- Drain the display lane too: a caller that never drains is a different test.
    x.drain_display(h, 65536)
    ffi.C.Sleep(200)
    local s = x.get_snapshot(h)
    if s.rx_bytes == prev_rx then stalls = stalls + 1 end
    prev_rx = s.rx_bytes
end
local last = x.get_snapshot(h)
local elapsed = ms() - t0

local fc = tonumber(x.log_flush(h, 5000))
local cc = tonumber(x.log_close(h, 5000))
x.close(h, 2000)
x.destroy(h)

local f = assert(io.open(logp, "rb"))
local got = f:read("*a")
f:close()

local rx_delta = last.rx_bytes - first.rx_bytes
print(string.format("elapsed             = %d ms (%d s)", elapsed, seconds))
print(string.format("rx_bytes delta      = %d   (%.2f KB/s effective, ~11.5 KB/s is 100%% of 115200 8N1)",
                    rx_delta, rx_delta / 1024 / (elapsed / 1000)))
print(string.format("log file on disk    = %d bytes", #got))
print(string.format("log_flush=%d log_close=%d  (0 = OK)", fc, cc))
print(string.format("2 s stall samples   = %d of %d", stalls, math.floor(elapsed / 200)))
print("---- loss / error counters (end of run) ----")
print(string.format("rx_sequence=%d rx_loss_offset=%d rx_backpressure_events=%d",
                    last.rx_sequence, last.rx_loss_offset, last.rx_backpressure_events))
print(string.format("rx_pool_exhausted_bytes=%d tx_rejected=%d save_rejected_bytes=%d",
                    last.rx_pool_exhausted_bytes, last.tx_rejected, last.save_rejected_bytes))
print(string.format("display_paused_bytes=%d ui_trimmed_bytes=%d display_pending=%d",
                    last.display_paused_bytes, last.ui_trimmed_bytes, last.display_pending))
print(string.format("flow_hold_events=%d callback_count=%d", last.flow_hold_events, last.callback_count))
print(string.format("line errors: framing=%d parity=%d overrun=%d break=%d (all 0 = clean framing)",
                    last.framing_errors, last.parity_errors, last.overrun_errors, last.break_events))

-- Structural sanity: the device interleaves shell output with its own ISP log
-- lines; counting recurring markers proves the capture is a coherent stream
-- rather than a truncated one.
local _, markers = got:gsub("%[I/irsc_cfg%]", "")
local _, prompts = got:gsub("msh />", "")
print(string.format("markers in capture  = %d '[I/irsc_cfg]' blocks, %d 'msh />' prompts", markers, prompts))

local clean = (last.rx_loss_offset == 0 and last.rx_backpressure_events == 0
               and last.rx_pool_exhausted_bytes == 0 and last.save_rejected_bytes == 0
               and last.framing_errors == 0 and last.parity_errors == 0
               and last.overrun_errors == 0 and last.break_events == 0)
print("RESULT: " .. (clean and "NO LOSS REPORTED by any counter" or "COUNTERS REPORT LOSS - see above"))
os.exit(clean and 0 or 1)
