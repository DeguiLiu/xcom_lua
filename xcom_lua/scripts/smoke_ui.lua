-- smoke_ui.lua - headless UI smoke driver for the ImPlot scope panel.
-- @name 示波器自动化冒烟
-- @desc 自动生成正弦/锯齿两路波形驱动示波器面板，供截图冒烟验证渲染链路。
--
-- Automated screenshot verification cannot synthesize mouse clicks into the
-- ImGui backend, so this script drives the scope from data instead: when
-- enabled (Lua script console, config [script] enabled, or the XCOM_SMOKE_*
-- env route in window.lua:_smoke_env_hooks), it pushes a 2-channel signal
-- every 20 ms through the same wave.push surface wave_demo.lua uses
-- (core/waveform.lua dual-renders each push into xcom_imgui_scope_push).  The
-- in-dashboard panel appears purely from this data flow — window.lua watches
-- wave activity (waveform.active()) and shows/hides the panel, so no show()
-- call is needed (wave.show() would instead pop the detached GDI window).
--
-- Channels: 1 = sine, 2 = ramping sawtooth; x is automatic (sys.now() ms).
-- A screenshot showing two live traces proves the scope render path works.

wave.config({
    title = "XCOM Smoke Wave",
    series = {
        { name = "SINE", color = 0x00CC66, min = -1.5, max = 1.5 },
        { name = "SAW",  color = 0x3399FF, min = -2.5, max = 2.5 },
    },
})

local TWO_PI = 2.0 * math.pi
local t0 = sys.now()

sys.timer_loop_start(20, function()
    local t = (sys.now() - t0) / 1000.0          -- seconds since start
    -- Channel 1: 0.5 Hz sine in [-1, 1].
    wave.push(1, math.sin(t * TWO_PI * 0.5))
    -- Channel 2: 0.25 Hz sawtooth in [-2, 2].
    local phase = (t * 0.25) % 1.0
    wave.push(2, phase * 4.0 - 2.0)
end)

log.info("smoke_ui", "scope smoke feed running (2 channels, 20 ms tick)")
