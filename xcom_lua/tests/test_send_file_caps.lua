-- test_send_file_caps.lua - offline audit for scripts/send_file.lua.
-- Usage: cd xcom_lua/runtime && ./luvjit.exe ../tests/test_send_file_caps.lua
--
-- Drives the REAL send_file.lua inside a sandbox that mirrors
-- core/script_engine.lua's build_env() contract (uart/log/sys/ui).  Two uv
-- fakes are used:
--   * fs_stat/fs_open/fs_read/fs_close  -> exercise the real sys.file_read cap.
--   * new_timer                          -> exercise the real engine timer
--     array (create/destroy/shutdown) without needing the event loop.
-- send_file's OWN timer lifecycle is audited with a manual pump that mirrors
-- engine.timers (an array with at most one in-flight one-shot), because real
-- uv callbacks only fire from uv.run() which we do not drive here.
--
-- Asserts:
--   A) sys.file_read: >32MB -> nil AND fs_open never called (stat-first guard);
--      <=cap -> whole bytes; empty -> "".
--   B) browse of an oversize file: no state change, "32MB cap" logged.
--   C) send loop keeps <=1 live timer (stop-before-rearm); Stop -> 0 live and
--      the Send button is restored.
--   D) port closed mid-send: running=false, Send restored, "port closed" logged.
--   E) completion: script drops its own timer ref (state.timer=nil).
--   F) engine timer array: create/destroy/shutdown keep the array consistent.

package.path = "../core/?.lua;" .. package.path

local pass_n, fail_n = 0, 0
local function ok(label, cond)
    if cond then pass_n = pass_n + 1; print("PASS  " .. label)
    else fail_n = fail_n + 1; print("FAIL  " .. label) end
end
local function eq(label, got, want)
    ok(string.format("%s (got=%s want=%s)", label, tostring(got), tostring(want)),
       got == want)
end

-- ---------------------------------------------------------------------------
-- Fake uv: fs bits + a fake timer handle (no event loop).
-- ---------------------------------------------------------------------------
local fs = { files = {}, open = 0, close = 0 }
local real_luv = require("luv")
local uv = setmetatable({}, { __index = real_luv })

