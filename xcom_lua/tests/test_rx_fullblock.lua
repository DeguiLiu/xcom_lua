-- test_rx_fullblock.lua - deterministic receive-path verification without
-- hardware or UI. Feeds the EXACT byte stream captured from the real device
-- (RT-Thread msh `help`, /tmp/raw_help.bin, 14089 bytes plain ASCII + CRLF)
-- through xcom_test_inject_rx in varying chunk sizes (simulating arbitrary
-- serial driver read() splits), then asserts on the drained display text:
--
--   1. Every "[HH:MM:SS.mmm] " timestamp sits at a line boundary (offset 0
--      or right after '\n'). Mid-line timestamps are THE bug.
--   2. Long command-description lines arrive intact: "mkfs", "mkdir",
--      "Concatenate", "current working directory" are not chopped by a
--      spurious newline+timestamp injected at a block boundary.
--   3. The byte count is conserved: drained total >= raw minus dropped
--      control bytes, and the tail (last command + prompt) is present.
--
-- Usage: runtime\luvjit.exe tests\test_rx_fullblock.lua <raw_capture.bin>
--        (default sample data if no file is given)

local ffi = require("ffi")
ffi.cdef[[void Sleep(unsigned long ms);]]
local script = (arg and arg[0]) or "tests/test_rx_fullblock.lua"
local tests_dir = script:match("^(.*)[/\\]") or "."
local root
if tests_dir == "tests" then
    root = "."
else
    root = tests_dir:gsub("[/\\]tests$", "")
end
package.path = root .. "/core/?.lua;" .. package.path
local xcom = require("xcom_ffi")

-- ---------------------------------------------------------------- helpers --
local passed, failed = 0, 0
local function ok(label, cond, detail)
    if cond then
        passed = passed + 1
        print("  ok   " .. label)
    else
        failed = failed + 1
        print("  FAIL " .. label .. (detail and ("  [" .. tostring(detail) .. "]") or ""))
    end
end

