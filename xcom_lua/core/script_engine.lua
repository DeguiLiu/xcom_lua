--[[--------------------------------------------------------------------------
core/script_engine.lua - user Lua script engine (LLCOM-inspired, adapted).

Trusted-local-script model: scripts in <app>/scripts/*.lua are user code the
same way the app itself is Lua — there is no security sandbox, only FAULT
ISOLATION so a broken script can never kill the host:

  * every hook dispatch runs inside pcall;
  * a hook that fails 3 times in a row is auto-disabled with a visible log
    line (re-enabling the script resets the strike counter);
  * script-owned sys timers are created through the engine so shutdown()
    stops them all;
  * JIT is on by default; each C->Lua entry (WndProc / the luv timers that
    drive dispatch) carries its own jit.off(fn, true), so hooks run on an
    already-interpreted call tree and a broken script cannot trip the
    traced-C-reentry panic.

Script environment (one shared table per script, fresh per (re)load):

  uart.send(data)          send raw bytes/latin1 string to the port
  uart.send_hex("01 A2")   send a hex string (spaces optional)
  uart.is_open()           port currently connected?
  on.receive(fn)           recv-convert hook: fn(text) -> text'|nil  (nil drops
                           the batch from DISPLAY only — the auto-save log
                           still records the raw bytes)
  on.send(fn)              send-convert hook: fn(payload) -> payload'|nil
                           (nil aborts the send)
  filter.keep(...)         keep only lines containing any pattern (plain find)
  filter.drop(...)         drop lines containing any pattern
  filter.clear()           remove all rules from THIS script
  highlight.rule(p, color, style)
                           color = 0xRRGGBB number; style = "text"|"bg"
  highlight.clear()
  log.trace/debug/info/warn/error/fatal(tag, ...)   -> Script Console log
  print(...)               alias of log.info("print", ...)
  sys.now()                uv.now() milliseconds
  sys.timer_start(ms, fn)          one-shot timer (fn pcall-wrapped)
  sys.timer_loop_start(ms, fn)     repeating timer
  sys.timer_stop(fn)
  wave.*                   waveform module passthrough (core/waveform.lua)
  string.toHex/fromHex/split/utf8Len  LLCOM-style string extensions
  _SCRIPT                  script base name ("demo")
  _PATH                    full path

Line filter semantics (applied per COMPLETE line, before _append_imgui_receive):
  show(line) := (no keep-rules OR line matches any keep) AND
                (line matches no drop-rule)
Plain substring match (string.find plain=true) — regex stays out of v1.

Partial-line contract: the filter only decides on lines terminated by '\n'.
The unterminated tail of a batch is held in `filter_pending` and decided with
the next batch.  Force-flush conditions (an unterminated line must never
starve the view):
  * #pending > 8 KiB   (pathological no-newline stream)
  * drain idle > 200ms (a silent gap ends the frame, like SSCOM 断帧)
  * filter disabled/cleared

Hook dispatch order inside process_rx(text):
  charset convert (window.lua side, before this call)
  -> on.receive hooks (batch-level; any may transform or drop)
  -> line filter (if any script registered keep/drop)
------------------------------------------------------------------------]]--

local M = {}

local uv = require("luv")

-- Cap a single script's log line so a runaway tostring can't blow the ring.
local LOG_LINE_MAX = 2000
-- Ring size for the Script Console log panel (last N lines kept).
local LOG_RING = 200
-- Consecutive failures before a hook is auto-disabled.
local HOOK_STRIKES = 3
-- Unterminated-line starvation bounds.
local PENDING_MAX = 8 * 1024
local PENDING_IDLE_MS = 200
-- Highlight rule caps shared with the C++ renderer (see bridge).
local MAX_RULES = 32
local FILE_READ_MAX = 32 * 1024 * 1024   -- sys.file_read cap (bytes)
-- Streamed file window for sys.file_open/file_seek_read (send-file flow):
-- a chunk this big bounds resident file data to a few MiB no matter how
-- large the file on disk is (vs the old whole-file file_read copy).
local FILE_WINDOW_BYTES = 1024 * 1024

-- ---------------------------------------------------------------------------
-- Async-read fd close discipline.
-- libuv forbids closing an fd that carries an outstanding fs request
-- (uv_fs_read on a background thread -> UB/crash).  Our blocking reads have no
-- such window; async streaming reads (sys.file_read_at_async, used by
-- send_file.lua to keep the UI unblocked on disk) DO.  So a close on an fd with
-- pending async reads defers the real uv_fs_close until that fd's completion
-- drains.  Threadpool completions are only delivered on a later event-loop pass
-- that yielded wall time (the app's message loop does this between ticks), so
-- a deferred close is finished by the completion callback itself, never by a
-- busy-spin on the UI thread.
-- ---------------------------------------------------------------------------
local function remove_open_fd(record, fd)
    local fds = record and record.open_fds
    if not fds then return end
    for i = #fds, 1, -1 do
        if fds[i] == fd then table.remove(fds, i); return end
    end
end

-- Number of outstanding async reads on this fd (0 / none if not tracked).
local function pending_reads(record, fd)
    local p = (record and record._fs_pending) or {}
    return (p[fd] or 0)
end

-- Close fd now iff no async read is in flight, else defer to its completion.
-- Runs uv.run("nowait") once so a just-issued threadpool read can post before
-- we fall through to the deferred-close bookkeeping.  Never blocks the caller.
local function fs_close(record, fd)
    if not record or not fd then return end
    remove_open_fd(record, fd)
    if pending_reads(record, fd) > 0 then
        -- Permit one pump so a completion that has already been posted by the
        -- threadpool can be delivered before we defer.  If it has NOT posted
        -- yet we hand the real close to the async completion (below) — that
        -- runs when the app's message loop next yields wall time and lets the
        -- threadpool signal land.  We never busy-spin here (UI thread).
        uv.run("nowait")
        if pending_reads(record, fd) == 0 then
            uv.fs_close(fd)
            return
        end
        -- still in flight: hand the real close to the completion callback.
        local def = record._fs_close_deferred or {}
        def[fd] = true
        record._fs_close_deferred = def
        return
    end
    uv.fs_close(fd)
end

-- ---------------------------------------------------------------------------
-- string extensions (LLCOM parity).  Method-call sugar `("AB"):toHex()`
-- resolves through the REAL string metatable, so a private table cannot
-- serve it; these four helpers are installed into the global string library
-- once (idempotent, additive only — host code never calls them, and the
-- names match LLCOM exactly so scripts port over unmodified).
-- ---------------------------------------------------------------------------

local function str_toHex(s, sep)
    sep = sep or ""
    return (s:gsub(".", function(c)
        return string.format("%02X%s", c:byte(), sep)
    end))
end

local function str_fromHex(s)
    local clean = s:gsub("[^0-9a-fA-F]", "")
    if #clean % 2 ~= 0 then clean = clean:sub(1, #clean - 1) end
    return (clean:gsub("(..)", function(h)
        return string.char(tonumber(h, 16))
    end))
end

local function str_split(s, delim)
    delim = delim or ","
    local out = {}
    local pos = 1
    while true do
        local hit = string.find(s, delim, pos, true)
        if not hit then
            out[#out + 1] = s:sub(pos)
            break
        end
        out[#out + 1] = s:sub(pos, hit - 1)
        pos = hit + #delim
    end
    return out
end

local function str_utf8Len(s)
    local n = 0
    for _ in s:gmatch("[\0-\x7F\xC2-\xFD][\x80-\xBF]*") do n = n + 1 end
    return n
end

string.toHex = string.toHex or str_toHex
string.fromHex = string.fromHex or str_fromHex
string.split = string.split or str_split
string.utf8Len = string.utf8Len or str_utf8Len

-- The sandbox hands scripts the plain `string` library; the extensions above
-- are reachable through it exactly like in LLCOM.
local script_string = string

-- ---------------------------------------------------------------------------
-- Construction
-- ---------------------------------------------------------------------------

-- opts:
--   script_dir      absolute directory containing *.lua (required)
--   send            function(payload_string) -> actually transmit
--   is_open         function() -> bool (port connected?)
--   on_rules_changed function(rules_array)  -- highlight rules updated; each
--                   rule = {pattern, color, style}
--   on_log          optional function(line) — mirrors every log line
--                   (window.lua pushes the ring to the C++ console)
--   wave            optional module table exposed as `wave` (core/waveform)
--   auto_reload     bool — poll script mtimes each poll() tick (1 Hz)
function M.new(opts)
    opts = opts or {}
    local engine = {
        script_dir = opts.script_dir,
        send_fn = opts.send,
        is_open_fn = opts.is_open,
        on_rules_changed = opts.on_rules_changed,
        on_log = opts.on_log,
        wave_module = opts.wave,
        charset_module = opts.charset,
        -- Serial simulator object (core/serial_sim.lua) injected by window.lua
        -- ONLY when the sim auto-activated (no real ports).  Exposed to
        -- scripts as sys.sim (nil otherwise); sim_control.lua drives it.
        sim_module = opts.sim,
        -- Host-injected native file-open dialog (returns UTF-8 path or nil).
        -- window.lua wires this to ui/win32.lua's GetOpenFileNameW.
        open_file_fn = opts.open_file,
        auto_reload = opts.auto_reload and true or false,
        -- name -> script record
        -- record = { name, path, chunk_env, enabled, mtime,
        --            recv_hook, send_hook, keeps, drops, strikes_recv,
        --            last_loaded }
        scripts = {},
        order = {},            -- stable script order (sorted names)
        -- line-filter pending partial line + idle tracking
        filter_pending = "",
        last_rx_ms = 0,
        rules_dirty = false,
        log_ring = {},         -- ring of formatted lines
        log_head = 0,          -- next ring write index
        log_count = 0,         -- total lines ever (for dirty check)
        log_flushed = 0,       -- last log_count pushed to the UI
        timers = {},           -- strong refs; timer:stop() on shutdown
        repl_env = nil,        -- first enabled script's env (REPL host)
    }
    return setmetatable(engine, { __index = M })
end

-- ---------------------------------------------------------------------------
-- Logging
-- ---------------------------------------------------------------------------

local LEVEL_TAG = { "TRACE", "DEBUG", "INFO ", "WARN ", "ERROR", "FATAL" }

function M:log(level, tag, ...)
    local parts = {}
    for i = 1, select("#", ...) do
        local v = select(i, ...)
        if type(v) == "string" then
            parts[#parts + 1] = v
        else
            parts[#parts + 1] = tostring(v)
        end
    end
    local text = table.concat(parts, " ")
    if #text > LOG_LINE_MAX then text = text:sub(1, LOG_LINE_MAX) .. "..." end
    local line = string.format("[%s][%s] %s", LEVEL_TAG[level] or "INFO ", tag, text)
    self.log_head = (self.log_head % LOG_RING) + 1
    self.log_ring[self.log_head] = line
    self.log_count = self.log_count + 1
    if self.on_log then
        local ok, err = pcall(self.on_log, line)
        if not ok then io.stderr:write("[script log] " .. tostring(err) .. "\n") end
    end
end

-- Concatenated log tail for the C++ console panel; empty when nothing new.
-- Returns text, is_dirty (dirty := log_count ~= log_flushed).
function M:log_lines()
    local dirty = self.log_count ~= self.log_flushed
    if not dirty then return nil, false end
    self.log_flushed = self.log_count
    local lines = {}
    -- Walk the ring oldest -> newest (index math keeps this linear in LOG_RING).
    local start = self.log_count - math.min(LOG_RING, self.log_count)
    for i = 0, math.min(LOG_RING, self.log_count) - 1 do
        local slot = (start + i) % LOG_RING + 1
        local line = self.log_ring[slot]
        if line then lines[#lines + 1] = line end
    end
    return table.concat(lines, "\n"), true
end

function M:clear_log()
    self.log_ring = {}
    self.log_head = 0
    self.log_count = 0
    self.log_flushed = 0
end

-- ---------------------------------------------------------------------------
-- Sandbox environment
-- ---------------------------------------------------------------------------

local SAFE_OS = {
    time = os.time, clock = os.clock, date = os.date, getenv = os.getenv,
    difftime = os.difftime,
}

local function build_env(engine, record)
    -- Fresh async fs-close bookkeeping per env.  A reload must not inherit the
    -- previous copy's in-flight read counts or deferred-close list: a stale
    -- non-zero _fs_pending makes pending_reads() see reads that no longer
    -- exist, deferring every later close to a completion that will never run
    -- (fd leak).  Force-empty all three (open_fds is also reset by
    -- close_record_fds before reload/shutdown, but build_env is the single
    -- entry and re-asserts a clean slate even on a direct call).
    record.open_fds = {}
    record._fs_pending = {}
    record._fs_close_deferred = {}
    local env = {
        _SCRIPT = record.name,
        _PATH = record.path,
        string = script_string,
        table = table, math = math, coroutine = coroutine,
        os = SAFE_OS,
        pairs = pairs, ipairs = ipairs, next = next, select = select,
        unpack = unpack, type = type, tostring = tostring, tonumber = tonumber,
        pcall = pcall, xpcall = xpcall, error = error, assert = assert,
        setmetatable = setmetatable, getmetatable = getmetatable,
        rawget = rawget, rawset = rawset, rawequal = rawequal,
    }

    env.uart = {
        send = function(data)
            if not engine.is_open_fn or not engine.is_open_fn() then
                env.log.warn(record.name, "uart.send ignored: port closed")
                return false, -2
            end
            if type(data) ~= "string" or #data == 0 then return false end
            -- send_fn returns (ok, errcode) where errcode is the ABI status
            -- (-5 full, -2 not open, -6 io, nil on success) so a streaming
            -- caller can back off on a full TX queue instead of aborting.
            local ok, errcode = engine.send_fn(data)
            if ok == nil then ok = true end  -- legacy host that returns nothing
            return ok and true or false, errcode
        end,
        send_hex = function(hex)
            local bytes = script_string.fromHex(hex or "")
            if #bytes == 0 then return false end
            return env.uart.send(bytes)
        end,
        is_open = function()
            return engine.is_open_fn and engine.is_open_fn() or false
        end,
    }

    env.on = {
        receive = function(fn)
            if type(fn) ~= "function" then return end
            record.recv_hook = fn
            record.strikes_recv = 0
        end,
        send = function(fn)
            if type(fn) ~= "function" then return end
            record.send_hook = fn
            record.strikes_send = 0
        end,
    }

    env.filter = {
        keep = function(...)
            for i = 1, select("#", ...) do
                local p = select(i, ...)
                if type(p) == "string" and #p > 0 then
                    record.keeps[#record.keeps + 1] = p
                end
            end
        end,
        drop = function(...)
            for i = 1, select("#", ...) do
                local p = select(i, ...)
                if type(p) == "string" and #p > 0 then
                    record.drops[#record.drops + 1] = p
                end
            end
        end,
        clear = function()
            record.keeps = {}
            record.drops = {}
        end,
    }

    env.highlight = {
        rule = function(pattern, color, style)
            if type(pattern) ~= "string" or #pattern == 0 then return end
            color = tonumber(color) or 0xE53935
            style = (style == "bg") and "bg" or "text"
            record.rules[#record.rules + 1] =
                { pattern = pattern, color = color, style = style }
            engine.rules_dirty = true
        end,
        clear = function()
            record.rules = {}
            engine.rules_dirty = true
        end,
    }

    -- Dynamic settings pages (C++ spec-rendered widgets).  The script calls
    -- ui.page(id, title, spec) to declare a tab in the Settings window and
    -- defines ui.event(page, kind, widget, value) to receive interactions.
    -- The window.lua pump routes events by "script:id" page ownership.
    env.ui = {
        page = function(id, title, spec)
            if type(id) ~= "string" or #id == 0 then return end
            local qid = record.name .. ":" .. id
            if spec == nil then
                record.ui_pages[qid] = nil
            else
                record.ui_pages[qid] = { title = title or id, spec = spec }
            end
        end,
        event = function() end,   -- user overrides: function(page, kind, widget, value)
    }

    env.log = {}
    for level = 1, 6 do
        env.log[LEVEL_TAG[level]:lower():gsub(" ", "")] = function(tag, ...)
            env._engine_log(level, tag, ...)
        end
    end

    env.sys = {
        now = function() return uv.now() end,
        timer_start = function(ms, fn)
            return engine:timer_create(tonumber(ms) or 0, fn, false)
        end,
        timer_loop_start = function(ms, fn)
            return engine:timer_create(tonumber(ms) or 0, fn, true)
        end,
        timer_stop = function(handle)
            engine:timer_destroy(handle)
        end,
        -- File access for plugins (send-file demo).  Read-only and bounded:
        -- open_file drives the native Win32 dialog through window.lua's
        -- injection hook (nil until the host wires it); file_read is capped
        -- so a plugin cannot stream a huge file into the single-threaded
        -- message loop (the MVP reads whole files, then chunks the BYTES).
        open_file = function()
            if engine.open_file_fn then
                return engine.open_file_fn()
            end
            return nil
        end,
        file_size = function(path)
            if type(path) ~= "string" or path == "" then return nil end
            local stat = uv.fs_stat(path)
            if stat and stat.type == "file" then return stat.size end
            return nil
        end,
        file_read = function(path)
            local size = env.sys.file_size(path)
            if not size or size > FILE_READ_MAX then return nil end
            local fd, err = uv.fs_open(path, "r", 438)  -- 0644 octal
            if not fd then return nil end
            -- pcall-guard the read so an unexpected uv.fs_read error cannot
            -- skip the close and leak the fd (this read path is NOT tracked on
            -- record.open_fds, so shutdown's tidy-up would never find it).
            local ok, data = pcall(uv.fs_read, fd, size == 0 and 1 or size, 0)
            pcall(function() uv.fs_close(fd) end)
            if not ok or not data or (size > 0 and #data ~= size) then
                return nil
            end
            return size == 0 and "" or data
        end,
        -- Streaming file reads for large payloads (send-file chunked flow).
        -- file_open/file_read_at/file_close keep only a 1 MiB window resident
        -- instead of whole-file copies; offset is absolute, len is clamped to
        -- the remaining size.  Every open fd is tracked on the record: reload,
        -- shutdown and unload close whatever the script left open, so a stale
        -- script can't keep a file locked for the life of the process.
        file_open = function(path)
            if type(path) ~= "string" or path == "" then return nil end
            local fd = uv.fs_open(path, "r", 438)  -- 0644 octal
            if not fd then return nil end
            local fds = record.open_fds
            fds[#fds + 1] = fd
            return fd
        end,
        file_read_at = function(fd, offset, len)
            if not fd or offset < 0 or len <= 0 then return nil end
            if len > FILE_WINDOW_BYTES then len = FILE_WINDOW_BYTES end
            return uv.fs_read(fd, len, offset)
        end,
        -- Non-blocking streaming read for large sends.  Runs on libuv's
        -- background threadpool (async fs_read) so a file chunk read never
        -- stalls the single-threaded UI message loop; the completion fires on
        -- the loop's next uv.run("nowait") pass (the app drains P1 each
        -- iteration).  cb(err, data) receives the chunk.  Callers MUST keep at
        -- most one in-flight read per fd and close only between completions —
        -- see file_close / close_record_fds, which defer the real uv.fs_close
        -- until the fd's in-flight count reaches zero (libuv forbids closing an
        -- fd under an outstanding fs request).  Async fds are still tracked on
        -- record.open_fds so reload/shutdown find them.
        file_read_at_async = function(fd, offset, len, cb)
            if not fd or offset < 0 or len <= 0 then
                if cb then cb("einval", nil) end
                return false
            end
            if len > FILE_WINDOW_BYTES then len = FILE_WINDOW_BYTES end
            local pending = record._fs_pending or {}
            pending[fd] = (pending[fd] or 0) + 1
            record._fs_pending = pending
            uv.fs_read(fd, len, offset, function(err, data)
                local p = record._fs_pending or {}
                local left = p[fd] or 0
                if left <= 1 then
                    p[fd] = nil          -- drained
                    record._fs_pending = p
                else
                    p[fd] = left - 1     -- still more in flight
                end
                if cb then cb(err and tostring(err) or nil, (not err) and data or nil) end
                -- If the caller closed while this read was outstanding, the
                -- real uv.fs_close was deferred; perform it now that it has
                -- drained (fs_close stored it under record._fs_close_deferred).
                if (record._fs_pending or {})[fd] == nil and
                   (record._fs_close_deferred or {})[fd] then
                    (record._fs_close_deferred or {})[fd] = nil
                    uv.fs_close(fd)
                end
            end)
            return true
        end,
        file_close = function(fd)
            -- Asynchronous-read-safe close (see the module-local fs_close above):
            -- closes now if nothing is in flight on fd, else defers the real
            -- uv.fs_close until the fd's pending async reads drain.
            fs_close(record, fd)
        end,
    }

    if engine.wave_module then
        env.wave = engine.wave_module
        -- llcom-compatible curve API (LuaApi.md AddPoint): scripts parse the
        -- received text themselves and push points, exactly like llcom's
        -- user-script "绘制曲线.lua".  apiAddPoint(value, line) with a 0-based
        -- line number maps onto wave.push(channel, y) (1-based channel);
        -- line defaults to 0 (first curve).  Points are appended to the tail,
        -- so the plot is a rolling "value over time" trace.
        local wave = engine.wave_module
        env.apiAddPoint = function(value, line)
            local n = tonumber(value)
            if n == nil then return false end
            local channel = (tonumber(line) or 0) + 1
            return wave.push(channel, n)
        end
    end

    -- Serial simulator passthrough (core/serial_sim.lua).  window.lua injects
    -- engine.sim_module ONLY when the sim auto-activated (no real COM ports);
    -- otherwise sys.sim stays nil so a hardware host's scripts see no change.
    -- Thin closures so a script never holds the sim object directly and every
    -- call is a nil-safe method dispatch.
    if engine.sim_module then
        local sim = engine.sim_module
        env.sys.sim = {
            start = function(port) return sim:start(port) end,
            stop = function() return sim:stop() end,
            profile = function(name) return sim:profile(name) end,
            set_rate = function(bps) return sim:set_rate(bps) end,
            ports = function() return sim:ports() end,
            is_active = function() return sim:available() and true or false end,
            is_running = function() return sim:is_running() and true or false end,
        }
    end

    -- Protocol libraries (in-project copy under xcom_lua/libs/protocol,
    -- injected into package.path by main.lua —
    -- docs/lua-libs-value-and-recommendations.md section 5).  struct.pack/unpack for binary frame parsing (Modbus RTU
    -- etc.) and json for config/export — the two highest-value gaps.  A
    -- failed require (missing vendor dir) degrades to nil, not an error.
    local ok_struct, struct = pcall(require, "struct")
    if ok_struct then env.struct = struct end
    local ok_json, json = pcall(require, "json")
    if ok_json then env.json = json end
    -- Base64 encode (pure Lua, straightforward loop; LLCOM scripts commonly
    -- need it).  decode omitted until a script asks for it.
    do
        local b64chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZ" ..
            "abcdefghijklmnopqrstuvwxyz0123456789+/"
        env.base64 = {
            encode = function(data)
                local out = {}
                local n = #data
                local i = 1
                while i <= n do
                    local b1 = data:byte(i) or 0
                    local b2 = data:byte(i + 1) or 0
                    local b3 = data:byte(i + 2) or 0
                    local remaining = n - i + 1          -- 1, 2 or 3
                    local v = b1 * 65536 + b2 * 256 + b3
                    local c1 = b64chars:sub(math.floor(v / 262144) % 64 + 1,
                                             math.floor(v / 262144) % 64 + 1)
                    local c2 = b64chars:sub(math.floor(v / 4096) % 64 + 1,
                                             math.floor(v / 4096) % 64 + 1)
                    local c3 = b64chars:sub(math.floor(v / 64) % 64 + 1,
                                             math.floor(v / 64) % 64 + 1)
                    local c4 = b64chars:sub(v % 64 + 1, v % 64 + 1)
                    if remaining == 1 then
                        out[#out + 1] = c1 .. c2 .. "=="
                    elseif remaining == 2 then
                        out[#out + 1] = c1 .. c2 .. c3 .. "="
                    else
                        out[#out + 1] = c1 .. c2 .. c3 .. c4
                    end
                    i = i + 3
                end
                return table.concat(out)
            end,
        }
    end

    -- Charset helpers (LLCOM apiUtf8ToHex / apiAscii2Utf8 parity).  The
    -- display-side stream conversion itself lives in core/charset.lua and is
    -- driven by window.lua; these are one-shot converters for scripts.
    if engine.charset_module then
        local cs = engine.charset_module
        env.apiUtf8ToHex = function(s)
            return cs.utf8_to_cp(s, 936)   -- UTF-8 -> GB2312 bytes
        end
        env.apiAscii2Utf8 = function(bytes)
            return cs.cp_to_utf8(bytes, 936)  -- GB2312 bytes -> UTF-8
        end
    end

    -- Host-side log entry point (called by env.log.* closures above).
    env._engine_log = function(level, tag, ...)
        engine:log(level, tag or record.name, ...)
    end
    env.print = function(...)
        env._engine_log(3, "print", ...)
    end

    -- LLCOM compatibility shims (ref/llcom core_script/head.lua): scripts
    -- written for LLCOM expect `uartReceive` as a GLOBAL receive hook and
    -- `apiSendUartData` as the legacy send entry.  Implemented as env-level
    -- aliases so porting an LLCOM script is a drop-in.
    env._engine_uart_receive_slot = function(data)
        if type(env.uartReceive) == "function" then
            return env.uartReceive(data)
        end
        return data
    end
    env.apiSendUartData = env.uart.send

    return env
end

-- Close every fd the script record still has open and empty the tracking
-- list.  Called on reload (before the new env is built) and on shutdown so
-- disabling or reloading a script that holds a file never locks it for the
-- rest of the process lifetime.
--
-- Unlike sys.file_close (which defers to an in-flight read's completion via
-- _fs_close_deferred), this is an unconditional teardown: the record is about
-- to be dropped or rebuilt, so there is no later completion that is guaranteed
-- to run and honour the deferred close.  We clear the pending count first so a
-- still-outstanding threadpool completion cannot re-close the fd (double
-- close) and cannot find a stale deferred marker; then close pcall-guarded so
-- an fd already closed by libuv (edge case) does not crash the UI thread.
local function close_record_fds(record)
    local list = record and record.open_fds
    if not list then return end
    for i = #list, 1, -1 do
        local fd = list[i]
        list[i] = nil
        -- Drop the pending count so the fd's in-flight completion, if it
        -- fires after this teardown, sees "drained" and skips its own close
        -- (it would otherwise double-close, and its deferred-close re-check
        -- below keys on pending == nil).
        if record._fs_pending then record._fs_pending[fd] = nil end
        -- Clear any deferred marker left by a prior sys.file_close so a late
        -- completion never carries it out on an already-closed fd.
        if record._fs_close_deferred then record._fs_close_deferred[fd] = nil end
        pcall(function() uv.fs_close(fd) end)
    end
    record.open_fds = {}
end

-- ---------------------------------------------------------------------------
-- Script lifecycle
-- ---------------------------------------------------------------------------

local function script_mtime(path)
    local stat = uv.fs_stat(path)
    return stat and stat.mtime.sec or nil
end

-- (Re)load one script file.  Returns ok, err.  A failed (re)load disables the
-- script and keeps the previous hook state cleared so a broken edit cannot
-- keep stale hooks alive.
function M:load_script(name)
    local record = self.scripts[name]
    if not record then return false, "unknown script " .. name end
    local chunk, err = loadfile(record.path)
    if not chunk then
        record.enabled = false
        self:log(5, name, "load error: " .. tostring(err))
        return false, err
    end
    -- Fresh record state per load: hooks/filters/rules do not survive a
    -- reload unless the script registers them again.  Close any fds the
    -- previous copy of the script left open (otherwise a hot reload would
    -- keep the file locked until process exit).
    record.recv_hook = nil
    record.send_hook = nil
    record.keeps = {}
    record.drops = {}
    record.rules = {}
    record.ui_pages = {}     -- ui.page declarations (repopulated on load)
    record.strikes_recv = 0
    record.strikes_send = 0
    record.mtime = script_mtime(record.path)
    close_record_fds(record)
    record.env = build_env(self, record)
    record.last_loaded = uv.now()
    setfenv(chunk, record.env)
    local ok, run_err = pcall(chunk)
    if not ok then
        record.enabled = false
        record.env = nil
        self:log(5, name, "run error: " .. tostring(run_err))
        return false, run_err
    end
    self.rules_dirty = true
    self:log(3, name, "loaded")
    return true
end

-- Scan the script directory and register every *.lua (sorted).  New files are
-- disabled by default; enabled state of known files persists across rescans
-- so a UI refresh doesn't silently turn scripts on/off.
function M:load_all()
    local names = {}
    local req, err = uv.fs_scandir(self.script_dir)
    if not req then
        self:log(4, "engine", "cannot scan " .. tostring(self.script_dir) ..
            ": " .. tostring(err))
        return
    end
    while true do
        local name = uv.fs_scandir_next(req)
        if not name then break end
        if name:match("%.lua$") then names[#names + 1] = name end
    end
    table.sort(names)
    for _, name in ipairs(names) do
        if not self.scripts[name] then
            local record = {
                name = name,
                path = self.script_dir .. "/" .. name,
                enabled = false,
                keeps = {}, drops = {}, rules = {},
            }
            self.scripts[name] = record
        end
    end
    self.order = names
end

function M:script_names()
    return self.order
end

function M:enable(name, enabled)
    local record = self.scripts[name]
    if not record then return end
    enabled = enabled and true or false
    if enabled then
        -- (Re)load on every enable so hooks reflect the newest file content
        -- (load_script clears stale hooks/filters/rules first; a failed load
        -- disables the record and we honour that below).
        local ok = self:load_script(name)
        if not ok then
            record.enabled = false
            return
        end
    end
    record.enabled = enabled
    if not enabled then
        -- Reset strike counters so re-enabling gives the hooks a fresh chance.
        record.strikes_recv = 0
        record.strikes_send = 0
    end
    self:log(3, name, enabled and "enabled" or "disabled")
end

function M:enabled_list()
    local out = {}
    for _, name in ipairs(self.order) do
        local record = self.scripts[name]
        if record and record.enabled then out[#out + 1] = name end
    end
    return out
end

function M:is_enabled(name)
    local record = self.scripts[name]
    return record and record.enabled or false
end

function M:reload(name)
    return self:load_script(name)
end

-- ---------------------------------------------------------------------------
-- Timers (engine-owned so shutdown() stops everything)
-- ---------------------------------------------------------------------------

function M:timer_create(ms, fn, repeating)
    if type(fn) ~= "function" then return nil end
    local timer = uv.new_timer()
    local engine = self
    local callback = function()
        local ok, err = pcall(fn)
        if not ok then
            engine:log(5, "timer", "callback error: " .. tostring(err))
        end
    end
    -- C re-entry into Lua from a luv callback: keep the interpreter-safe
    -- discipline used everywhere in this app (see window.lua timer callbacks).
    if jit and jit.off then jit.off(callback, true) end
    self.timers[#self.timers + 1] = timer
    if repeating then
        timer:start(math.max(1, ms), math.max(1, ms), callback)
    else
        timer:start(math.max(1, ms), 0, callback)
    end
    return timer
end

function M:timer_destroy(handle)
    for i, timer in ipairs(self.timers) do
        if timer == handle then
            timer:stop()
            table.remove(self.timers, i)
            return
        end
    end
end

function M:shutdown()
    for _, timer in ipairs(self.timers) do
        local ok = pcall(function() timer:stop() end)
        if not ok then io.stderr:write("[script] timer stop failed\n") end
    end
    self.timers = {}
    for _, record in pairs(self.scripts) do
        close_record_fds(record)
    end
end

-- ---------------------------------------------------------------------------
-- Hook dispatch (all pcall-wrapped; 3 strikes disables)
-- ---------------------------------------------------------------------------

-- Run every enabled script's recv hook over one drained batch.
-- Returns the (possibly transformed) text, or nil when the batch is dropped.
-- LLCOM compat: after the explicit on.receive hooks, a script that defined
-- the legacy GLOBAL `uartReceive` function also gets the batch (its return
-- value is ignored per LLCOM semantics — the hook is observe-only).
function M:dispatch_receive(text)
    for _, name in ipairs(self.order) do
        local record = self.scripts[name]
        if record and record.enabled then
            if record.recv_hook then
                local ok, result = pcall(record.recv_hook, text)
                if ok then
                    record.strikes_recv = 0
                    if result == nil or result == false then
                        return nil  -- batch dropped from display
                    elseif type(result) == "string" then
                        text = result
                    end
                    -- non-string truthy result: keep text unchanged
                else
                    record.strikes_recv = record.strikes_recv + 1
                    self:log(5, name, "on.receive error: " .. tostring(result))
                    if record.strikes_recv >= HOOK_STRIKES then
                        record.recv_hook = nil
                        record.strikes_recv = 0
                        self:log(4, name, "on.receive disabled after " ..
                            HOOK_STRIKES .. " consecutive errors")
                    end
                end
            end
            -- Legacy LLCOM `uartReceive` global (observe-only, pcall-wrapped
            -- with the same 3-strikes policy).
            if record.env and type(record.env.uartReceive) == "function" then
                local ok, err = pcall(record.env.uartReceive, text)
                if not ok then
                    record.strikes_recv = record.strikes_recv + 1
                    self:log(5, name, "uartReceive error: " .. tostring(err))
                    if record.strikes_recv >= HOOK_STRIKES then
                        record.env.uartReceive = nil
                        record.strikes_recv = 0
                        self:log(4, name, "uartReceive disabled after " ..
                            HOOK_STRIKES .. " consecutive errors")
                    end
                end
            end
        end
    end
    return text
end

-- Send-convert hook.  Returns payload', or nil to abort the send.
function M:dispatch_send(payload)
    for _, name in ipairs(self.order) do
        local record = self.scripts[name]
        if record and record.enabled and record.send_hook then
            local ok, result = pcall(record.send_hook, payload)
            if ok then
                record.strikes_send = 0
                if result == nil or result == false then
                    return nil
                elseif type(result) == "string" then
                    payload = result
                end
            else
                record.strikes_send = record.strikes_send + 1
                self:log(5, name, "on.send error: " .. tostring(result))
                if record.strikes_send >= HOOK_STRIKES then
                    record.send_hook = nil
                    record.strikes_send = 0
                    self:log(4, name, "on.send disabled after " ..
                        HOOK_STRIKES .. " consecutive errors")
                end
            end
        end
    end
    return payload
end

-- ---------------------------------------------------------------------------
-- Line filter
-- ---------------------------------------------------------------------------

-- One line against every enabled script's keep/drop sets.
-- keep wins the default-show only when at least one keep rule exists.
function M:line_visible(line)
    local any_keep = false
    for _, name in ipairs(self.order) do
        local record = self.scripts[name]
        if record and record.enabled then
            for _, pat in ipairs(record.keeps) do
                any_keep = true
                if string.find(line, pat, 1, true) then
                    return true
                end
            end
        end
    end
    if any_keep then return false end  -- keeps exist, none matched
    for _, name in ipairs(self.order) do
        local record = self.scripts[name]
        if record and record.enabled then
            for _, pat in ipairs(record.drops) do
                if string.find(line, pat, 1, true) then
                    return false
                end
            end
        end
    end
    return true
end

function M:has_line_filter()
    for _, name in ipairs(self.order) do
        local record = self.scripts[name]
        if record and record.enabled then
            if #record.keeps > 0 or #record.drops > 0 then
                return true
            end
        end
    end
    return false
end

-- Apply the line filter to one batch.  Returns filtered text ("" when every
-- line is dropped — the caller treats "" as "nothing to display").
-- Fast path: no active filter returns text unchanged (single table scan).
function M:apply_line_filter(text)
    if not self:has_line_filter() then
        return text
    end
    local combined = self.filter_pending .. text
    self.filter_pending = ""
    -- Decide only up to the last complete line; hold the tail.
    local last_nl = 0
    local pos = 1
    while true do
        local hit = string.find(combined, "\n", pos, true)
        if not hit then break end
        last_nl = hit
        pos = hit + 1
    end
    local complete = last_nl > 0 and combined:sub(1, last_nl) or ""
    -- No newline in the batch: the WHOLE combined text is the pending tail.
    local tail = last_nl > 0 and combined:sub(last_nl + 1) or combined
    local out = {}
    local start = 1
    while start <= #complete do
        local hit = string.find(complete, "\n", start, true)
        local line_end = hit or #complete
        local line = complete:sub(start, line_end)
        if self:line_visible(line) then
            out[#out + 1] = line
        end
        start = line_end + 1
    end
    self.filter_pending = tail
    self.last_rx_ms = uv.now()
    -- Oversize unterminated lines must never starve the view: decide the
    -- pending tail immediately instead of waiting for the idle poll.
    if #tail > PENDING_MAX then
        self.filter_pending = ""
        if self:line_visible(tail) then
            out[#out + 1] = tail
        end
    end
    return table.concat(out)
end

-- Decide whether the pending partial line should be force-flushed as a
-- complete line (idle gap or oversize).  Called from poll().
function M:flush_pending()
    if self.filter_pending == "" then return end
    local force = false
    if #self.filter_pending > PENDING_MAX then
        force = true
    elseif self.last_rx_ms > 0 and uv.now() - self.last_rx_ms > PENDING_IDLE_MS then
        force = true
    end
    if not force then return end
    local line = self.filter_pending
    self.filter_pending = ""
    if self:line_visible(line) then
        self.pending_output = line
    end
end

-- ---------------------------------------------------------------------------
-- Highlight rules aggregation
-- ---------------------------------------------------------------------------

-- Rules across all ENABLED scripts, capped at MAX_RULES (matching the C++
-- renderer's cap).  Each rule = {pattern, color, style}.
function M:collect_rules()
    local rules = {}
    for _, name in ipairs(self.order) do
        local record = self.scripts[name]
        if record and record.enabled then
            for _, rule in ipairs(record.rules) do
                if #rules >= MAX_RULES then
                    self:log(4, "engine", "highlight rule cap (" ..
                        MAX_RULES .. ") reached; ignoring extras")
                    return rules
                end
                rules[#rules + 1] = rule
            end
        end
    end
    return rules
end

function M:take_rules_if_dirty()
    if not self.rules_dirty then return nil end
    self.rules_dirty = false
    return self:collect_rules()
end

-- Plugin settings pages: collect every enabled script's ui.page()
-- declarations as {id=, title=, spec=} records.  window.lua diffs the
-- resulting id set against what the C++ side currently holds and pushes
-- additions/changes (and removals via spec=nil).
function M:collect_ui_pages()
    local pages = {}
    for _, name in ipairs(self.order) do
        local record = self.scripts[name]
        if record and record.enabled and record.ui_pages then
            for id, page in pairs(record.ui_pages) do
                pages[#pages + 1] = { id = id, title = page.title, spec = page.spec }
            end
        end
    end
    return pages
end

-- Route one plugin event to the owning script's ui.event callback.  Page ids
-- are "script.lua:local_id"; a missing script or non-function is ignored.
function M:dispatch_ui_event(page, kind, widget, value)
    local name = page:match("^([^:]+):")
    local record = name and self.scripts[name]
    if not record or not record.enabled or not record.env then return end
    local ui = record.env.ui
    if ui and type(ui.event) == "function" then
        local ok, err = pcall(ui.event, page, kind, widget, value)
        if not ok then
            self:log(5, record.name, "ui.event error: " .. tostring(err))
        end
    end
end

-- ---------------------------------------------------------------------------
-- Receive funnel + poll
-- ---------------------------------------------------------------------------

-- Full display-side receive funnel (called with the RAW drained batch):
--   hooks -> line filter.  Returns text to append (nil/"" = drop).
function M:process_rx(text, now_ms)
    if not text or #text == 0 then
        return nil
    end
    self.pending_output = nil
    -- 1) recv-convert hooks (batch level)
    local hooked = self:dispatch_receive(text)
    if hooked == nil then return nil end
    -- 2) line filter
    local filtered = self:apply_line_filter(hooked)
    -- A force-flushed pending line rides along (poll() set pending_output).
    if self.pending_output then
        filtered = self.pending_output .. filtered
        self.pending_output = nil
    end
    if filtered == "" then return nil end
    return filtered
end

-- Periodic housekeeping from window.lua's 1 Hz timer:
--   * mtime hot-reload of enabled scripts (opt-in)
--   * pending partial-line idle flush
function M:poll()
    self:flush_pending()
    if not self.auto_reload then return end
    for _, name in ipairs(self.order) do
        local record = self.scripts[name]
        if record and record.enabled then
            local mtime = script_mtime(record.path)
            if mtime and record.mtime and mtime ~= record.mtime then
                self:log(3, name, "changed on disk, reloading")
                self:load_script(name)
            end
        end
    end
end

-- REPL: evaluate one line in the first enabled script's environment.
function M:eval_command(line)
    line = (line or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if line == "" then return end
    self:log(3, "repl", "> " .. line)
    local env
    for _, name in ipairs(self.order) do
        local record = self.scripts[name]
        if record and record.enabled and record.env then
            env = record.env
            break
        end
    end
    if not env then
        self:log(4, "repl", "no enabled script to host the command")
        return
    end
    -- Try expression first (prepend "return "), fall back to statement.
    local chunk, err = loadstring("return " .. line, "=repl")
    if not chunk then
        chunk, err = loadstring(line, "=repl")
    end
    if not chunk then
        self:log(4, "repl", tostring(err))
        return
    end
    setfenv(chunk, env)
    local ok, a, b, c, d = pcall(chunk)
    if not ok then
        self:log(4, "repl", tostring(a))
        return
    end
    if a ~= nil or b ~= nil or c ~= nil or d ~= nil then
        self:log(3, "repl", tostring(a) ..
            (b ~= nil and ("\t" .. tostring(b)) or "") ..
            (c ~= nil and ("\t" .. tostring(c)) or "") ..
            (d ~= nil and ("\t" .. tostring(d)) or ""))
    end
end

-- Hook dispatch reaches user-script closures that may call FFI (uart.send ->
-- core_send -> xcom.send).  These methods are invoked via the dynamic
-- self.scripts.process_rx / .dispatch_send dispatch, so a recursive jit.off on
-- the caller (poll_display) does NOT protect them.  Pin the whole dispatch
-- chain off JIT so a traced hook never causes the "bad callback" PANIC (same
-- discipline documented for serial_sim and window.lua).
if jit and jit.off then
    jit.off(M.process_rx, true)
    jit.off(M.dispatch_receive, true)
    jit.off(M.dispatch_send, true)
    jit.off(M.dispatch_ui_event, true)
end

return M
