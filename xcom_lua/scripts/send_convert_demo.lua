-- send_convert_demo.lua - 发送转换示例（LLCOM 发送转换脚本风格）
-- @name 发送序号前缀
-- @desc 在每次发送的数据前加上 [#序号] 前缀，演示 on.send 发送转换钩子。
-- 在每次手动发送的载荷前加上序号前缀，方便设备端对账。
-- on.send 钩子返回 nil 会取消本次发送。

local seq = 0

on.send(function(payload)
    seq = seq + 1
    return string.format("[#%03d] ", seq) .. payload
end)