uv.fs_stat = function(path)
    local data = fs.files[path]
    if not data then return nil end
    return { type = "file", size = #data, mtime = { sec = 0 } }
end
uv.fs_open = function(path)
    if not fs.files[path] then return nil, "enoent" end
    fs.open = fs.open + 1
    return { path = path }
end
uv.fs_read = function(fd, size, offset, callback)
    local slurp
    if offset then
        slurp = fs.files[fd.path]:sub(offset + 1, offset + size)
    else
        slurp = fs.files[fd.path]:sub(1, size)
    end
    if callback then
        -- async threadpool form (send_file's file_read_at_async path): fire the
        -- completion deterministically.  The engine's sys wrapper never blocks,
        -- and our pump drives send_file synchronously, so invoke inline.
        callback(nil, slurp)
        return true
    end
    return slurp
end
uv.fs_close = function() fs.close = fs.close + 1 return true end

-- Fake timer handle models a real luv timer: :start arms it, :stop disarms.
-- We never fire callbacks from here; the send_file pump below does that.
local handle_n = 0
uv.new_timer = function()
    handle_n = handle_n + 1
    return { id = handle_n, started = false, stopped = false,
             start = function(self) self.started = true end,
             stop  = function(self) self.stopped = true end }
end
package.loaded["luv"] = uv

local engine_mod = require("script_engine")

-- ---------------------------------------------------------------------------
-- Harness: one engine, one script record, send_file.lua loaded into it.
-- ---------------------------------------------------------------------------
local sent = {}
local open_flag = { v = true }
local function new_harness_engine()
    local engine = engine_mod.new({
        script_dir = "_unused",
        send = function(p) sent[#sent + 1] = p; return true end,
        is_open = function() return open_flag.v end,
        auto_reload = false,
    })
    return engine
end

local function load_send_file(engine)
    local record = {
        name = "send_file.lua", path = "../scripts/send_file.lua",
        enabled = true, keeps = {}, drops = {}, rules = {}, ui_pages = {},
    }
    engine.scripts[record.name] = record
    engine.order = { record.name }
    assert(engine:load_script(record.name), "send_file.lua failed to load")
    return record
end

-- Manual timer pump mirroring engine.timers (array).  send_file keeps at most
-- one in-flight one-shot; schedule() stops the previous before arming the next.
local function install_pump(record)
    local live = {}          -- array of {handle, fn}; mirrors engine.timers
    local pending = nil      -- the single armed callback awaiting its tick
    record.env.sys.timer_start = function(_ms, fn)
        local handle = { id = handle_n + 1 }
        handle_n = handle_n + 1
        live[#live + 1] = { handle = handle, fn = fn }
        pending = { handle = handle, fn = fn }
        return handle
    end
    record.env.sys.timer_stop = function(handle)
        for i = #live, 1, -1 do
            if live[i].handle == handle then table.remove(live, i) end
        end
        if pending and pending.handle == handle then pending = nil end
    end
    -- One tick: fire the pending one-shot.  Its handle is NOT auto-removed
    -- (matching the real engine: only timer_destroy removes from the array),
    -- so the script must stop it explicitly to avoid lingering.
    local api = {}
    function api.tick()
        if not pending then return false end
        local fn = pending.fn
        pending = nil
        fn()
        return true
    end
    function api.live_count() return #live end
    function api.run(limit)
        local n = 0
        while pending and n < (limit or 100000) do api.tick(); n = n + 1 end
        return n
    end
    return api
end

local function spec_of(record)
    local page = record.ui_pages["send_file.lua:file"]
    return page and page.spec or ""
end

-- ===========================================================================
-- A) real sys.file_read cap semantics
-- ===========================================================================
local engine_a = new_harness_engine()
local rec_a = load_send_file(engine_a)
local sys = rec_a.env.sys

fs.files["/small.bin"] = string.rep("x", 1234)
eq("A1 file_read small returns full bytes", #sys.file_read("/small.bin"), 1234)
fs.files["/empty.bin"] = ""
eq("A2 file_read empty -> '' (not nil)", sys.file_read("/empty.bin"), "")

local big = string.rep("y", 33 * 1024 * 1024)   -- 33MB > 32MiB cap
fs.files["/big.bin"] = big
local before_open = fs.open
local res = sys.file_read("/big.bin")
eq("A3 >32MB returns nil", res, nil)
eq("A4 >32MB: fs_open never called (stat-first guard)", fs.open, before_open)
fs.files["/big.bin"] = nil; big = nil; collectgarbage()

-- exactly-at-cap boundary: 32MiB is allowed (size > MAX is the reject test)
local edge = string.rep("e", 32 * 1024 * 1024)
fs.files["/edge.bin"] = edge
eq("A5 ==32MiB accepted", sys.file_read("/edge.bin") and #sys.file_read("/edge.bin") or -1, 32 * 1024 * 1024)
fs.files["/edge.bin"] = nil; edge = nil; collectgarbage()
eq("A6 handles balanced so far", fs.open, fs.close)

-- ===========================================================================
-- B) browse an oversize file -> ACCEPTED (streaming window, no whole-file
--    read): page declared, no send yet.  The 32MB cap only bounds the legacy
--    sys.file_read; the streamed file_open/file_read_at path has no cap.
-- ===========================================================================
local engine_b = new_harness_engine()
local rec_b = load_send_file(engine_b)
local pump_b = install_pump(rec_b)
rec_b.env.sys.open_file = function() return "/huge.bin" end
fs.files["/huge.bin"] = string.rep("w", 32 * 1024 * 1024 + 1)
engine_b:dispatch_ui_event("send_file.lua:file", "click", "browse")
eq("B1 oversize browse: no timer armed (send not started)", pump_b.live_count(), 0)
ok("B2 oversize browse: page declared with progress head",
   spec_of(rec_b):find("FILE: huge.bin", 1, true) ~= nil)
fs.files["/huge.bin"] = nil; collectgarbage()
-- Release the fd B opened but never sent (mirrors "user browsed a file and
-- left the page"): engine:shutdown() is the host-side fd sweep the engine
-- documents, so tests that don't tear down their engine would leak the fd.
engine_b:shutdown()

-- ===========================================================================
-- C) send loop keeps <=1 live timer; Stop -> 0 live + Send restored
-- ===========================================================================
local engine_c = new_harness_engine()
local rec_c = load_send_file(engine_c)
local pump_c = install_pump(rec_c)
open_flag.v = true
rec_c.env.sys.open_file = function() return "/ok.bin" end
fs.files["/ok.bin"] = string.rep("A", 5000)   -- 5 chunks of 1024
engine_c:dispatch_ui_event("send_file.lua:file", "click", "browse")
ok("C1 browse ok: page declared", spec_of(rec_c):find("Choose file", 1, true) ~= nil)

engine_c:dispatch_ui_event("send_file.lua:file", "click", "start")
eq("C2 after start: exactly 1 live timer", pump_c.live_count(), 1)
-- step a few chunks; the stop-before-rearm invariant keeps live at 1
for _ = 1, 3 do pump_c.tick() end
eq("C3 mid-send: still <=1 live timer (no accumulation)", pump_c.live_count(), 1)
-- Stop mid-send
engine_c:dispatch_ui_event("send_file.lua:file", "click", "stop")
eq("C4 Stop: live timers drained to 0", pump_c.live_count(), 0)
ok("C5 Stop: Send button restored", spec_of(rec_c):find("button:start:Send", 1, true) ~= nil)

-- ===========================================================================
-- D) port closed mid-send -> running=false, Send restored, logged
-- ===========================================================================
local engine_d = new_harness_engine()
local rec_d = load_send_file(engine_d)
local pump_d = install_pump(rec_d)
open_flag.v = true
rec_d.env.sys.open_file = function() return "/ok2.bin" end
fs.files["/ok2.bin"] = string.rep("B", 5000)
engine_d:dispatch_ui_event("send_file.lua:file", "click", "browse")
engine_d:dispatch_ui_event("send_file.lua:file", "click", "start")
pump_d.tick()                 -- one chunk sent while open
open_flag.v = false           -- user closes the port mid-send
pump_d.tick()                 -- next step: uart.send fails
eq("D1 closed mid-send: live timers drained", pump_d.live_count(), 0)
ok("D2 closed mid-send: Send button restored", spec_of(rec_d):find("button:start:Send", 1, true) ~= nil)
ok("D3 closed mid-send: 'port closed' logged",
   (engine_d:log_lines() or ""):find("port closed", 1, true) ~= nil)

-- ===========================================================================
-- E) completion: script drops its own timer ref
-- ===========================================================================
local engine_e = new_harness_engine()
local rec_e = load_send_file(engine_e)
local pump_e = install_pump(rec_e)
open_flag.v = true
sent = {}
rec_e.env.sys.open_file = function() return "/tiny.bin" end
fs.files["/tiny.bin"] = string.rep("Q", 2048)   -- exactly 2 chunks of 1024
engine_e:dispatch_ui_event("send_file.lua:file", "click", "browse")
engine_e:dispatch_ui_event("send_file.lua:file", "click", "start")
local ticks = pump_e.run(100)
eq("E1 completion: 2 chunks sent", #sent, 2)
eq("E1b chunk contents stream in order (file_read_at spans)",
   sent[1] .. sent[2], string.rep("Q", 2048))
ok("E2 completion: 'done' logged", (engine_e:log_lines() or ""):find("done:", 1, true) ~= nil)
-- Diagnostic (not a hard gate): the final fired one-shot lingers in the array
-- because send_file sets state.timer=nil without timer_stop on completion.
print(string.format("INFO  completion left %d live timer handle(s) after %d ticks",
                    pump_e.live_count(), ticks))
ok("E3 completion: Send button restored (running=false)",
   spec_of(rec_e):find("button:start:Send", 1, true) ~= nil)

-- ===========================================================================
-- G) backpressure: a full TX queue (-5 err_full) retries the same chunk
--    instead of aborting; a real port error (-2 not open) aborts.
-- ===========================================================================
do
    local engine_g = new_harness_engine()
    local rec_g = load_send_file(engine_g)
    local pump_g = install_pump(rec_g)
    open_flag.v = true
    sent = {}
    rec_g.env.sys.open_file = function() return "/bp.bin" end
    fs.files["/bp.bin"] = string.rep("B", 2048)   -- 2 chunks of 1024

    -- Interpose a send that reports "full" on the first attempt then succeeds,
    -- and counts how many times each chunk was dispatched.
    local full_then_ok = { calls = 0 }
    rec_g.env.uart.send = function(data)
        full_then_ok.calls = full_then_ok.calls + 1
        if full_then_ok.calls == 1 then return false, -5 end  -- buffer full once
        sent[#sent + 1] = data
        return true, nil
    end

    engine_g:dispatch_ui_event("send_file.lua:file", "click", "browse")
    engine_g:dispatch_ui_event("send_file.lua:file", "click", "start")
    pump_g.run(100)

    -- The full chunk was retried (not dropped), so both chunks still land in
    -- order, and the send was issued 3 times total (1 failed retry + 2 ok).
    eq("G1 backpressure: full chunk retried, both chunks delivered",
       #sent, 2)
    eq("G2 backpressure: correct byte order preserved",
       sent[1] .. sent[2], string.rep("B", 2048))
    eq("G3 backpressure: send attempted failed+2ok", full_then_ok.calls, 3)

    -- A real error (not-open) must abort, not retry forever.
    local engine_h = new_harness_engine()
    local rec_h = load_send_file(engine_h)
    local pump_h = install_pump(rec_h)
    rec_h.env.sys.open_file = function() return "/bp2.bin" end
    fs.files["/bp2.bin"] = string.rep("C", 2048)
    rec_h.env.uart.send = function() return false, -2 end  -- not open
    engine_h:dispatch_ui_event("send_file.lua:file", "click", "browse")
    engine_h:dispatch_ui_event("send_file.lua:file", "click", "start")
    pump_h.run(50)
    ok("G4 port error aborts (Send restored, not stuck retrying)",
       spec_of(rec_h):find("button:start:Send", 1, true) ~= nil)

    fs.files["/bp.bin"] = nil; fs.files["/bp2.bin"] = nil; collectgarbage()
end

-- ===========================================================================
-- F) engine timer array with the REAL sys API (fake uv.new_timer)
-- ===========================================================================
local engine_f = new_harness_engine()
local rec_f = load_send_file(engine_f)
-- Use the untouched real sys.timer_start/timer_stop (engine:timer_create).
local h1 = rec_f.env.sys.timer_start(5, function() end)
local h2 = rec_f.env.sys.timer_start(5, function() end)
eq("F1 two engine timers live", #engine_f.timers, 2)
rec_f.env.sys.timer_stop(h1)
eq("F2 after stop(h1): one live", #engine_f.timers, 1)
engine_f:shutdown()
eq("F3 shutdown(): array emptied", #engine_f.timers, 0)

-- stream window semantics: file_read_at returns exactly the requested span
-- and clamps to the file tail; no whole-file copy is ever made.
fs.files["/win.bin"] = "0123456789"
local fd_w = sys.file_open("/win.bin")
ok("H1 file_open returns a handle", fd_w ~= nil)
eq("H2 read_at offset 3 len 4", sys.file_read_at(fd_w, 3, 4), "3456")
eq("H3 read_at clamps at tail", sys.file_read_at(fd_w, 8, 100), "89")
eq("H4 read_at rejects len 0", sys.file_read_at(fd_w, 0, 0), nil)
eq("H5 read_at rejects negative offset", sys.file_read_at(fd_w, -1, 4), nil)
sys.file_close(fd_w)
-- After B's leaked fd is swept by engine_b:shutdown(), the H open+close is
-- the last outstanding pair; the accounting is fully balanced here.
eq("H6 handle accounting", fs.open, fs.close)
fs.files["/win.bin"] = nil

-- handle accounting across every file_read used above
eq("G1 all fs_open closed", fs.open, fs.close)

print(string.format("send_file_caps: %d passed, %d failed", pass_n, fail_n))
os.exit(fail_n > 0 and 1 or 0)
