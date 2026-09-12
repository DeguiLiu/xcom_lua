-- scope_demo.lua - exercise the in-dashboard ImPlot oscilloscope panel.
-- @name 双通道示波器
-- @desc 解析 "$S1,12.5" 格式的行，把两个通道画成实时曲线，演示 wave 示波器面板。
--
-- Scripts reach the scope surface through the `wave` module (core/waveform.lua
-- dual-renders every wave.push into the native ImPlot panel via
-- xcom_imgui_scope_push).  The new ui/imgui_bridge.lua wrappers
-- (scope_clear / scope_configure / scope_set_visible) back the same C exports
-- and are driven by the host; here we show the script-facing path.
--
-- There is no standalone Scope page/header chip: the panel appears as soon as
-- this script pushes its first point (window.lua watches wave activity) and
-- hides a couple of seconds after the last push.  Disable this script to hide
-- the panel for good.
--
-- Run: enable this script in the Lua console, then feed the receive view with
-- lines like "$S1,12.5" "$S2,-3.0".

wave.config({
    title = "Scope Demo",
    series = {
        { name = "S1", color = 0x00CC66 },
        { name = "S2", color = 0x3399FF },
    },
})

on.receive(function(text)
    for ch, value in text:gmatch("%$S(%d),([%-%d%.]+)") do
        local index = tonumber(ch)
        if index == 1 or index == 2 then
            wave.push(index, tonumber(value) or 0)
        end
    end
    return text
end)

-- No wave.show() call: the in-dashboard panel appears automatically on the
-- first push above (wave.show() would instead open the detached GDI popup).
log.info("scope_demo", "$S1/$S2 lines are now plotted on the ImPlot scope")
