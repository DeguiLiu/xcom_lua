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
-- Stub for the ring/activity sections, which must not touch Win32 at all.  The
-- popup section further down replaces it with the real module.
package.loaded.win32 = { load = function() end }
local wave = require("waveform")
-- Same luv instance waveform resolved (nil on a host without luv, where
-- now_ms() falls back to os.clock and the plain busy wait is enough).
local ok_uv, uv_ref = pcall(require, "luv")
if not ok_uv then uv_ref = nil end

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

    -- Grace expiry.  now_ms() is uv.now() — the LOOP clock, refreshed by the
    -- uv_run("nowait") pass the app performs every frame (window.lua
    -- _pump_events).  A busy wait alone leaves it frozen (measured: 51 ms of
    -- os.clock moved uv.now() by 0), so the wait below has to pump the loop,
    -- exactly like the host, or this asserts against a stale clock.
    local t0 = os.clock()
    while (os.clock() - t0) < 0.05 do
        if uv_ref then uv_ref.run("nowait") end
    end
    ok("active false after grace elapsed", wave.active(20) == false)
    ok("idle_ms grows after wait", (wave.idle_ms() or 0) >= 20)

    -- clear() drops ownership: the reconciler hides the panel on the next frame.
    wave.clear()
    ok("clear resets active", wave.active() == false)
    ok("clear resets idle_ms", wave.idle_ms() == nil)
end

eq("snapshot without window errors", select(2, wave.snapshot()), "waveform window not visible")

-- ---- bmp_writer.save (the FFI path wave.snapshot actually uses) --------------
-- The pure-Lua builder above is fully covered, but `save` is what a snapshot
-- calls, and it shipped broken twice over: its `if jit and ffi` guard read a
-- GLOBAL ffi declared below it (every call answered "ffi unavailable", so no
-- file was ever written), and each row was written with row_bytes instead of
-- stride, producing a file shorter than the size its own header declares.
-- Width 3 is the case that exposes the second bug: 3*3 = 9 -> stride 12.
do
    local ffi = require("ffi")
    local w3 = 3
    local stride3 = 12
    -- Source is TOP-DOWN (as GDI hands it over): row 0 = red-ish, row 1 = green.
    local buf = ffi.new("uint8_t[?]", stride3 * 2)
    for i = 0, w3 * 3 - 1 do buf[i] = 0x11 end            -- top row: BGR 11 11 11
    for i = stride3, stride3 + w3 * 3 - 1 do buf[i] = 0x22 end  -- bottom: 22 22 22
    local path = (os.getenv("TEMP") or ".") .. "/xcom_bmp_writer_test.bmp"
    local saved, serr = bmp.save(path, w3, 2, buf, stride3)
    eq("save reports success", saved, true)
    ok("save error string empty", serr == nil, serr)
    local f = io.open(path, "rb")
    local data = f and f:read("*a")
    if f then f:close() end
    eq("saved file length == header + stride*height",
       data and #data or -1, 14 + 40 + stride3 * 2)
    ok("pixel data starts with the LAST source row (bottom-up)",
       data and data:sub(55, 55 + 8) == string.rep(string.char(0x22), 9),
       data and data:sub(55, 63))
    os.remove(path)
end

-- ---- GDI popup + BMP snapshot (Windows only) --------------------------------
-- wave.show()/wave.snapshot() are one chain of Win32 calls that shipped broken
-- at four separate points -- LoadCursorA raised on an FFI conversion error,
-- WM_NCCREATE fell through to DefWindowProcA(NULL) and cancelled the creation,
-- FillRect was resolved from gdi32 instead of user32, and WM_SIZE stored a
-- cdata width.  Each one masked the next, so assert the path end to end: a
-- window has to exist and a snapshot has to produce a file whose length equals
-- the size its own header declares.
if package.config:sub(1, 1) == "\\" then
    package.loaded.win32 = nil
    package.path = "./ui/?.lua;" .. package.path   -- ui/win32.lua
    local w_ok, w32 = pcall(require, "win32")
    if w_ok and w32.load then pcall(w32.load) end
    local shown, show_err = false, w32
    if w_ok then
        shown, show_err = pcall(function() return wave.show() end)
    end
    ok("show() creates the GDI popup", shown and wave.visible() == true,
       show_err)
    if shown and wave.visible() then
        local snap = (os.getenv("TEMP") or ".") .. "/xcom_wave_ring_snap.bmp"
        os.remove(snap)
        local got, snap_err = wave.snapshot(snap)
        eq("snapshot() names the file it wrote", got, snap)
        ok("snapshot() reported no error", snap_err == nil, snap_err)
        local f = io.open(snap, "rb")
        local data = f and f:read("*a")
        if f then f:close() end
        if data then
            local w_px = data:byte(19) + data:byte(20) * 256
            local h_px = data:byte(23) + data:byte(24) * 256
            local stride = math.floor((w_px * 3 + 3) / 4) * 4
            ok("snapshot header is sized", w_px > 100 and h_px > 100)
            eq("snapshot BMP length matches its own header", #data,
               14 + 40 + stride * h_px)
        else
            ok("snapshot file readable", false)
        end
        os.remove(snap)
        wave.hide()
    end
end

print(string.format("wave_ring: %d passed, %d failed", passed, failed))
if failed > 0 then os.exit(1) end
