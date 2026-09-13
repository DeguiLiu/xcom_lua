-- test_rx_display_caps.lua - offline audit for the display-side enforcement
-- of [display] auto_clear_bytes ("自动清空") and frame_gap_ms ("自动断帧").
-- Usage: runtime\luvjit.exe tests/test_rx_display_caps.lua
--
-- Neither the C core nor the ImGui DLL acts on these two options:
--   * xcom_set_options (xcom_core/src/abi/xcom_abi.cpp) stores only
--     hex_view / timestamp / pause_display and DISCARDS auto_clear_bytes
--     (xcom.h even documents it as "trim threshold on the widget").
--   * the DLL keeps Lua-owned int buffers for the two sidebar widgets and
--     only renders them (xcom_imgui_bridge.cpp: frame_gap_en_/frame_gap_ms_,
--     auto_clear/auto_clear_bytes).
-- So Window:_process_rx_batch / Window:_append_imgui_receive in
-- ui/window.lua must enforce both, display-side.  This test drives the REAL
-- Window methods (same stubbing pattern as tests/test_send_file_caps.lua:
-- fake deps, manual clock injection) on a minimal instance built with
-- window.new() -- NO window/DLL/port needed.  window.new does not create
-- Win32 handles; without hwnd/build_ui the instance has no self.recv and
-- self.imgui stays nil unless a fake bridge is installed, which is exactly
-- the harness below.  Each fed chunk goes through the local feed() helper,
-- which force-flushes the whole-line bridge (design §2): a partial line is now
-- held until a frame boundary, and these cases assert the displayed result of
-- that boundary, not immediate partial display.
--
-- Asserts:
--   A) auto-clear OFF (0): the view accumulates across batches, no clear.
--   B) auto-clear boundary: view < threshold survives; the append whose
--      accumulated bytes REACH the threshold clears the view (chunks, tail,
--      dirty flag and the absolute _imgui_receive_total accumulator all
--      reset), and the empty push is what the fake bridge observed.
--   C) auto-clear re-arms after firing (second threshold distance -> second
--      clear), proving the accumulator was really reset, not just clamped.
--   D) the auto-save log path is unaffected: poll_display-style logic lives
--      outside these functions; the test pins that _append/_clear touch only
--      _imgui_* fields and self.imgui pushes.
--   E) frame-gap OFF: batches never get a separator, tail-open flag tracks.
--   F) frame-gap ON:
--      F1 exactly-at-threshold elapsed (== N ms) -> NO break (needs > N);
--      F2 over-threshold elapsed + open tail -> one synthetic "\n" chunk is
--         inserted BEFORE the batch (view ends "abc\ndef");
--      F3 over-threshold elapsed but the tail already ended at a newline ->
--         no duplicate blank line;
--      F4 batches drained inside one poll (same fake now) never break.
--   G) the gap break does NOT feed the auto-clear accumulator extra bytes
--      beyond what is displayed... it is displayed text, so it DOES count;
--      but a break must never trigger a clear on its own: threshold check
--      is the SAME single funnel (documented behaviour, pinned here).

package.path = "./ui/?.lua;./core/?.lua;" .. package.path

-- ---------------------------------------------------------------------------
-- Fake uv.now BEFORE requiring window.lua: window captures `require("luv")`
-- at load time, so the patch must already be installed.  uv.now is the
-- loop-cached monotonic clock; it only advances from uv.run(), which a
-- pure-logic test cannot drive, so elapsed gaps are made deterministic here.
-- luv is a Windows-runtime binary module, absent on the Linux review host, so
-- inject a minimal stub through package.preload (uv.now is all this pure
-- display path touches); win32.lua likewise refuses to load its DLLs off
-- Windows, so patch load() on the REAL module and stub the lazy kernel32 handle
-- it would otherwise touch.  Same harness as tests/test_rx_charset_batch.lua
-- and tests/test_rx_display_pipeline.lua.
-- ---------------------------------------------------------------------------
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

local window_mod = require("window")

local pass_n, fail_n = 0, 0
local function ok(label, cond)
    if cond then pass_n = pass_n + 1; print("PASS  " .. label)
    else fail_n = fail_n + 1; print("FAIL  " .. label) end
