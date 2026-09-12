-- 绘制曲线-解析结构体.lua - 接收转换插件
--   （移植自 llcom user_script_recv_convert/绘制曲线-解析结构体.lua）
-- @name 结构体帧解析曲线
-- @desc 解析 [uint8][int32][float] 二进制帧，把三路数值分别画到曲线0/1/2。
--
-- 帧格式（小端，共 9 字节负载 + 1 字节包尾 0x0A）：
--   offset 0   uint8      -> 曲线0
--   offset 1   int32 LE   -> 曲线1
--   offset 5   float LE   -> 曲线2   (IEEE-754 单精度)
--   offset 9   0x0A 包尾
--
-- 例（曲线值 5、1000、1.5 的一帧）：
--   05 E8 03 00 00 00 00 C0 3F 0A
--
-- 说明：LuaJIT 没有 Lua 5.3 的 string.unpack，这里用工程内置的 struct 模块
-- （libs/protocol/struct.lua，注入为全局 struct）。llcom 原文用 '<Blf'，
-- 其中 l 在本 struct 实现里是 8 字节，故改用 4 字节的 '<Bif'，含义见上。
-- struct 模块缺失时脚本静默跳过（不影响接收显示）。

local FRAME_LEN = 1 + 4 + 4   -- uint8 + int32 + float

on.receive(function(uartData)
    if not struct then return uartData end
    -- 按包尾 0x0A 切开，防止粘包
    local frames = uartData:split(string.char(0x0A))
    for i = 1, #frames do
        local frame = frames[i]
        if #frame == FRAME_LEN then
            local ok, u8, i32, f32 = pcall(struct.unpack, "<Bif", frame)
            if ok then
                apiAddPoint(u8, 0)
                apiAddPoint(i32, 1)
                apiAddPoint(f32, 2)
            end
        end
    end
    return uartData
end)
