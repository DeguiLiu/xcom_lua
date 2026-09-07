-- send_convert_demo.lua - 发送转换示例（LLCOM 发送转换脚本风格）
-- 在每次手动发送的载荷前加上序号前缀，方便设备端对账。
-- on.send 钩子返回 nil 会取消本次发送。

local seq = 0

on.send(function(payload)
    seq = seq + 1
    return string.format("[#%03d] ", seq) .. payload
end)
