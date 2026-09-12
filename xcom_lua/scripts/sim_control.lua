-- sim_control.lua - serial DATA simulator control page (plugin UI).
-- @name 串口模拟器控制
-- @desc 独立插件窗口控制内置串口数据模拟器：选profile、调速率、启停。无硬件时使用。
--
-- Drives core/serial_sim.lua through the host-injected `sys.sim` closure set
-- (script_engine exposes it ONLY when the simulator auto-activated, i.e. this
-- machine has no real COM ports).  On a hardware host sys.sim is nil and this
-- page degrades to an inert "SIM inactive" notice.
--
-- Workflow (no hardware):
--   1. Open a SIM port (sidebar combo: "VIRTUAL" or "TESTLOOP"); the host
--      arms the 20 ms pump automatically on the OFFLINE -> OPEN edge.
--   2. Enable this script (Script Console) -> header "Set" chip ->
--      "SIM Control" tab.
--   3. Pick a Profile + Rate and Start/Stop; bytes flow through the REAL
--      display pipeline (hex/timestamp/pause/charset/script hooks/scope).
--
-- spec grammar (one widget per line; wid = [A-Za-z0-9_.-]):
--   title:TEXT / slider:wid:label:min:max:default / combo:wid:label:idx:a|b|c
--   button:wid:label
--
-- ALL page strings are English on purpose: the ImGui body font only ships the
-- glyph set the C++ bridge's Lang strings need, so Chinese here would tofu.

local PROFILES = { "text", "gb2312", "hexbin", "modbus", "at-modem", "wave", "echo" }
local DEFAULT_PROFILE_IDX = 0    -- "text"
local RATE_MIN = 64
local RATE_MAX = 65536
local DEFAULT_RATE = 1024        -- bytes/s

local sim = sys.sim

-- The combo/slider widgets carry their own echo state so a re-declared spec
-- renders the current selection (the C++ side resets on every push).
local state = {
    profile_idx = DEFAULT_PROFILE_IDX,
    rate = DEFAULT_RATE,
}

local function refresh()
    if not sim then
        ui.page("sim", "SIM Control",
            "title:SIM inactive - real serial ports present")
        return
    end
    local running = sim.is_running()
    local status
    if running then
        status = "RUNNING  profile=" .. PROFILES[state.profile_idx + 1] ..
            "  rate=" .. state.rate .. " B/s"
    else
        status = "STOPPED  (open a VIRTUAL/TESTLOOP port, then Start)"
    end
    local lines = {
        "title:" .. status,
        "combo:profile:Profile:" .. state.profile_idx .. ":" ..
            table.concat(PROFILES, "|"),
        "slider:rate:Rate B/s:" .. RATE_MIN .. ":" .. RATE_MAX .. ":" .. state.rate,
    }
    if running then
        lines[#lines + 1] = "button:stop:Stop"
    else
        lines[#lines + 1] = "button:start:Start"
    end
    ui.page("sim", "SIM Control", table.concat(lines, "\n"))
end

refresh()   -- declare the page on load

ui.event = function(page, kind, widget, value)
    if not sim then return end
    if kind == "combo" and widget == "profile" then
        local idx = (tonumber(value) or state.profile_idx) + 1
        if PROFILES[idx] then
            state.profile_idx = idx - 1
            if not sim.profile(PROFILES[idx]) then
                log.warn("sim_control", "unknown profile: " .. tostring(PROFILES[idx]))
            end
        end
    elseif kind == "slider" and widget == "rate" then
        local bps = tonumber(value) or state.rate
        bps = math.max(RATE_MIN, math.min(RATE_MAX, math.floor(bps)))
        state.rate = bps
        sim.set_rate(bps)
    elseif kind == "click" and widget == "start" then
        if not uart.is_open() then
            log.warn("sim_control", "open a SIM port (VIRTUAL/TESTLOOP) first")
            refresh()
            return
        end
        sim.set_rate(state.rate)
        sim.profile(PROFILES[state.profile_idx + 1])
        -- Re-arm the pump; pass no port so it keeps the one the host recorded
        -- when it auto-started on connect (falls back to VIRTUAL).
        if sim.start() then
            log.info("sim_control", "started profile=" ..
                PROFILES[state.profile_idx + 1] .. " rate=" .. state.rate)
        else
            log.warn("sim_control", "start refused (no core handle)")
        end
    elseif kind == "click" and widget == "stop" then
        sim.stop()
        log.info("sim_control", "stopped")
    end
    refresh()
end
