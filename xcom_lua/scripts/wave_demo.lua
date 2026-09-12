-- wave_demo.lua - 波形显示示例
-- @name 双通道波形显示
-- @desc 解析 "$CH0,1.23" 格式的协议行，把数值推入波形窗口绘制实时曲线。
-- 解析形如 "$CH0,1.23" / "$CH1,0.5" 的协议行，把数值推入波形窗口。
--
-- wave.config{ series = { {name="CH0", color=0x00CC66}, ... } }
-- wave.push(series_index_or_name, y)   -- x 自动取时间
-- wave.push(series, x, y)              -- 显式 x
-- wave.show() / wave.hide() / wave.snapshot([path])   -- 独立 GDI 弹窗
--
-- 说明：内置仪表盘的 ImPlot 波形面板由脚本活跃度自动开关（首次 push 出现，
-- 停止 push 后隐藏），无需调用 show()；这里的 wave.show() 只用于额外弹出
-- 一个可截图/回看的独立 GDI 窗口。若只要面板曲线，删掉下面这行 show() 即可。
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
