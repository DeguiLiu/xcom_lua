-- send_file.lua - 发送文件（Lua 插件动态 UI + 纯 Lua 流式分块发送）
-- @name 分块发送文件
-- @desc 弹出独立插件窗口选文件，按块现读现发，演示 ui.page 动态界面与流式发送。
-- 演示方案 A：零 C++ 改动，脚本用 ui.page() 在头部「Set」设置弹窗里声明
-- "File Send" 页，选文件走系统打开对话框，按块现读现发（1 MiB 内存在窗，
-- 不再整文件驻留内存，任意大小文件都可发）。
--
-- 运行方式：脚本控制台启用 send_file.lua → 点标题栏「Set」芯片 →
-- "File Send" 页签 → Choose file 选文件 → 调 Chunk/Gap → Send。
-- 进度实时刷在页面标题行（NO FILE / 文件名 + 已发/总字节）。
--
-- spec 文法（一行一控件，wid 仅限字母数字与 _ . -）：
--   title:文本 / check:wid:标签:0|1 / slider:wid:标签:min:max:默认
--   combo:wid:标签:默认idx:a|b|c / button:wid:标签

local state = {
    path = nil,       -- 当前文件完整路径
    size = 0,         -- 文件字节数
    fd = nil,         -- 流式句柄（sys.file_open；nil = 未加载）
    offset = 0,       -- 已发送字节数
    chunk = 1024,     -- 每块字节（发到串口前一次构造的载荷块）
    chunk_idx = 2,    -- combo 当前项（0 基，重声明 spec 时回显用）
    interval = 50,    -- 块间隔毫秒
    running = false,  -- 发送中
    timer = nil,      -- 在途一次性定时器句柄（自续前显式回收）
    stall_retries = 0,-- 连续被瞬时拒绝的次数（成功推进即清零）
}

-- combo 索引 -> 字节数（与 spec 的 items 顺序一致）
local CHUNK_ITEMS = { 128, 512, 1024, 4096, 16384 }
local CHUNK_DEFAULT_IDX = 2   -- 1024

-- uart.send's errcode is the xcom ABI status; the sandbox exposes no FFI, so
-- mirror core/xcom_ffi.lua's names here.  Both are TRANSIENT refusals and must
-- share one retry path: -4 err_busy (the scheduler declined the event —
-- breaker downgrade / open-in-progress), -5 err_full (TX pool / dispatcher
-- queue at capacity).  Only a non-transient code (e.g. -2 not open, -6 io)
-- aborts outright.
local ERR_BUSY, ERR_FULL = -4, -5
-- Upper bound on consecutive transient rejections before the stream gives up.
-- Unbounded retry would leave a permanently wedged pipeline (e.g. a breaker
-- stuck at L2) spinning forever with sys.busy(true), locking the host out.
local MAX_STALL_RETRIES = 100

local function basename(path)
    return path:match("([^/\\]+)$") or path
end

local function fmt_size(n)
    if n >= 1024 * 1024 then return string.format("%.1fMB", n / 1048576) end
    if n >= 1024 then return string.format("%.0fKB", n / 1024) end
    return tostring(n) .. "B"
end

local function close_file()
    if state.fd then
        sys.file_close(state.fd)
        state.fd = nil
    end
end

