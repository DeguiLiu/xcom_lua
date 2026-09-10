-- 绘制曲线.lua - llcom "绘制曲线" 示例的等价脚本。
--
-- 数据格式约定（与 llcom 一致）：
--   值\r\n               → 单条曲线，每行一个点
--   值1,值2\r\n          → 两条曲线（逗号分隔，最多 4 条）
--
-- 曲线编号为 0 起（0 = 第一条）。应用只提供 apiAddPoint(value, line)，
-- 解析逻辑完全由脚本决定 —— 与 llcom 的 LuaApi.md AddPoint 一致。
-- 数值行会被画成"值随时间"的滚动曲线；非数值行忽略。
--
-- 启用：在「脚本控制台」里勾选本脚本。之后向串口发送/接收形如
--   123
--   123,456
-- 的纯数值行即可看到曲线。

on.receive(function(uartData)
    -- 按换行符切开，防止粘包
    local data = uartData:split("\r\n")

    for i = 1, #data do
        local line = data[i]
        -- 单行可能是 "12" 或 "12,34"（多通道）
        local parts = line:split(",")
        for ch = 1, #parts do
            local value = tonumber(parts[ch])
            if value then
                apiAddPoint(value, ch - 1)   -- 曲线号 0 起
            end
        end
    end

    -- 原样输出（曲线是旁路，不影响接收显示）
    return uartData
end)

log.info("绘制曲线", "收到 值\\r\\n 或 值1,值2\\r\\n 即绘制曲线")
