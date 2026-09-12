-- 大小写转换.lua - 接收转换插件（UartAssist / SSCOM 常见功能）
-- @name 接收大小写转换
-- @desc 把接收到的英文字符统一转成大写（或小写），便于与协议文本比对。
-- 通过下方 MODE 常量切换：
--   "upper" = 全部转大写（默认）
--   "lower" = 全部转小写
--
-- 例：MODE="upper" 时收到 "ok\r\n" -> 显示 "OK\r\n"。
-- 说明：仅转换 ASCII 英文字母，中文/数字/控制字符不受影响。

local MODE = "upper"   -- 可选 "upper" / "lower"

on.receive(function(text)
    if MODE == "lower" then
        return text:lower()
    end
    return text:upper()
end)
