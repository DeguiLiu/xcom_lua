-- 绘制曲线-多条.lua - 接收转换插件（移植自 llcom user_script_recv_convert/绘制曲线-多条.lua）
-- @name 双通道数值曲线
-- @desc 解析 "值1,值2" 行，分别画到曲线0 / 曲线1（逗号分隔，一次两个点）。
-- 数据格式约定：每行两个以逗号分隔的数值，行尾可带 \r\n；不足两个或非数值时忽略。
--     1.5,2.5
--     -3,10
-- 曲线编号 0 起（0 = 第一条）；曲线面板由脚本活跃度自动开关。
--
-- 与「数值行绘制曲线」的区别：本脚本只认「恰好两个逗号分隔值」的帧，
-- 适合一次上报两路采样的设备；需要 3~4 路时用「数值行绘制曲线」。

on.receive(function(uartData)
    -- 按换行符切开，防止粘包
    local data = uartData:split("\r\n")
    for i = 1, #data do
        local two = data[i]:split(",")
        if #two == 2 then
            local n1 = tonumber(two[1])
            local n2 = tonumber(two[2])
            if n1 and n2 then
                apiAddPoint(n1, 0)   -- 曲线0
                apiAddPoint(n2, 1)   -- 曲线1
            end
        end
    end
    -- 原样输出（曲线是旁路，不影响接收显示）
    return uartData
end)
