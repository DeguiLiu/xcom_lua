-- 加上换行回车.lua - 发送转换插件（移植自 llcom user_script_send_convert/加上换行回车.lua)
-- @name 发送追加换行回车
-- @desc 发送前在数据末尾追加 CR LF（"\r\n"），方便 AT 等按行解析的设备。
-- 无条件追加：若你输入的文本已经带 \r\n，会再加一份。需要防止重复追加时，
-- 可改用「发送转义字符还原」脚本，在输入里写 \r\n 由脚本还原。
--
-- 例：输入 "AT" -> 实发 41 54 0D 0A。

on.send(function(uartData)
    return uartData .. "\r\n"
end)
