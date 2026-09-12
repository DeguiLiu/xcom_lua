-- filter_log_level.lua - 日志等级过滤示例
-- @name 日志等级过滤
-- @desc 只保留含 ERROR/WARN/FATAL 的行，屏蔽其余行，演示 filter.keep 白名单过滤。
-- 只保留含 ERROR/WARN 的行（其余行从显示中隐藏；自动保存日志仍记录原始字节）。
--
-- filter.keep(...)  只保留命中任一关键词的行（白名单）
-- filter.drop(...)  丢弃命中任一关键词的行（黑名单）
-- 两者可组合：先白名单后黑名单。等级过滤只是关键词过滤的特例。

filter.keep("ERROR", "WARN", "FATAL")
-- 只想排除噪声行时，改用：
-- filter.drop("DEBUG", "TRACE")
