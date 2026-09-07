-- auto_reply.lua - 自动应答示例（LLCOM 自动回复.lua 风格）
-- 收到以 "AT" 结尾的行时自动回复 "OK\r\n"。
-- on.receive 钩子返回 nil 会把该批从显示中隐藏；这里原样返回文本。

on.receive(function(text)
    if text:find("AT\r?\n") or text:match("^AT\r?\n?$") then
        sys.timer_start(10, function()
            uart.send("OK\r\n")
        end)
        log.info("auto_reply", "AT detected -> OK")
    end
    return text
end)