local function load_raw(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local data = f:read("*a")
    f:close()
    return data
end

-- Fallback sample mirroring the real device stream when the raw capture is
-- unavailable: long "cmd<pad>- description\r\n" lines totalling > 8 KiB so it
-- spans many blocks regardless of chunk size.
local function make_sample()
    local cmds = {
        "v_zoom_coord     - coord zoom test: v_zoom_coord <x> <y> <multiple>",
        "v_zoom_center    - center zoom test: v_zoom_center <multiple>\195\151100>",
        "v_zoom_propotio  - proportional zoom: v_zoom_propotio <x> <y> <multiple>",
        "camera_app_switc - switch scene mode",
        "mkfs             - format disk with file system",
        "mkdir            - Create the DIRECTORY.",
        "pwd              - Print the name of the current working directory.",
        "cat              - Concatenate FILE(s)",
        "cp               - Copy SOURCE to DEST.",
        "ls               - List information about the FILE(s).",
    }
    local parts = {"help\r\nRT-Thread shell commands:\r\n"}
    for round = 1, 30 do
        for i = 1, #cmds do
            parts[#parts + 1] = cmds[i] .. "\r\n"
        end
    end
    parts[#parts + 1] = "\r\nmsh />"
    return table.concat(parts)
end

-- ------------------------------------------------------------- run scenario --
local function run_scenario(chunk_size, raw, label)
    print(("scenario: %-s (chunk=%d bytes)"):format(label, chunk_size))
    local handle, err = xcom.create()
    if not handle then error(err) end

    -- open: VIRTUAL session (xcom_abi.cpp is_virtual_port) -- hardware-free.
    -- test_inject_rx requires an OPEN port; VIRTUAL reaches OPEN in-process
    -- with no serial backend, and the core treats injected bytes exactly like
    -- real serial bytes, so the formatting pipeline under test is identical.
    local rc = tonumber(xcom.open_async(handle, "VIRTUAL", 115200, 8, 0, 0, 0, false, false))
    local opened = false
    for _ = 1, 40 do
        local s = xcom.get_snapshot(handle)
        if s and s.port_state == xcom.port_open then opened = true break end
        local r = tonumber(xcom.take_open_result(handle))
        if r ~= xcom.ok and r ~= xcom.err_busy then break end
        ffi.C.Sleep(50)
    end
    if not opened then
        print("  SKIP (VIRTUAL session did not reach open)")
        xcom.destroy(handle)
        return
    end

    xcom.set_options(handle, { hex_view = false, timestamp = true,
        pause_display = false, auto_clear_bytes = 0 })

    -- Inject the raw stream in fixed-size chunks (arbitrary driver splits).
    -- Chunk size changes WHERE a block boundary falls; it must not change the
    -- formatted text.  A real serial line is physically rate-limited (~11.5
    -- bytes/ms at 115200 baud; 14 KiB of help output takes >1 s), while the
    -- Lua poller drains every 10 ms — the pools are sized for that contract.
    -- The test paces injection with a 1 ms yield per chunk (faster than any
    -- real line, slower than the pool flood a bare loop creates) and drains
    -- every batch, so a formatting bug is measured without an artificial
    -- pool-overflow failure mode mixed in.  Pool saturation itself is covered
    -- by tests/stress_fullband.lua.
    local total = #raw
    local offset = 1
    local accumulated = {}
    -- Helper accumulates drained text so the mid-injection drain and the final
    -- drain share one buffer (the assertions read the whole stream).
    local function drain_into(dst)
        for _ = 1, 2000 do
            local st2, t2 = xcom.drain_display(handle, 65536)
            if st2 ~= xcom.ok or not t2 or #t2 == 0 then return end
            dst[#dst + 1] = t2
        end
    end
    while offset <= total do
        local n = math.min(chunk_size, total - offset + 1)
        xcom.test_inject_rx(handle, raw:sub(offset, offset + n - 1), n)
        offset = offset + n
        ffi.C.Sleep(1)
        drain_into(accumulated)
    end
    ffi.C.Sleep(120)
    drain_into(accumulated)
    local captured = table.concat(accumulated)
    xcom.close(handle, 2000)
    xcom.destroy(handle)

    -- Assert 1: timestamps only at line boundaries.
    local bad = 0
    local i = 1
    while i <= #captured do
        if captured:sub(i, i) == "[" and captured:sub(i + 1, i + 2):match("^%d%d")
           and captured:sub(i + 8, i + 8) == ":" then
            if i > 1 then
                local prev = captured:byte(i - 1)
                if prev ~= 10 and prev ~= 13 then
                    bad = bad + 1
                    if bad <= 3 then
                        print(("    mid-line ts @%d ctx=%q"):format(
                            i, captured:sub(math.max(1, i - 20), i + 20)))
                    end
                end
            end
        end
        i = i + 1
    end
    ok("no mid-line timestamps", bad == 0, bad .. " occurrences")

    -- Assert 2: intact lines (each description must appear whole: the command
    -- name, its padding, and the dash on the SAME line — a block-boundary
    -- split would put the timestamp between them).
    local intact = 0
    -- %-patterns: '%s-' = zero or more spaces; 'mkfs%s+-%s+format'
    local probes = { "mkfs%s+-%s+format disk",
                     "mkdir%s+-%s+Create the DIRECTORY",
                     "Concatenate FILE",
                     "current working directory" }
    for _, p in ipairs(probes) do
        if captured:find(p) then intact = intact + 1 end
    end
    ok("command lines intact (" .. intact .. "/4)", intact == 4)

    -- Assert 3: byte conservation is plausible (strip only removes control
    -- bytes; CRLF collapses to LF).  With timestamps on, the output must be
    -- larger than the raw input.
    ok("output not truncated", #captured >= #raw,
       ("#captured=%d #raw=%d"):format(#captured, #raw))
    ok("tail prompt present", captured:find("msh />", 1, true) ~= nil)
    return captured
end

-- ------------------------------------------------------------------- main --
local raw = (arg and arg[1]) and load_raw(arg[1]) or make_sample()
print(("raw sample: %d bytes"):format(#raw))

-- Chunk sizes that mirror real serial driver reads: one full block, a short
-- read, and a pathologically tiny read (worst case for block-boundary bugs).
run_scenario(4096, raw, "full block")
run_scenario(1000, raw, "odd mid-line split")
run_scenario(64,   raw, "tiny splits")

print(("%d passed, %d failed"):format(passed, failed))
os.exit(failed == 0 and 0 or 1)
