-- test_rx_display_pipeline.lua - offline regression for the receive-display
-- pipeline redesign (docs/design-rx-display-pipeline.md §4, Lua half).
--
-- What is pinned here:
--   1. RX is NOT written to the log by Lua.  Persistence belongs to the core's
--      raw-byte lane; the old window.lua log_append calls wrote every byte
--      twice.  The TX echo still logs (the raw lane carries RX only), so it is
--      asserted too.
--   2. Scripts receive WHOLE lines: a partial line is held across drain batches
--      and delivered exactly once, joined, when its LF arrives.
--   3. A never-terminated line is force-flushed at the 4 KiB cap instead of
--      being held forever.
--   4. Pipeline order: the charset stage (④) converts first, the script stage
--      (⑤) sees UTF-8 / LF / NO timestamp, and the timestamp (⑥) is applied
--      afterwards.
--   5. Timestamp is segment-scoped: one stamp only when the batch gap reaches
--      the threshold; with no xcom_drain_display_ts export stamping is DISABLED
--      (never stamped with the wrong clock).
--   6. A raising script hook is counted + surfaced and the batch is still
--      shown, not silently dropped.
--
-- Offline (no port / DLL / Win32): drives the REAL Window methods on a minimal
-- window.new() instance with a fake bridge, exactly like
-- tests/test_rx_charset_batch.lua.  Conversion is stubbed to the documented
-- charset contract (DB6 D0 -> UTF-8 中); the C++ line normaliser is simulated
-- by feeding LF-only text, since ③ folds CRLF before Lua ever sees it.
--
-- Usage: luajit tests/test_rx_display_pipeline.lua   (from the repo root)

package.path = "./ui/?.lua;./core/?.lua;" .. package.path

local fake_now = 1000000
package.preload["luv"] = function()
    return { now = function() return fake_now end }
end
local uv = require("luv")
uv.now = function() return fake_now end

local real_win32 = require("win32")
real_win32.load = function() return true end
real_win32.kernel32 = setmetatable({}, {
    __index = function() return function() return 0 end end,
})

local charset = require("charset")
-- Mirror dbcs_to_utf8's documented contract.  The window's own "hold the batch
-- on nil" behaviour is covered by test_rx_charset_batch; here the stub only
-- needs to turn the synthetic GB2312 bytes into UTF-8.
function charset.convert(text)
    if not text or #text == 0 then return text end
    return (text:gsub("\214\208", "\228\184\173"))
end
charset.reset = function() end
charset.flush = function() return nil end

local window_mod = require("window")
local xcom = require("xcom_ffi")

local pass_n, fail_n = 0, 0
local function ok(label, cond)
    if cond then pass_n = pass_n + 1; print("PASS  " .. label)
    else fail_n = fail_n + 1; print("FAIL  " .. label) end
end
local function eq(label, got, want)
    ok(string.format("%s (got=%q want=%q)", label, tostring(got), tostring(want)),
       got == want)
end

