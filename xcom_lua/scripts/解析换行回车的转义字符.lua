-- 解析换行回车的转义字符.lua - 发送转换插件
--   （移植自 llcom user_script_send_convert/解析换行回车的转义字符.lua）
-- @name 发送转义字符还原
-- @desc 把输入中的字面量 \r \n \t 转义序列还原成真正的控制字符后再发送。
-- 这样可以在发送框里直接写 "AT\r\n"，实发的是 AT + 回车 + 换行，
-- 而不是 4 个可见字符。比「发送追加换行回车」更灵活：换行位置由你控制。
--
-- 例：输入 AT\r\n -> 实发 41 54 0D 0A
--     A\tB      -> 实发 41 09 42
--
-- 只识别反斜杠 + r/n/t 三种转义；其余反斜杠原样保留。

on.send(function(uartData)
    local out = uartData:gsub("\\r", "\r"):gsub("\\n", "\n"):gsub("\\t", "\t")
    return (out)   -- 括号只取 gsub 的第一个返回值（丢弃替换计数）
end)