end
local function eq(label, got, want)
    ok(string.format("%s (got=%s want=%s)", label, tostring(got), tostring(want)),
       got == want)
end

-- Fake uv.now is installed ABOVE the require of window (see header); the
-- module captures the same mutable table, so patching it there takes hold.
local real_luv_unused = nil  -- placeholder to keep the history readable
local function new_fake_bridge()
    return {
        pushes = {},
        set_receive_text = function(self, text, base)
            self.pushes[#self.pushes + 1] = { text = text, base = base }
        end,
    }
end

-- Minimal instance: window.new fills the receive fields and seeds
-- _auto_clear_bytes / _frame_gap_ms from cfg.  charset default ASCII keeps
-- the funnel on its passthrough branch; scripts stay nil.
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
        charset = "ASCII", frame_gap_ms = 0,
    }
    for k, v in pairs(cfg_over or {}) do cfg[k] = v end
    local win = window_mod.new(cfg, { [""] = {} }, "_test.ini")
    win.imgui = new_fake_bridge()
    return win
end

-- View snapshot helpers ------------------------------------------------------
local function view_text(win)
    win:_flush_imgui_receive()
    return win._imgui_receive
end

-- Whole-line bridge (design §2): _process_rx_batch now holds an unterminated
-- tail across batches so scripts see whole lines, so a partial is only
-- displayed when a frame boundary forces it out.  These cases assert immediate
-- display of each fed chunk, so feed() emulates that boundary with the same
-- force-flush the idle/new-segment paths use.  It delivers exactly the bytes
-- the old immediate path displayed, so every counter/clear assertion is
-- unchanged.
local function feed(win, text)
    win:_process_rx_batch(text)
    win:_flush_rx_lines(false)
end

