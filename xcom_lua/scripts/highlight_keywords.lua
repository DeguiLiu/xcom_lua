-- highlight_keywords.lua - 高亮示例：关键词着色（文字色 + 背景色两种风格）
-- @name 关键词高亮
-- @desc 为 ERROR/WARN/OK/timeout 等关键词着色，演示文字色与背景色两种高亮样式。
-- 依赖 Phase 4 的 xcom_imgui.dll 高亮渲染；旧 DLL 下规则静默不显示。
--
-- highlight.rule(pattern, color, style)
--   pattern : 明文子串（非正则）
--   color   : 0xRRGGBB 数字
--   style   : "text"=彩色文字（默认） / "bg"=半透明背景色块

highlight.rule("ERROR", 0xE53935)          -- 红
highlight.rule("WARN",  0xFFB300, "text")  -- 琥珀
highlight.rule("FAIL",  0xE53935)
highlight.rule("OK",    0x2E7D32, "text")  -- 绿
highlight.rule("timeout", 0xE53935, "bg")  -- 背景色块风格
