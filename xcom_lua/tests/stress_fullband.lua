-- Full-bandwidth sustained-receive stress test (no UI).
--
-- Simulates 921600-baud line rate (~90 KiB/s) through the SAME rx_ingress
-- entry point the real serial callback uses (xcom_test_inject_rx), pumped at
-- the same 10 ms cadence the UI display poller would use.  Verifies the
-- data-loss contract end to end:
--   * every injected byte comes back out of drain_display exactly once,
--     modulo the display text-view's documented CRLF->LF normalisation
--     (xcom_ao.cpp: a CR emits one LF and consumes an adjacent LF WITHIN the
--     same rx block; the expected loss is counted exactly per inject below)
--   * rx_pool_exhausted_bytes stays 0 (the 512 KiB core pool never fills)
--   * display_pending drains to 0 within the poll budget
--
-- Usage: runtime\luajit.exe tests\stress_fullband.lua [seconds] [kib_per_s] [port]
--        port defaults to VIRTUAL (hardware-free in-process session); pass a
--        COM name explicitly to stress the same contract on real hardware.

local ffi = require("ffi")
ffi.cdef[[void Sleep(unsigned long ms);]]
local script = (arg and arg[0]) or "tests/stress_fullband.lua"
local tests_dir = script:match("^(.*)[/\\]") or "."
local root = tests_dir:gsub("[/\\]$", "") .. "/.."
package.path = root .. "/core/?.lua;" .. package.path
local xcom = require("xcom_ffi")

local seconds = tonumber(arg and arg[1]) or 30
local rate_kib = tonumber(arg and arg[2]) or 90  -- 921600 baud ~= 90 KiB/s
-- Port param (arg 3): default VIRTUAL -- xcom_core's hardware-free in-process
-- session (xcom_abi.cpp is_virtual_port: exact "VIRTUAL" or a "TEST" prefix).
-- open_async reaches port_open with no serial backend, and xcom_test_inject_rx
-- feeds the REAL rx_ingress -> display pipeline, so the full-bandwidth
-- data-loss contract is measurable on a headless host.  Try VIRTUAL first and
-- keep the classic COM candidate list as fallback order (an explicit COM name
-- takes the first slot, the rest still follow).
local port_arg = arg and arg[3]
local candidates = { "VIRTUAL" }
if port_arg and port_arg ~= "" and port_arg ~= "VIRTUAL" then
    candidates = { port_arg }