-- 每次 state 变化后重声明页面：spec 变 -> window.lua pump 自动重推 C++ 标签页
local function refresh()
    local head
    if state.path then
        head = "FILE: " .. basename(state.path) .. "  " ..
               state.offset .. "/" .. fmt_size(state.size)
    else
        head = "NO FILE"
    end
    local lines = {
        "title:" .. head,
        "button:browse:Choose file",
        "slider:chunk:Chunk bytes:128:16384:" .. state.chunk,
        "combo:chunkidx:Chunk preset:" .. state.chunk_idx ..
            ":128|512|1024|4096|16384",
        "slider:interval:Gap ms:10:1000:" .. state.interval,
    }
    if state.running then
        lines[#lines + 1] = "button:stop:Stop"
    else
        lines[#lines + 1] = "button:start:Send"
        -- Resume only makes sense with a partially-sent file still loaded.
        -- Stop deliberately KEEPS state.fd/offset (see the stop branch), so a
        -- multi-MB firmware that aborted at 80% can continue instead of being
        -- re-sent from byte 0.
        if state.fd and state.offset > 0 and state.offset < state.size then
            lines[#lines + 1] = "button:resume:Resume from " ..
                fmt_size(state.offset)
        end
    end
    ui.page("file", "File Send", table.concat(lines, "\n"))
end

refresh()   -- 加载即声明页面

-- ---- async incremental send pump -------------------------------------------
-- Plugin contract: "one `chunk` per `interval`".  Each chunk is read with
-- sys.file_read_at_async — a libuv threadpool request — so the disk never blocks
-- the single-threaded UI; the completion fires on the message loop's next
-- uv.run("nowait") pass and sends the chunk over the port.  The `interval` gap
-- is honoured BETWEEN completed chunks via a self-rearming one-shot timer, so
-- this stays a paced stream (not a burst) while reads run off-thread.  At most
-- one async read is in flight at a time; send_file closes the fd only between
-- completions, which the engine's async-aware file_close makes safe.
-- 句柄必须显式回收：引擎强引用 timers 数组直到 timer_stop，长文件几千个
-- 一次性定时器若不回收就是几千个常驻 uv handle。
local function schedule(ms, fn)
    if state.timer then
        sys.timer_stop(state.timer)
        state.timer = nil
    end
    state.timer = sys.timer_start(ms, fn)
end

local function stop_running(reason)
    state.running = false
    -- Clear the host interlock flag together with state.running: any_script_busy
    -- must go false the instant the stream is no longer active, or the host
    -- would keep refusing to start a sequence / auto-cycle forever.
    sys.busy(false)
    if state.timer then
        sys.timer_stop(state.timer)
        state.timer = nil
    end
    if reason then
        log.error("send_file", reason .. " at offset " .. state.offset)
    end
    refresh()
end

local issue_read      -- forward so the completion can re-arm

-- Kernel of one paced send step: issue exactly one non-blocking read at the
-- current offset; when it completes, send it and schedule the next chunk after
-- the user-chosen gap.
issue_read = function()
    if not state.running then return end
    if state.offset >= state.size then
        close_file()
        stop_running(nil)
        log.info("send_file", "done: " .. state.offset .. " bytes")
        return
    end
    local fd = state.fd
    local offset = state.offset
    local want = math.min(state.chunk, state.size - state.offset)
    if not fd then
        stop_running("file closed")
        return
    end
    -- Tag this flight so a late/stale completion (after Stop or a fd swap) is
    -- ignored instead of sending over the wrong file/offset.
    state.inflight = { fd = fd, offset = offset }
    local ok = sys.file_read_at_async(fd, offset, want, function(err, data)
        if not state.running then return end             -- stopped meanwhile
        if not state.inflight or state.inflight.fd ~= fd or
           state.inflight.offset ~= offset then return end -- superseded by a new flight
        state.inflight = nil
        if err or not data or #data == 0 then
            close_file()
            stop_running("read failed")
            return
        end
        -- Backpressure / transient refusal: a full TX queue (err_full, -5) and
        -- a scheduler downgrade (err_busy, -4) are both "wait a moment"
        -- conditions, not failures.  Retry the SAME chunk after `interval` so
        -- the line has time to drain/recover; only a real "not open" / "io"
        -- error aborts.  errcode comes from uart.send's second return value.
        local sent, errcode = uart.send(data)
        if not sent and (errcode == ERR_FULL or errcode == ERR_BUSY) then
            if state.stall_retries >= MAX_STALL_RETRIES then
                close_file()
                stop_running("retry limit reached: " ..
                    tostring(state.stall_retries) .. " retries rejected (" ..
                    tostring(errcode) .. ")")
                return
            end
            -- Do not advance offset; re-issue this chunk after the gap.
            state.stall_retries = state.stall_retries + 1
            schedule(state.interval, issue_read)
            return
        end
        state.stall_retries = 0   -- progress: a fresh budget for the next stall
        if not sent then
            close_file()
            stop_running("port error (" .. tostring(errcode) .. ")")
            return
        end
        state.offset = offset + #data
        refresh()
        schedule(state.interval, issue_read)
    end)
    if not ok then
        stop_running("read rejected")
    end
end

local step = issue_read   -- alias kept for the "Send" button path

ui.event = function(page, kind, widget, value)
    if kind == "click" and widget == "browse" then
        local path = sys.open_file()
        if not path then return end
        local size = sys.file_size(path)
        if not size or size <= 0 then
            log.error("send_file", "empty or unreadable: " .. path)
            return
        end
        local fd = sys.file_open(path)
        if not fd then
            log.error("send_file", "open failed: " .. path)
            return
        end
        stop_running(nil)
        close_file()   -- release a previously browsed (unsent) file's fd
        state.path, state.size, state.fd = path, size, fd
        state.offset = 0
        log.info("send_file", "loaded " .. basename(path) .. " (" ..
                 fmt_size(size) .. ")")
    elseif kind == "slider" and widget == "chunk" then
        state.chunk = math.max(1, tonumber(value) or state.chunk)
    elseif kind == "combo" and widget == "chunkidx" then
        local idx = (tonumber(value) or CHUNK_DEFAULT_IDX) + 1
        if CHUNK_ITEMS[idx] then
            state.chunk_idx = idx - 1
            state.chunk = CHUNK_ITEMS[idx]
        end
    elseif kind == "slider" and widget == "interval" then
        state.interval = math.max(1, tonumber(value) or state.interval)
    elseif kind == "click" and widget == "start" then
        if not state.fd then
            log.warn("send_file", "choose a file first")
            return
        end
        if not uart.is_open() then
            log.warn("send_file", "port not open")
            return
        end
        state.offset = 0
        state.running = true
        state.stall_retries = 0
        -- Publish the stream to the host for the WHOLE run, not just while a
        -- timer is armed: between two chunks the one-shot timer is stopped but
        -- an async read (and the next send) is still in flight, and that window
        -- is exactly where a naive "is a timer running?" probe would misjudge.
        sys.busy(true)
        schedule(0, step)
    elseif kind == "click" and widget == "resume" then
        -- Continue from wherever the previous run stopped. The fd was left
        -- open by stop_running/stop, and offset already points at the first
        -- byte the peer has not seen.
        if not state.fd then
            log.warn("send_file", "no file loaded")
            return
        end
        if not uart.is_open() then
            log.warn("send_file", "port not open")
            return
        end
        state.running = true
        state.stall_retries = 0
        -- Same stream-lifetime publication as Send: the host interlock must
        -- block a batch sender while a resumed transfer is mid-flight.
        sys.busy(true)
        schedule(0, step)
    elseif kind == "click" and widget == "stop" then
        -- Keep offset AND fd: a resume needs to read from the same handle, and
        -- reopening the file would lose the position for files being written
        -- by another process. close_file() happens on completion or on browse.
        stop_running(nil)
        log.info("send_file", "stopped at " .. state.offset .. "/" ..
                 fmt_size(state.size))
    end
    refresh()
end
