-- test_rx_charset_batch.lua - RED/GREEN regression for display-path garbling
-- when a multi-byte character straddles the 10 ms drain-batch boundary.
--
-- Symptom (user report): occasional garbage in the receive area with correct
-- serial parameters.  Root cause candidate A: charset.convert() is called
-- per drained batch; a DBCS lead byte at the tail of batch N is HELD PENDING
-- (convert returns nil) until its trail byte arrives in batch N+1.  The
-- window.lua call site was `charset.convert(text) or text`, so the "nil =
-- everything held" sentinel was coerced into "display the RAW held bytes" —
-- emitting the lone lead byte (e.g. 0xD6) straight into the UTF-8 view, where
-- it is an invalid sequence.  Two batches torn mid-character thus leak one
-- garbage byte per split.
--
-- The fix belongs in the CALL SITE (window.lua), not the converter: the
-- converter's nil = "nothing displayable yet, hold" contract is correct
-- (see tests/test_charset.lua section 6).  A display-side `or text` breaks it.
--
-- Offline (no port / DLL / Win32): drives the REAL Window:_process_rx_batch
-- on a minimal window.new() instance with a fake bridge, exactly like
-- tests/test_rx_display_caps.lua.  Conversion itself is stubbed (kernel32 is
-- unavailable on Linux): the stub mirrors charset.lua's documented contract
-- (nil while bytes are pending, string once a batch completes a character).
--
-- Usage: luajit tests/test_rx_charset_batch.lua   (from the repo root)

package.path = "./ui/?.lua;./core/?.lua;" .. package.path

-- uv.now must be patched BEFORE window.lua is required (it captures luv at
-- load time).  Deterministic clock: no gap break will fire (frame_gap off).
-- luv is a Windows-runtime binary module, absent on the Linux review host, so
-- inject a minimal stub into package.preload (uv.now is all this path uses).
local fake_now = 1000000
package.preload["luv"] = function()
    return { now = function() return fake_now end }
end
local uv = require("luv")

-- win32.lua refuses to load its DLLs off Windows; the real module's cdef +
-- constants are platform-independent, so patch load() on the REAL module
-- (window.new only calls w.load() and w.kernel32.GetModuleHandleA, neither of
-- which this pure display path uses) and stub the two lazy handles.
local real_win32 = require("win32")
real_win32.load = function() return true end
real_win32.kernel32 = setmetatable({}, {
    __index = function() return function() return 0 end end,
})

local charset = require("charset")

-- Stub the converter to the DOCUMENTED contract without touching kernel32:
-- mirror dbcs_to_utf8 — hold a TRAILING dangling lead byte (0xD6) pending and
-- return nil when a batch is entirely held.  We assert on the WINDOW call
-- site, not on charset.lua (whose own split behaviour test_charset.lua
-- already covers); this only needs to reproduce the nil-versus-text signal.
local pending_raw = ""
function charset.convert(text)
    if not text or #text == 0 then return text end
    local data = pending_raw .. text
    pending_raw = ""
    if data:byte(-1) == 0xD6 then          -- dangling lead: hold it back
        pending_raw = data:sub(-1)
        data = data:sub(1, #data - 1)
        if #data == 0 then return nil end  -- whole batch held
    end
    -- "中" = D6 D0 -> UTF-8 E4 B8 AD; other bytes verbatim
    return (data:gsub("\214\208", "\228\184\173"))
end
charset.reset = function() pending_raw = "" end
charset.flush = function()
    if pending_raw == "" then return nil end
    local held = pending_raw
    pending_raw = ""
    return held   -- orphan lead shown as-is (code page default in the real one)
end

local window_mod = require("window")

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
        charset = "GB2312", frame_gap_ms = 0,
    }
    for k, v in pairs(cfg_over or {}) do cfg[k] = v end
    local win = window_mod.new(cfg, { [""] = {} }, "_test.ini")
    win.imgui = {
        pushes = {},
        set_receive_text = function(self, text)
            self.pushes[#self.pushes + 1] = text
        end,
    }
    win._charset_active = true   -- force the conversion branch (GB2312)
    return win
end

local function view_text(win)
    win:_flush_imgui_receive()
    return win._imgui_receive
end

-- ===========================================================================
-- 1) DBCS character torn across two drain batches: lead byte ends batch 1,
--    trail byte opens batch 2.  Batch 1 must display NOTHING (held pending),
--    batch 2 must display the fully converted character.
-- ===========================================================================
charset.reset()
local w = new_fake_window()
w:_process_rx_batch("A\214")      -- 'A' + lead of 中 (D6 D0): D6 held
eq("1a torn batch1: hold, no raw leak", view_text(w), "A")
w:_process_rx_batch("\208B")      -- trail D0 completes 中, then 'B'
eq("1b torn batch2: completed -> utf8", view_text(w), "A\228\184\173B")

-- ===========================================================================
-- 2) Whole batch is a single held lead byte -> nothing may be displayed.
--    (Before the fix the `or text` leaked the raw D6 into the view.)
-- ===========================================================================
charset.reset()
local w2 = new_fake_window()
w2:_process_rx_batch("\214")
eq("2a fully-held batch: no raw leak", view_text(w2), "")
eq("2b fully-held batch: bridge untouched", #w2.imgui.pushes, 0)

-- ===========================================================================
-- 3) Passthrough (ASCII/UTF-8) must be unaffected: convert returns the same
--    string, never nil, so nothing is held.
-- ===========================================================================
charset.reset()
local w3 = new_fake_window({ charset = "ASCII" })
w3._charset_active = false
w3:_process_rx_batch("plain ascii\n")
eq("3 pass: ascii flows through", view_text(w3), "plain ascii\n")

-- ===========================================================================
-- 4) Close-path flush: a character torn at the FINAL batch boundary must not
--    stay held forever.  _final_drain calls charset.flush() and appends the
--    orphan bytes.  Drive it with a fake core whose drain returns empty.
-- ===========================================================================
charset.reset()
local w4 = new_fake_window()
w4:_process_rx_batch("\214")           -- lone lead held pending
eq("4a pending held: view empty", view_text(w4), "")
local xcom = require("xcom_ffi")
local saved_drain = xcom.drain_display
xcom.drain_display = function() return xcom.ok, nil end   -- core empty
w4.core = { fake = true }
w4:_final_drain()
xcom.drain_display = saved_drain
eq("4b flush emits the held byte", view_text(w4), "\214")
ok("4c flush re-armed (nothing stays pending)",
   (charset.flush()) == nil)

print(string.format("rx_charset_batch: %d passed, %d failed", pass_n, fail_n))
os.exit(fail_n > 0 and 1 or 0)
