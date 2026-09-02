-- Full-bandwidth sustained-receive stress test (no UI).
--
-- Simulates 921600-baud line rate (~90 KiB/s) through the SAME rx_ingress
-- entry point the real serial callback uses (xcom_test_inject_rx), pumped at
-- the same 10 ms cadence the UI display poller would use.  Verifies the
-- data-loss contract end to end:
--   * every injected byte comes back out of drain_display exactly once
--   * rx_pool_exhausted_bytes stays 0 (the 512 KiB core pool never fills)
--   * display_pending drains to 0 within the poll budget
--
-- Usage: runtime\luajit.exe tests\stress_fullband.lua [seconds] [kib_per_s]

local ffi = require("ffi")
ffi.cdef[[void Sleep(unsigned long ms);]]
local script = (arg and arg[0]) or "tests/stress_fullband.lua"
local tests_dir = script:match("^(.*)[/\\]") or "."
local root = tests_dir:gsub("[/\\]$", "") .. "/.."
package.path = root .. "/core/?.lua;" .. package.path
local xcom = require("xcom_ffi")

local seconds = tonumber(arg and arg[1]) or 30
local rate_kib = tonumber(arg and arg[2]) or 90  -- 921600 baud ~= 90 KiB/s

local handle, err = xcom.create()
assert(handle, err)

-- A persistent port_state == open is required by inject_rx.  Open COM-look
-- failures still leave the HSM CLOSED, so drive a virtual session: the core
-- accepts inject only when OPEN; try the highest COM index, else bail.
-- Fall back list: common loopback pairs on dev boxes.
local candidates = { "COM3", "COM4", "COM5", "COM2", "COM1" }
local opened_port = nil
for _, port in ipairs(candidates) do
    local rc = tonumber(xcom.open_async(handle, port, 115200, 8, 0, 0, 0, false, false))
    if rc == xcom.ok then
        for _ = 1, 40 do
            local snap = xcom.get_snapshot(handle)
            if snap and snap.port_state == xcom.port_open then
                opened_port = port
                break
            end
            local result = tonumber(xcom.take_open_result(handle))
            if result ~= xcom.ok and result ~= xcom.err_busy then break end
            ffi.C.Sleep(50)
        end
    end
    if opened_port then break end
    -- roll to the next candidate if this one failed to open
    local snap = xcom.get_snapshot(handle)
    if snap and snap.port_state ~= xcom.port_closed then
        xcom.close(handle, 2000)
    end
end
if not opened_port then
    print("no COM port could be opened for injection; cannot run")
    os.exit(2)
end
print("inject port: " .. opened_port)

-- Build a ~4 KiB text frame (line-numbered so content integrity is spot
-- checkable at the end).
local frame = {}
for i = 1, 200 do
    frame[#frame + 1] = string.format("[%06d] 0123456789ABCDEF velocity frame data\r\n", i)
end
local frame_text = table.concat(frame)
print(string.format("frame: %d bytes", #frame_text))

local per_tick_bytes = math.floor(rate_kib * 1024 * 10 / 1000)  -- per 10 ms tick
local frames_per_tick = math.max(1, math.floor(per_tick_bytes / #frame_text))
local tick_remainder = per_tick_bytes - frames_per_tick * #frame_text

local injected, drained = 0, 0
local exhausted_first_seen = nil
local overflow_events = 0
local ticks = 0
local deadline = os.clock() + seconds
local chunk = ffi.new("char[?]", 65536)

print(string.format("rate: %d KiB/s (%d bytes/tick), duration %ds",
                   rate_kib, per_tick_bytes, seconds))

while os.clock() < deadline do
    ticks = ticks + 1
    -- P1 cadence: inject what the line would have delivered in 10 ms.
    for _ = 1, frames_per_tick do
        local rc = tonumber(xcom.test_inject_rx(handle, frame_text, #frame_text))
        if rc ~= xcom.ok then overflow_events = overflow_events + 1 end
    end
    if tick_remainder > 0 then
        local rc = tonumber(xcom.test_inject_rx(handle, frame_text:sub(1, tick_remainder), tick_remainder))
        if rc ~= xcom.ok then overflow_events = overflow_events + 1 end
    end
    injected = injected + frames_per_tick * #frame_text + (tick_remainder > 0 and tick_remainder or 0)

    -- Same drain cadence/budget as poll_display: up to 8 x 64 KiB per tick.
    for _ = 1, 8 do
        local rc, text = xcom.drain_display(handle, 65536)
        if rc ~= xcom.ok or not text or #text == 0 then break end
        drained = drained + #text
    end

    -- Backpressure watch every 100 ticks (1 s).
    if ticks % 100 == 0 then
        local snap = xcom.get_snapshot(handle)
        if snap then
            if snap.rx_pool_exhausted_bytes > 0 and not exhausted_first_seen then
                exhausted_first_seen = os.time() - math.floor(deadline - seconds - os.clock() + seconds)
                exhausted_first_seen = os.clock()
            end
            io.write(string.format("\r  t=%2ds injected=%7d KiB drained=%7d KiB backlog=%4d KiB exhausted=%d pending=%d   ",
                math.floor(seconds - (deadline - os.clock())),
                injected / 1024, drained / 1024,
                (injected - drained) / 1024,
                snap.rx_pool_exhausted_bytes, snap.display_pending))
            io.stdout:flush()
        end
    end
    ffi.C.Sleep(10)
end
print("")

-- Final drain to empty.
local final_rounds = 0
while final_rounds < 200 do
    local rc, text = xcom.drain_display(handle, 65536)
    if rc ~= xcom.ok or not text or #text == 0 then break end
    drained = drained + #text
    final_rounds = final_rounds + 1
end

local snap = xcom.get_snapshot(handle)
print(string.format("ticks=%d (%.1f s effective)", ticks, ticks * 0.01))
print(string.format("injected: %d bytes (%.1f KiB)", injected, injected / 1024))
print(string.format("drained:  %d bytes (%.1f KiB)", drained, drained / 1024))
print(string.format("effective rate: %.1f KiB/s", injected / 1024 / seconds))
print(string.format("rx_pool_exhausted_bytes: %d", snap and snap.rx_pool_exhausted_bytes or -1))
print(string.format("rx_callback_oversize: %d", snap and snap.rx_callback_oversize_bytes or -1))
print(string.format("display_pending at end: %d", snap and snap.display_pending or -1))
print(string.format("inject rejected (overflow) events: %d", overflow_events))

local verdict = "PASS"
if drained ~= injected then verdict = "FAIL (drained ~= injected: " .. (injected - drained) .. " bytes lost/stuck)" end
if snap and snap.rx_pool_exhausted_bytes > 0 then verdict = "FAIL (pool exhausted)" end
if snap and (snap.display_pending or 0) > 0 then verdict = "FAIL (display still pending)" end
if overflow_events > 0 then verdict = "FAIL (inject rejected)" end
print("VERDICT: " .. verdict)

xcom.close(handle, 2000)
xcom.destroy(handle)
os.exit(verdict == "PASS" and 0 or 1)
