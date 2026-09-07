-- scope_demo.lua - exercise the in-dashboard ImPlot oscilloscope panel.
--
-- Scripts reach the scope surface through the `wave` module (core/waveform.lua
-- dual-renders every wave.push into the native ImPlot panel via
-- xcom_imgui_scope_push).  The new ui/imgui_bridge.lua wrappers
-- (scope_clear / scope_configure / scope_set_visible) back the same C exports
-- and are driven by the host; here we show the script-facing path.
--
-- Run: enable this script in the Lua console, then feed the receive view with
-- lines like "$S1,12.5" "$S2,-3.0".  The Scope header chip toggles the panel.

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

wave.show()
log.info("scope_demo", "$S1/$S2 lines are now plotted on the ImPlot scope")
