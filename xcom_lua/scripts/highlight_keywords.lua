-- highlight_keywords.lua - 高亮示例：关键词着色（文字色 + 背景色两种风格）
-- @name 关键词高亮
-- @desc 为 ERROR/WARN/OK/timeout 等关键词着色，演示文字色与背景色两种高亮样式。
-- 依赖 Phase 4 的 xcom_imgui.dll 高亮渲染；旧 DLL 下规则静默不显示。
--
-- highlight.rule(pattern, color, style)
--   pattern : 明文子串（非正则）
--   color   : 0xRRGGBB 数字
--   style   : "text"=彩色文字（默认） / "bg"=半透明背景色块

-- 文字色按白色接收区实测的 WCAG 对比度选取（AA 正文需 4.5:1）：旧的红
-- 0xE53935 只有 4.23:1，琥珀 0xFFB300 只有 1.79:1（白底上几乎看不见），
-- 故改为 0xC62828（5.62:1）与 0x8A6D00（4.92:1）；绿 0x2E7D32 本就
-- 5.13:1，保留。
highlight.rule("ERROR", 0xC62828)          -- 红 5.62:1
highlight.rule("WARN",  0x8A6D00, "text")  -- 暗琥珀 4.92:1
highlight.rule("FAIL",  0xC62828)
highlight.rule("OK",    0x2E7D32, "text")  -- 绿 5.13:1
highlight.rule("timeout", 0xC62828, "bg")  -- 背景色块风格（0.35 alpha 色块）
