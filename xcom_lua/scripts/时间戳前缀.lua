-- 时间戳前缀.lua - 接收转换插件（UartAssist / SSCOM 常见功能）
-- @name 接收行时间戳前缀
-- @desc 给每一行接收数据加上 [HH:MM:SS.mmm] 时间戳前缀，便于定位事件先后。
--
-- 例：收到  "OK\r\nERROR\r\n"
--     显示为 "[09:31:07.412] OK\r\n[09:31:07.413] ERROR\r\n"
--
-- 说明：
--   * 每行取本机当前时间（sys.now() 毫秒级）；同一批数据的多行时间戳会略有差异，
--     符合串口分帧到达的实际观感；
--   * 只影响显示，自动保存的原始日志仍记录未加前缀的字节；
--   * 未以换行结尾的残行也会被加上前缀，若随后续批拼接可能重复加，属可接受折衷。

local function stamp()
    local now = sys.now()
    return string.format("[%s.%03d] ",
        os.date("%H:%M:%S", math.floor(now / 1000)), now % 1000)
end

on.receive(function(text)
    -- 给每段非换行内容加前缀，保留原有 \n 结构
    local out = text:gsub("[^\n]+", function(line) return stamp() .. line end)
    return (out)
end)
