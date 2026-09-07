-- Reproduce the exact bug: timestamp inserted mid-line when a device prompt
-- arrives without a trailing newline, then a command is echoed with one.
--
-- Scenario (from the user's screenshot):
--   device sends "msh/g"        (no trailing newline - prompt)
--   user types   "echo 1\r\n"  (echoed back WITH newline)
-- Expected (timestamp on):  each timestamped line starts with [HH:MM:SS.mmm]
--   and a mid-line command echo should NOT get a timestamp glued to it.
--
-- Usage: runtime\luajit.exe tests\test_ts_midline.lua [COMport]
--        no port arg -> VIRTUAL (hardware-free in-process session,
--        xcom_abi.cpp is_virtual_port); the test only feeds bytes through
--        xcom_test_inject_rx, so no physical endpoint is required.

local ffi = require("ffi")
ffi.cdef[[void Sleep(unsigned long ms);]]
local script = (arg and arg[0]) or "tests/test_ts_midline.lua"
local tests_dir = script:match("^(.*)[/\\]") or "."
local root
if tests_dir == "tests" then
    root = "."
else
    root = tests_dir:gsub("[/\\]tests$", "")
end
package.path = root .. "/core/?.lua;" .. package.path
local xcom = require("xcom_ffi")

local port = (arg and arg[1]) or "VIRTUAL"
local handle, err = xcom.create()
assert(handle, err)
local function finish(code)
    xcom.close(handle, 2000)
    xcom.destroy(handle)
    os.exit(code or 0)
end

-- open
local rc = tonumber(xcom.open_async(handle, port, 115200, 8, 0, 0, 0, false, false))
if rc ~= xcom.ok then print("open_async failed " .. rc); finish(1) end
local opened = false
for _ = 1, 40 do
    local s = xcom.get_snapshot(handle)
    if s and s.port_state == xcom.port_open then opened = true break end
    local r = tonumber(xcom.take_open_result(handle))
    if r ~= xcom.ok and r ~= xcom.err_busy then break end
    ffi.C.Sleep(50)
end
if not opened then print("could not open " .. port); finish(1) end

-- enable timestamp, text view
xcom.set_options(handle, { hex_view = false, timestamp = true,
    pause_display = false, auto_clear_bytes = 0, max_display_bytes = 2*1024*1024 })

local function drain_all()
    local out = ""
    for _ = 1, 200 do
        local st, text = xcom.drain_display(handle, 65536)
        if st ~= xcom.ok or not text or #text == 0 then break end
        out = out .. text
    end
    return out
end

-- Feed the exact byte sequence the device produces.
-- 1) prompt "msh/g" with NO trailing newline (this is where the bug shows)
xcom.test_inject_rx(handle, "msh/g", 5)
ffi.C.Sleep(30)
-- 2) user command echo "echo 1\r\n" WITH trailing newline
xcom.test_inject_rx(handle, "echo 1\r\n", 8)
ffi.C.Sleep(30)
-- 3) command output + next prompt (no newline)
xcom.test_inject_rx(handle, "1\r\nmsh/g", 8)
ffi.C.Sleep(30)

local captured = drain_all()
print("=== captured (raw, | = newline) ===")
print(captured:gsub("\r\n", "|"):gsub("\n", "|"):gsub("\r", "|"))
print("=== hex-ish view of first 80 bytes ===")
local shown = 0
for i = 1, #captured do
    local b = captured:byte(i)
    io.write(string.format("%02X ", b))
    shown = shown + 1
    if shown % 16 == 0 then io.write("\n") end
    if shown >= 80 then break end
end
print("")

-- Assertions:
-- (a) every timestamp prefix "[HH:MM:SS.mmm] " must be at offset 0 or right
--     after a \n or \r.  A mid-line timestamp is THE bug.
local bad = 0
local i = 1
while i <= #captured do
    if captured:sub(i, i) == "[" and captured:sub(i+1, i+2):match("^%d%d")
       and captured:sub(i+8, i+8) == ":" then
        -- found a timestamp start; check it is at a line boundary
        if i > 1 then
            local prev = captured:byte(i - 1)
            if prev ~= 10 and prev ~= 13 then  -- not \n or \r
                bad = bad + 1
                print(string.format("MID-LINE TIMESTAMP at offset %d: prev=%d context='%s'",
                    i, prev, captured:sub(math.max(1, i-8), i+8)))
            end
        end
    end
    i = i + 1
end

-- (b) the echoed command "echo 1" must appear exactly once (not split by a
--     spurious newline injection).
local echo_count = select(2, captured:gsub("echo 1", ""))

-- (c) a separator newline may be inserted BEFORE a mid-line timestamp, but it
--     must not corrupt the visible command text.
print(string.format("mid-line timestamps: %d (must be 0)", bad))
print(string.format("'echo 1' occurrences: %d (must be 1)", echo_count))

local verdict = (bad == 0 and echo_count == 1) and "PASS" or "FAIL"
print("VERDICT: " .. verdict)
finish(verdict == "PASS" and 0 or 1)
