-- test_wave_ring.lua - unit tests for the waveform ring math + BMP writer.
-- Pure Lua (no Win32): exercises the module-loadable parts only.
-- Usage: runtime\luvjit.exe tests\test_wave_ring.lua

package.path = "./core/?.lua;" .. package.path

local passed, failed = 0, 0
local function ok(label, cond)
    if cond then passed = passed + 1
    else failed = failed + 1; print("FAIL  " .. label) end
end
local function eq(label, got, want)
    ok(label .. " (got=" .. tostring(got) .. " want=" .. tostring(want) .. ")",
        got == want)
end

-- ---- BMP writer: pure-String builder ----------------------------------------
local bmp = require("bmp_writer")

-- 2x2 image, top-down rows [red, blue] / [green, yellow] in BGR bytes.
local rows = {
    "\0\0\255\255\0\0",    -- top:    red,  blue
    "\0\255\0\255\255\0",  -- bottom: green, yellow
}
local image = bmp.build_image(2, 2, rows)
-- stride = floor((2*3+3)/4)*4 = 8; data = 8*2 = 16; total = 14+40+16
eq("file size (stride-padded)", #image, 14 + 40 + 16)
-- 'BM' magic
eq("magic", image:sub(1, 2), "BM")
-- offset-to-bits = 54
eq("pixel offset", image:byte(11) + image:byte(12) * 256, 54)
-- bottom-up storage: the LAST source row (green/yellow) is stored FIRST
eq("bottom-up first pixel", image:sub(55, 57), "\0\255\0")       -- green
eq("bottom-up second pixel", image:sub(58, 60), "\255\255\0")    -- yellow
eq("top row second", image:sub(55 + 8, 55 + 8 + 2), "\0\0\255")  -- red
eq("pad byte", image:sub(61, 62), "\0\0")                        -- 2px pad to 8

-- odd width (3 px -> 9 bytes -> stride 12, 3 pad bytes)
local rows3 = { string.rep("\1", 9) }
local img3 = bmp.build_image(3, 1, rows3)
eq("odd width stride", #img3, 14 + 40 + 12)

-- ---- waveform ring: exercise via module internals through a fake state ------
-- The ring helpers are file-locals; test them indirectly by loading the
-- module and driving its public data API with a stubbed Win32 (no window is
-- created, so no GDI is touched).
package.loaded.win32 = { load = function() end }   -- never reached: show() not called
local wave = require("waveform")

wave.config({
    title = "test",
    series = { { name = "A", color = 0x112233 }, { name = "B", color = 0x445566 } },
})
ok("config two series", #wave._state_series() == 2)

wave.push(1, 100)          -- series index
wave.push("B", 200)        -- series name
wave.push("A", 150)
local counts = wave._state_counts()
eq("series A count", counts[1], 2)
eq("series B count", counts[2], 1)
local last = wave._state_last()
eq("series A last y", last[1], 150)
eq("series B last y", last[2], 200)

wave.clear()
counts = wave._state_counts()
eq("clear empties", counts[1], 0)

ok("bad series rejected", wave.push(99, 1) == false)
ok("named lookup works", wave.push("B", 7) == true)
ok("visible false without window", wave.visible() == false)

-- ---- waveform activity (scope auto-show ownership) --------------------------
-- The scope panel has no header chip: window.lua shows it while
-- wave.active() is true and hides it once the grace window elapses.  These
-- tests pin that contract (a script's push is the only visibility signal).
do
    -- Fresh module: the earlier block already pushed, so reset for a clean
    -- "never pushed" baseline.
    wave.clear()
    ok("active false before any push", wave.active() == false)
    ok("idle_ms nil before any push", wave.idle_ms() == nil)

    wave.push("A", 42)
    ok("active true right after push", wave.active() == true)
    ok("idle_ms small after push", (wave.idle_ms() or 1e9) < 100)
    -- A generous window must still report active.
    ok("active true with explicit window", wave.active(60000) == true)

    -- Grace expiry: busy-wait past a tiny window so the assertion is timing
    -- independent (os.clock granularity differs across hosts).
    local t0 = os.clock()
    while (os.clock() - t0) < 0.05 do end
    ok("active false after grace elapsed", wave.active(20) == false)
    ok("idle_ms grows after wait", (wave.idle_ms() or 0) >= 20)

    -- clear() drops ownership: the reconciler hides the panel on the next frame.
    wave.clear()
    ok("clear resets active", wave.active() == false)
    ok("clear resets idle_ms", wave.idle_ms() == nil)
end

eq("snapshot without window errors", select(2, wave.snapshot()), "waveform window not visible")

print(string.format("wave_ring: %d passed, %d failed", passed, failed))
if failed > 0 then os.exit(1) end
