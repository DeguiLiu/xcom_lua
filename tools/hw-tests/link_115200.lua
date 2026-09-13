-- Real-hardware 115200 8N1 link test against the MCU on COM37.
--
-- Sends a deterministic byte stream and compares what came back, byte for
-- byte, against what was sent.  The receive side is read through the receive
-- LOG lane, which xcom.h documents as the lossless lane ("the file lane is
-- lossless"), so the comparison is a genuine end-to-end RX check rather than a
-- display-text approximation.
--
-- Usage (from xcom_lua/):
--   runtime\luajit.exe ..\..\hw\link_115200.lua [port] [bytes] [logpath] [chunk] [pace_ms]
package.path = "./core/?.lua;" .. package.path
local ffi = require("ffi")
ffi.cdef[[uint64_t GetTickCount64(void); void Sleep(uint32_t);]]
local x = require("xcom_ffi")

local port   = arg[1] or "COM37"
local total  = tonumber(arg[2]) or 32768
local logp   = arg[3] or "D:/workspace/e2e2/logs/rx_115200.bin"
local chunk  = tonumber(arg[4]) or 512
local pace   = tonumber(arg[5]) or 50
local BAUD   = 115200

local function ms() return tonumber(ffi.C.GetTickCount64()) end

-- Deterministic payload: a 256-byte ramp repeated.  Every byte position is
-- known, so a drop shows up as an offset shift rather than silent corruption.
local ramp = {}
for i = 0, 255 do ramp[#ramp + 1] = string.char(i) end
ramp = table.concat(ramp)
local function expected(n)
    local reps = math.ceil(n / #ramp)
    return string.sub(string.rep(ramp, reps), 1, n)
end
local want = expected(total)

local h = x.create()
assert(h, "xcom_create failed")

local rc = tonumber(x.log_open(h, logp, false))
print(string.format("log_open            -> %d   (%s)", rc, logp))

rc = tonumber(x.open_async(h, port, BAUD, 8, 0, 0, 0, nil, nil))
print(string.format("open_async(%s)  -> %d", port, rc))
local okopen = false
for _ = 1, 40 do
    local s = x.get_snapshot(h)
    if s and s.port_state == x.port_open then okopen = true break end
    ffi.C.Sleep(50)
end
if not okopen then
    local e = x.take_error(h)
    print("open FAILED: " .. (e and (e.code .. " " .. e.message) or "no error detail"))
    x.destroy(h)
    os.exit(1)
end
print("port_state          -> OPEN")

-- Pace the TX at about the link rate: 512 B per 50 ms ~= 10.2 KB/s, just under
-- the 11.5 KB/s of 115200 8N1, so the peer's echo buffer cannot be swamped by
-- us (a peer-side overflow would be a peer limitation, not an XCOM defect).
local t0 = ms()
local sent = 0
while sent < total do
    local n = math.min(chunk, total - sent)
    local piece = string.sub(want, sent + 1, sent + n)
    local s = tonumber(x.send(h, piece, 0))
    if s ~= x.ok then print("  send failed at offset " .. sent .. " status=" .. tostring(s)) break end
    sent = sent + n
    ffi.C.Sleep(pace)
end
print(string.format("tx pushed           -> %d bytes in %d ms", sent, ms() - t0))

-- Wait for the echo to come back.  Budget: link time x3 plus slack.
local budget = math.floor(total / (BAUD / 10) * 1000 * 3) + 8000
local tw = ms()
local last = -1
while ms() - tw < budget do
    local s = x.get_snapshot(h)
    local rx = s and s.rx_bytes or 0
    if rx >= total then break end
    if rx ~= last then last = rx end
    ffi.C.Sleep(100)
end
local wait_ms = ms() - tw

local snap = x.get_snapshot(h)
print(string.format("rx wait             -> %d ms (budget %d)", wait_ms, budget))
print(string.format("rx_bytes=%d  tx_bytes=%d  callback_count=%d  port_state=%d",
                    snap.rx_bytes, snap.tx_bytes, snap.callback_count, snap.port_state))
print(string.format("loss counters: rx_sequence=%d rx_loss_offset=%d rx_backpressure_events=%d",
                    snap.rx_sequence, snap.rx_loss_offset, snap.rx_backpressure_events))
print(string.format("               rx_pool_exhausted_bytes=%d tx_rejected=%d save_rejected_bytes=%d flow_hold_events=%d",
                    snap.rx_pool_exhausted_bytes, snap.tx_rejected, snap.save_rejected_bytes, snap.flow_hold_events))
print(string.format("line errors:   framing=%d parity=%d overrun=%d break=%d",
                    snap.framing_errors, snap.parity_errors, snap.overrun_errors, snap.break_events))

print(string.format("log_flush           -> %d", tonumber(x.log_flush(h, 5000))))
print(string.format("log_close           -> %d", tonumber(x.log_close(h, 5000))))
x.close(h, 2000)
x.destroy(h)

-- Compare the received log against what was sent.
local f = assert(io.open(logp, "rb"))
local got = f:read("*a")
f:close()
print(string.format("log file            -> %d bytes on disk (expected %d)", #got, total))

if got == want then
    print("RESULT: BYTE-EXACT - no loss, no reordering, no corruption")
    os.exit(0)
end

-- Mismatch: characterise it before blaming anything.
local first_bad = nil
for i = 1, math.min(#got, #want) do
    if got:byte(i) ~= want:byte(i) then first_bad = i - 1 break end
end
print(string.format("RESULT: MISMATCH  first difference at offset %s (got %d bytes, want %d)",
                    tostring(first_bad), #got, #want))
local at = string.find(got, string.sub(want, 1, 64), 1, true)
print(string.format("        expected stream starts at file offset %s",
                    at and (at - 1) or "NOT FOUND"))
os.exit(1)
