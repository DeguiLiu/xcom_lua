-- 时间戳前缀.lua - 接收转换插件示例
-- @name 接收行时间戳前缀
-- @desc 给每一行接收数据加上 [HH:MM:SS.mmm] 时间戳前缀，便于定位事件先后。
--
-- 例：收到  "OK\r\nERROR\r\n"
--     显示为 "[09:31:07.412] OK\r\n[09:31:07.413] ERROR\r\n"
--
-- 注意：内置显示管线已有「时间戳」功能（间隔阈值 [display] timestamp_gap_ms，
-- 默认 200 ms，只在每段首行打一个戳）。本脚本仅作 on.receive 转换插件的**示例**，
-- 二者同时启用会**重复打戳**——请只在需要「逐行打戳」这种内置功能不提供的语义时
-- 启用本脚本，并关闭内置时间戳。
--
-- 说明：
--   * 每行取本机当前时间（sys.now() 毫秒级）；同一批数据的多行时间戳会略有差异，
--     符合串口分帧到达的实际观感；
--   * 只影响显示，自动保存的原始日志仍记录未加前缀的字节（落盘由 C++ 原始字节
--     通道独占，Lua 不再写 RX 日志）；
--   * 跨批次续行不重复打戳：一行被读到一半时，后续批次的续接内容不再加前缀。
--     内置的整行缓冲已经保证脚本只会收到整行，这里的 mid_line 逻辑对上游半行
--     仍有兜底作用（但正常情况下不再触发）。

-- 上一批是否停在行中（mid-line）。true 表示下一批的开头是续行，不再打戳。
local mid_line = false

local function stamp()
    local now = sys.now()
    return string.format("[%s.%03d] ",
        os.date("%H:%M:%S", math.floor(now / 1000)), now % 1000)
end

on.receive(function(text)
    if text == "" then
        return text
    end
    local out = {}
    -- 本批开头若不是续行，先补一个行首前缀。
    if not mid_line then
        out[#out + 1] = stamp()
    end
    -- 按 \n 切分，逐段搬运；只有确认 \n 之后还有内容时才给下一行打戳，
    -- 这样结尾的 \n 不会留下一个没有行的前缀。
    local cursor = 1
    while true do
        local nl = text:find("\n", cursor, true)
        if nl == nil then
            break
        end
        out[#out + 1] = text:sub(cursor, nl)
        if nl < #text then
            out[#out + 1] = stamp()
        end
        cursor = nl + 1
    end
    if cursor <= #text then
        out[#out + 1] = text:sub(cursor)   -- 残行：本批结束在行中
        mid_line = true
    else
        mid_line = false                   -- 恰好停在 \n 之后
    end
    return table.concat(out)
end)