-- ===========================================================================
-- A) auto-clear disabled: plain accumulation, no clears
-- ===========================================================================
local w1 = new_fake_window({ auto_clear_bytes = 0 })
feed(w1,"hello ")
feed(w1,"world\n")
eq("A1 disabled: tail accumulates", view_text(w1), "hello world\n")
eq("A2 disabled: accumulator grows", w1._imgui_receive_total, 12)
eq("A3 disabled: no bridge pushes", #w1.imgui.pushes, 0)

-- ===========================================================================
-- B) threshold boundary: < threshold survives, == threshold clears
-- ===========================================================================
local w2 = new_fake_window({ auto_clear_bytes = 10 })
feed(w2,"123456789")            -- 9 < 10: keep
eq("B1 9/10 bytes: view kept", view_text(w2), "123456789")
eq("B2 9/10 bytes: no pushes", #w2.imgui.pushes, 0)
feed(w2,"0")                    -- 10 == 10: fire exactly at threshold
eq("B3 10/10 bytes: accumulator reset", w2._imgui_receive_total, 0)
eq("B4 10/10 bytes: retained tail cleared", w2._imgui_receive, "")
eq("B5 10/10 bytes: chunks cleared", #w2._imgui_receive_chunks, 0)
eq("B6 10/10 bytes: dirty cleared", w2._imgui_receive_dirty, false)
eq("B7 10/10 bytes: flush is a no-op", tostring(view_text(w2)), "")
local push = w2.imgui.pushes[1]
ok("B8 10/10 bytes: empty push reached the view",
   push and push.text == "" and #w2.imgui.pushes == 1)

-- A batch that crosses (overshoots) the threshold also clears, and display
-- continues from empty afterwards.
local w2b = new_fake_window({ auto_clear_bytes = 5 })
feed(w2b,"abcdefgh")            -- 8 > 5: overshoot clears too
eq("B9 crossed batch: view empty", w2b._imgui_receive_total, 0)
feed(w2b,"xyz")
eq("B10 continues after clear", view_text(w2b), "xyz")
eq("B11 post-clear accumulator counts fresh", w2b._imgui_receive_total, 3)
feed(w2b,"12")                  -- total 5 == threshold: fire
eq("B12 re-crossed: cleared again", w2b._imgui_receive_total, 0)

-- ===========================================================================
-- C) log path unaffected: the clear touches only view state
-- ===========================================================================
-- poll_display appends the RAW batch to the auto-save log BEFORE any display
-- call, so what matters is that the display functions mutate ONLY _imgui_*
-- fields / view flags / the bridge.  Drive _append_imgui_receive directly on
-- an instance carrying the persistence/counter fields and snapshot them
-- across a threshold fire.
local w3 = new_fake_window({ auto_clear_bytes = 4 })
w3._rx_bytes = 12345
w3._tx_bytes = 678
w3._log_active = true
w3.connected = true
w3.core = { fake = true }          -- any accidental core use would fault
w3._imgui_receive = "seed"
w3:_append_imgui_receive("abcd")   -- 4 >= 4: fires the clear
eq("C1 threshold cleared the view", w3._imgui_receive_total, 0)
eq("C2 rx counter untouched", w3._rx_bytes, 12345)
eq("C3 tx counter untouched", w3._tx_bytes, 678)
eq("C4 _log_active untouched", w3._log_active, true)
eq("C5 connected untouched", w3.connected, true)
ok("C6 no core interaction from display path",
   w3.core ~= nil and w3.core.fake == true)

-- ===========================================================================
-- D/E) frame-gap disabled: no separators ever
-- ===========================================================================
local w4 = new_fake_window({ auto_clear_bytes = 0, frame_gap_ms = 0 })
fake_now = 5000; feed(w4,"abc")
fake_now = 99000; feed(w4,"def")
eq("D1 gap disabled: halves glue together", view_text(w4), "abcdef")
eq("D2 gap disabled: anchor tracks open tail", w4._view_tail_open, true)
fake_now = 99999; feed(w4,"\n")
fake_now = 999999; feed(w4,"x")
eq("D3 gap disabled: still no break", view_text(w4), "abcdef\nx")
eq("D4 gap flag off keeps anchor timestamp unarmed", w4._rx_last_batch_ms, nil)

-- ===========================================================================
-- F) frame-gap enabled: break exactly when elapsed > N ms AND tail open
-- ===========================================================================
local w5 = new_fake_window({ auto_clear_bytes = 0, frame_gap_ms = 50 })
-- First batch: nothing precedes it, so no break regardless of `now`.
fake_now = 1000; feed(w5,"abc")
eq("F1 first batch: no break", view_text(w5), "abc")
-- Same fake now (two batches drained inside ONE poll_display round): even
-- with the flag on, elapsed 0 must not break.
fake_now = 1000; feed(w5,"X")
eq("F2 same-poll batch: no break", view_text(w5), "abcX")
-- Exactly at the threshold: 1050 - 1000 == 50, need strictly MORE.
fake_now = 1050; feed(w5,"Y")
eq("F3 elapsed == N: no break", view_text(w5), "abcXY")
-- One ms over: 1101 - 1050 = 51 > 50, tail open -> break before the batch.
fake_now = 1101; feed(w5,"def")
eq("F4 elapsed > N, open tail: break inserted", view_text(w5), "abcXY\ndef")
-- Tail now ends mid-line again; a gap arriving when the tail is CLOSED
-- (ends '\n') must NOT insert a duplicate blank line.
fake_now = 1101; feed(w5,"done\n")          -- same poll: no break
fake_now = 5000; feed(w5,"next")            -- big gap, tail closed
ok("F5 elapsed > N, closed tail: no break",
   view_text(w5):find("done\nnext", 1, true) ~= nil)
-- Mid-line tail + gap again -> second break.
fake_now = 9000; feed(w5,"!")
ok("F6 second gap: break again", view_text(w5):find("next\n!", 1, true) ~= nil)

-- ===========================================================================
-- G) the two features coexist: a gap break counts toward the display byte
--    accumulator (it is real display text) but can never trigger a clear by
--    itself unless the threshold is reached through the SAME funnel.
-- ===========================================================================
local w6 = new_fake_window({ auto_clear_bytes = 1000, frame_gap_ms = 20 })
fake_now = 1000; feed(w6,"aaaa")
fake_now = 2000; feed(w6,"bbbb")           -- break + bbbb
eq("G1 combined tail", view_text(w6), "aaaa\nbbbb")
eq("G2 accumulator counts break byte", w6._imgui_receive_total, 9)
eq("G3 far from threshold: no clear", w6._imgui_receive, "aaaa\nbbbb")

print(string.format("rx_display_caps: %d passed, %d failed", pass_n, fail_n))
os.exit(fail_n > 0 and 1 or 0)
