-- 数据截断.lua - 接收转换插件（UartAssist / SSCOM 常见功能）
-- @name 接收行截断
-- @desc 超过设定字节长度的接收行截断并追加省略号，避免超长行刷屏卡顿。
--
-- MAX_LEN 为每行保留的字节数（默认 256），超出部分替换为 "..."。
--     收到 300 字节的一行 -> 显示前 256 字节 + "..."
--
-- 说明：
--   * 只影响显示；自动保存的原始日志仍记录完整字节；
--   * 截断以字节计，多字节中文可能被切在半个字符上，属可接受；
--   * 只想过滤而非截断长行时，用 filter.drop / filter.keep 更合适。

local MAX_LEN = 256

on.receive(function(text)
    local out = text:gsub("[^\n]+", function(line)
        if #line > MAX_LEN then
            return line:sub(1, MAX_LEN) .. "..."
        end
        return line
    end)
    return (out)
end)