local function new_fake_window(cfg_over)
    local cfg = {
        window = { x = 0, y = 0, w = 920, h = 650 },
        port = "", baud_rate = 115200, data_bits = 8, stop_bits = 0,
        parity = 0, flow_control = 0, dtr_enable = false, rts_enable = false,
        receive_hex = false, timestamp = false, pause_display = false,
        auto_clear_bytes = 0, max_display_bytes = 2 * 1024 * 1024,
        auto_save = false, save_path = "", always_on_top = false,
        send_hex = false, send_crlf = false, autosend_period_ms = 0,
        quick_pages = { { text = {}, enabled = {} } },
        quick = { text = {}, enabled = {} },
        script_enabled = {}, script_auto_reload = false,
        script_autorun_console = false, baud_custom = 0, multi_gap_ms = 100,
        charset = "ASCII", frame_gap_ms = 0, tx_echo = true,
    }
    for k, v in pairs(cfg_over or {}) do cfg[k] = v end
    local win = window_mod.new(cfg, { [""] = {} }, "_test.ini")
    win.imgui = {
        pushes = {},
        set_receive_text = function(self, text)
            self.pushes[#self.pushes + 1] = text
        end,
    }
    return win
end

local function view_text(win)
    win:_flush_imgui_receive()
    return win._imgui_receive
end

-- Count "HH:MM:SS.mmm" prefixes in a view string.
local function stamp_count(text)
    local n = 0
    for _ in text:gmatch("%[%d%d:%d%d:%d%d%.%d%d%d%] ") do n = n + 1 end
    return n
end

-- ===========================================================================
-- 1) RX is not logged by Lua; the TX echo still is.
-- ===========================================================================
do
    local w = new_fake_window()
    w.core = { fake = true }
    w.connected = true
    w._log_active = true
    local saved_ts, saved_append = xcom.drain_display_ts, xcom.log_append
    local logged = {}
    local queue = { { xcom.ok, "hello\n", 1000, true },
                    { xcom.ok, "world\n", 1300, true } }
    local di = 0
    xcom.drain_display_ts = function()
        di = di + 1
        local d = queue[di]
        if d then return d[1], d[2], d[3], d[4] end
        return xcom.ok, nil, nil, true
    end
    xcom.log_append = function(_, text) logged[#logged + 1] = text; return xcom.ok end
    w:poll_display()
    eq("1a RX path makes zero log_append calls", #logged, 0)
    w:_echo_tx("hi")
    eq("1b TX echo still logs (one line)", #logged, 1)
    eq("1c TX log line", logged[1], "TX: hi\n")
    xcom.drain_display_ts, xcom.log_append = saved_ts, saved_append
end

-- ===========================================================================
-- 2) Whole lines: "PART" is held; "PARTIAL\n" is delivered exactly once.
-- ===========================================================================
do
    local w = new_fake_window({ charset = "ASCII" })
    local calls = {}
    w.scripts = {
        process_rx = function(_, text) calls[#calls + 1] = text; return text end,
    }
    w:_process_rx_batch("PART")
    eq("2a partial line: hook not called yet", #calls, 0)
    w:_process_rx_batch("IAL\n")
    eq("2b completed line: hook called once", #calls, 1)
    eq("2c hook received the joined whole line", calls[1], "PARTIAL\n")
end

-- ===========================================================================
-- 3) Cap flush: a 5 KiB unterminated line is delivered, not held forever.
-- ===========================================================================
do
    local w = new_fake_window({ charset = "ASCII" })
    local calls = {}
    w.scripts = {
        process_rx = function(_, text) calls[#calls + 1] = text; return text end,
    }
    local big = string.rep("x", 5 * 1024)   -- no LF anywhere
    w:_process_rx_batch(big)
    eq("3a cap flush calls the hook", #calls, 1)
    eq("3b the whole held line was delivered", #calls[1], #big)
    ok("3c forced-flush counter incremented", w._rx_line_forced >= 1)
    eq("3d nothing left pending", w._rx_line_pending, "")
end

-- ===========================================================================
-- 4) Order: charset (④) -> script (⑤, pure UTF-8/LF, no stamp) -> timestamp (⑥).
-- ===========================================================================
do
    local w = new_fake_window({ charset = "GB2312", timestamp = true })
    w._charset_active = true
    local calls = {}
    w.scripts = {
        process_rx = function(_, text) calls[#calls + 1] = text; return text end,
    }
    w:_process_rx_batch("\214\208\n", 1000, true)   -- 中 + LF (③ already folded)
    eq("4a script saw UTF-8, not GB2312", calls[1], "\228\184\173\n")
    ok("4b script saw no timestamp prefix", not calls[1]:find("[", 1, true))
    eq("4c the viewport DID get exactly one timestamp", stamp_count(view_text(w)), 1)
end

-- ===========================================================================
-- 5) Timestamp is segment-scoped, and absent when the export is unavailable.
-- ===========================================================================
do
    local w = new_fake_window({ charset = "ASCII", timestamp = true })
    w:_process_rx_batch("one\n", 1000, true)     -- first batch: segment opens
    w:_process_rx_batch("two\n", 1100, true)     -- gap 100 < 200: no stamp
    w:_process_rx_batch("three\n", 1400, true)   -- gap 300 >= 200: new segment
    eq("5a below-threshold batch not stamped; two segments stamped",
       stamp_count(view_text(w)), 2)

    local w2 = new_fake_window({ charset = "ASCII", timestamp = true })
    w2:_process_rx_batch("no-clock\n", nil, false)   -- older DLL: no export
    eq("5b fallback disables stamping", stamp_count(view_text(w2)), 0)
    ok("5c fallback notice emitted once", w2._rx_ts_notice_given == true)
    w2:_process_rx_batch("again\n", nil, false)
    ok("5d fallback stays quiet on later batches", w2._rx_ts_notice_given == true)
end

-- ===========================================================================
-- 6) A raising script hook is visible, counted, and does not drop the batch.
-- ===========================================================================
do
    local w = new_fake_window({ charset = "ASCII" })
    w.scripts = {
        process_rx = function() error("boom") end,
    }
    w:_process_rx_batch("data\n")
    eq("6a failing batch is still shown", view_text(w), "data\n")
    eq("6b failure counted", w._rx_funnel_errors, 1)
    ok("6c failure surfaced on the status line",
       type(w._status_dirty) == "string" and w._status_dirty:find("funnel", 1, true) ~= nil)
end

-- ===========================================================================
-- 7) Idle flush: a held partial line is delivered once the segment-gap
--    interval passes with no new batch (a device that does not delimit frames).
-- ===========================================================================
do
    local w = new_fake_window({ charset = "ASCII" })
    local calls = {}
    w.scripts = {
        process_rx = function(_, text) calls[#calls + 1] = text; return text end,
    }
    w.core = { fake = true }
    w.connected = true
    local saved = xcom.drain_display_ts
    xcom.drain_display_ts = function() return xcom.ok, nil, nil, true end
    fake_now = 1000000
    w:_process_rx_batch("BIN")                  -- held partial, no LF
    eq("7a held until the idle gap", #calls, 0)
    fake_now = fake_now + w._timestamp_gap_ms - 1
    w:poll_display()                            -- just under threshold: held
    eq("7b below threshold: still held", #calls, 0)
    fake_now = fake_now + 1                     -- exactly at the threshold
    w:poll_display()
    eq("7c idle gap flushes the held partial", #calls, 1)
    eq("7d delivered whole", calls[1], "BIN")
    eq("7e pending cleared", w._rx_line_pending, "")
    w:poll_display()                            -- nothing left to flush
    eq("7f not re-emitted", #calls, 1)
    xcom.drain_display_ts = saved
end

print(string.format("rx_display_pipeline: %d passed, %d failed", pass_n, fail_n))
os.exit(fail_n > 0 and 1 or 0)
