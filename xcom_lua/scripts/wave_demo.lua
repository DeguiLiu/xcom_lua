-- wave_demo.lua - 波形显示示例
-- 解析形如 "$CH0,1.23" / "$CH1,0.5" 的协议行，把数值推入波形窗口。
--
-- wave.config{ series = { {name="CH0", color=0x00CC66}, ... } }
-- wave.push(series_index_or_name, y)   -- x 自动取时间
-- wave.push(series, x, y)              -- 显式 x
-- wave.show() / wave.hide() / wave.snapshot([path])
--
-- 无硬件时可用 preview_rx.lua + 示例流查看效果。

wave.config({
    title = "XCOM Waveform",
    series = {
        { name = "CH0", color = 0x00CC66 },
        { name = "CH1", color = 0x3399FF },
    },
})

on.receive(function(text)
    for ch, value in text:gmatch("%$CH(%d),([%-%d%.]+)") do
        local index = tonumber(ch)
        if index == 0 or index == 1 then
            wave.push(index + 1, tonumber(value) or 0)
        end
    end
    return text
end)

wave.show()
log.info("wave_demo", "$CH0/$CH1 lines are now plotted")
