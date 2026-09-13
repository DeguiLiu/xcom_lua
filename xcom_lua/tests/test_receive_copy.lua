-- test_receive_copy.lua - unit tests for core/receive_copy.lua (pure Lua).
--
-- The receive log injects a fixed 15-byte "[HH:MM:SS.mmm] " prefix at the
-- start of every display segment (ui/window.lua rx_timestamp_prefix).  A user
-- who copies text out of the receive area wants the RAW bytes back, so the
-- copy path strips exactly that prefix before setting the clipboard.  These
-- tests call the real function (not a source grep) so a comment edit cannot
-- pass them.
--
-- Usage: /home/dgliu/.local/openresty/luajit/bin/luajit tests/test_receive_copy.lua

package.path = "./core/?.lua;../xcom_lua/core/?.lua;" .. package.path
local receive_copy = require("receive_copy")

local passed = 0
local failed = 0
local function eq(label, got, want)
    if got == want then
        passed = passed + 1
    else
        failed = failed + 1
        print(string.format("FAIL  %s  (got=%q want=%q)", tostring(label),
                            tostring(got), tostring(want)))
    end
end

local strip = receive_copy.strip_timestamps

-- 1) passthrough shapes
eq("empty string", strip(""), "")
eq("nil passthrough", strip(nil), nil)
eq("plain text", strip("hello world"), "hello world")
eq("empty line", strip("\n"), "\n")

-- 2) the exact injected prefix is removed, alone and per line
eq("line start", strip("[09:31:07.412] OK\n"), "OK\n")
eq("two stamped lines",
   strip("[09:31:07.412] A\n[09:31:07.413] B\n"), "A\nB\n")
eq("no trailing newline (prompt)", strip("[23:59:59.999] msh/g"), "msh/g")
eq("CRLF preserved", strip("[01:02:03.004] OK\r\n"), "OK\r\n")
eq("UTF-8 payload preserved", strip("[01:02:03.004] 温度=25\n"), "温度=25\n")

-- 3) a stamp glued mid-line (a segment boundary where the previous line had
--    no newline) is removed too: the option promises raw bytes, so every
--    exact prefix goes, not just the line-anchored ones.
eq("glued mid-line",
   strip("[09:31:07.412] ABC[09:31:07.413] DEF\n"), "ABCDEF\n")
eq("dense back-to-back",
   strip("[00:00:00.000] [00:00:00.001] x"), "x")
eq("stamp then only whitespace", strip("A[00:00:00.000] "), "A")

-- 4) near-miss shapes are payload, not stamps: the pattern is exact
eq("1-digit hour kept", strip("[9:31:07.412] x"), "[9:31:07.412] x")
eq("2-digit millis kept", strip("[09:31:07.41] x"), "[09:31:07.41] x")
eq("4-digit millis kept", strip("[09:31:07.4123] x"), "[09:31:07.4123] x")
eq("missing space kept", strip("[09:31:07.412]x"), "[09:31:07.412]x")
eq("plain log tag kept", strip("[INFO] booting"), "[INFO] booting")
eq("ISO date kept", strip("[2026-09-13] x"), "[2026-09-13] x")

-- 4b) DOCUMENTED TRADE-OFF of the opt-in option: the tool's stamp format is
--     indistinguishable from a device that emits the identical 15-byte
--     token, so an exact match anywhere is removed -- including inside a
--     device line.  This is why the option defaults to off; a user who turns
--     it on is asking for the raw payload and accepts the heuristic.
eq("exact device stamp also stripped (opt-in trade-off)",
   strip("at [12:00:00.000] done"), "at done")

-- 5) non-string scalar is passed through untouched (defensive; callers only
--    ever hand it a string).
eq("number passthrough", strip(42), 42)

print(string.format("\nreceive_copy tests: %d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