end
for _, p in ipairs({ "COM3", "COM4", "COM5", "COM2", "COM1" }) do
    if p ~= candidates[1] then candidates[#candidates + 1] = p end
end

local handle, err = xcom.create()
assert(handle, err)

-- A persistent port_state == open is required by inject_rx; the core accepts
-- inject only when OPEN.  VIRTUAL satisfies this with no hardware (in-process
-- session, skipped Win32 backend in sink_owner_open).  When a COM candidate
-- is tried instead, a failed open leaves the HSM CLOSED and we roll on.
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
    print("no port could be opened for injection (default VIRTUAL session failed); cannot run")
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
local FRAME_LINES = #frame   -- line numbers cycle 1..FRAME_LINES every frame
print(string.format("frame: %d bytes", #frame_text))

-- Sequence scanner: the drained stream must walk the line-number cycle in
-- order.  A frame wrap (FRAME_LINES -> 1) is legitimate; any other jump is a
-- missing/duplicate/reordered line.  Returns the running error count delta.
-- drain_display cuts the stream at arbitrary byte offsets, so a line header
-- ("[000088]" = 8 bytes) can straddle two chunks; carry the trailing 7 bytes
-- into the next scan (a full header never fits in a 7-byte tail, so an
-- already-counted header can never be re-seen, and payload has no '[' char).
local expect_line = nil    -- next expected frame line number (sequence check)
local first_seq_err = nil  -- first mismatch detail for the failure report
local sequence_error = 0   -- count of missing/duplicate/reordered lines seen
local seq_carry = ""       -- tail of the previous drained chunk (<=7 bytes)
local function scan_lines(text)
    local errs = 0
    local stream = seq_carry .. text
    local tail = #stream > 7 and stream:sub(-7) or ""
    for line_num in stream:gmatch("%[(%d+)%]") do
        local n = tonumber(line_num)
        if expect_line == nil then
            expect_line = n   -- first drained line seeds the sequence
        else
            local want = expect_line % FRAME_LINES + 1
            if n ~= want then
                errs = errs + 1
                if first_seq_err == nil then
                    first_seq_err = string.format(
                        "after line %d expected %d got %d", expect_line, want, n)
                end
            end
            expect_line = n
        end
    end
    seq_carry = tail
    return errs
end

-- Display text-view normalisation model (xcom_ao.cpp format_payload): a CR is
-- emitted as one LF and consumes an adjacent LF, so each "\r\n" pair costs one
-- display byte.  rx_ingress carves every injected payload into fresh 4096-byte
-- blocks (kRxBlockBytes) and formats each block independently, so a CR that
-- lands on the last byte of a block cannot fold with the next block's LF and
-- both bytes survive.  Losslessness is therefore
--     drained == injected - folded_pairs
-- with folded_pairs counted exactly, not estimated.  The payload is pure
-- printable ASCII + CRLF, so no other rule of the text view (ANSI strip,
-- control-byte drop) applies.
local RX_BLOCK_BYTES = 4096
local function folded_bytes(s)
    local n = 0
    local i = s:find("\r\n", 1, true)
    while i do
        if (i - 1) % RX_BLOCK_BYTES ~= RX_BLOCK_BYTES - 1 then
            n = n + 1
        end
        i = s:find("\r\n", i + 2, true)
    end
    return n
end
local frame_folded = folded_bytes(frame_text)

local per_tick_bytes = math.floor(rate_kib * 1024 * 10 / 1000)  -- per 10 ms tick
-- Granularity note: one frame is 9400 B, far above a 10 ms slice at 90 KiB/s
-- (921 B), so frames_per_tick floors to 1 and the actual injection is one
-- WHOLE frame per tick (~918 KiB/s at the default rate) — an intentional
-- over-stress, ~10x the nominal line rate.  The rate-floor assertion below
-- still checks against the nominal target; raise rate_kib on the CLI to
-- exercise higher rates deliberately.
local frames_per_tick = math.max(1, math.floor(per_tick_bytes / #frame_text))
local tick_remainder = per_tick_bytes - frames_per_tick * #frame_text

local injected, drained = 0, 0
local crlf_injected = 0    -- "\r\n" pairs fed in (folded to one LF by the text view)
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
    -- Same for the remainder bytes: a partial-frame prefix would re-inject
    -- "[000001]" at the tail of the previous line's payload and the sequence
    -- scanner below would misread it as a real line header.  Cut the prefix
    -- header off (start after the first \n) so only whole line headers appear.
    local rem_text = nil
    if tick_remainder > 0 then
        rem_text = frame_text:sub(1, tick_remainder)
        local nl = rem_text:find("\n", 1, true)
        if nl then rem_text = rem_text:sub(nl + 1) end
    end
    if rem_text then
        local rc = tonumber(xcom.test_inject_rx(handle, rem_text, #rem_text))
        if rc ~= xcom.ok then overflow_events = overflow_events + 1 end
    end
    injected = injected + frames_per_tick * #frame_text + (rem_text and #rem_text or 0)
    crlf_injected = crlf_injected + frames_per_tick * frame_folded
        + (rem_text and folded_bytes(rem_text) or 0)

    -- Same drain cadence/budget as poll_display: up to 8 x 64 KiB per tick.
    for _ = 1, 8 do
        local rc, text = xcom.drain_display(handle, 65536)
        if rc ~= xcom.ok or not text or #text == 0 then break end
        drained = drained + #text
        sequence_error = sequence_error + scan_lines(text)
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
    sequence_error = sequence_error + scan_lines(text)
    final_rounds = final_rounds + 1
end

local snap = xcom.get_snapshot(handle)
print(string.format("ticks=%d (%.1f s effective)", ticks, ticks * 0.01))
print(string.format("injected: %d bytes (%.1f KiB)", injected, injected / 1024))
print(string.format("drained:  %d bytes (%.1f KiB)", drained, drained / 1024))
print(string.format("crlf pairs folded (CRLF->LF text normalisation): %d bytes", crlf_injected))
print(string.format("line-sequence errors: %d (last line %s)%s",
                   sequence_error, expect_line and tostring(expect_line) or "none",
                   first_seq_err and (" first: " .. first_seq_err) or ""))
print(string.format("effective rate: %.1f KiB/s (target %d)", injected / 1024 / seconds, rate_kib))
print(string.format("rx_pool_exhausted_bytes: %d", snap and snap.rx_pool_exhausted_bytes or -1))
print(string.format("rx_callback_oversize: %d", snap and snap.rx_callback_oversize_bytes or -1))
print(string.format("display_pending at end: %d", snap and snap.display_pending or -1))
print(string.format("inject rejected (overflow) events: %d", overflow_events))

local expected_drained = injected - crlf_injected
local verdict = "PASS"
if drained ~= expected_drained then verdict = "FAIL (drained ~= injected-crlf_folded: " .. (expected_drained - drained) .. " bytes lost/stuck)" end
if sequence_error > 0 then verdict = "FAIL (" .. sequence_error .. " line-sequence errors)" end
-- Rate floor: Sleep(10) cadence can silently stretch (scheduler, GC), so
-- pin the effective injection rate to >= 80% of target — below that the
-- "full-band" claim is untested even if nothing was lost.
if injected / 1024 / seconds < rate_kib * 0.8 then
    verdict = string.format("FAIL (effective rate %.1f KiB/s < 80%% of target %d KiB/s)",
                            injected / 1024 / seconds, rate_kib)
end
if snap and snap.rx_pool_exhausted_bytes > 0 then verdict = "FAIL (pool exhausted)" end
if snap and (snap.display_pending or 0) > 0 then verdict = "FAIL (display still pending)" end
if overflow_events > 0 then verdict = "FAIL (inject rejected)" end
print("VERDICT: " .. verdict)

xcom.close(handle, 2000)
xcom.destroy(handle)
os.exit(verdict == "PASS" and 0 or 1)
