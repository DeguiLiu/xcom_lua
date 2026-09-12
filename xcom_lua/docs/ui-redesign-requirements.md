# XCOM Lua 仪表盘重设计 — 需求汇总

> 本文档汇总历次对话中用户提出的全部需求，作为 UI 重设计与功能实现的工作依据。
> 更新日期：2026-09-04（第 3 次更新：新增 LLCOM 式 Lua 脚本系统与串口助手功能需求）

---

# 第 3 轮新增需求（2026-09-04）：Lua 脚本系统 + 串口助手功能

## 9. 核心需求：LLCOM 式 Lua 脚本系统

> 用户原话：「参考 ref/llcom-master 把 lua 脚本集成进去，比如高亮特定的词汇，只保留含有
> 某些关键词的日志，保留某种等级的日志，过滤某些等级的日志，等等。lua 脚本还可以做一些
> 其它的功能，任由你发挥」

| # | 需求 | 状态 |
|---|------|------|
| 9.1 | **关键词高亮**：高亮接收日志中的特定词汇（如 ERROR 红色） | 🔄 Lua 侧规则引擎已实现；C++ 渲染待 Phase 4 |
| 9.2 | **关键词保留**：只保留含有某些关键词的日志行 | ✅ `filter.keep(...)` |
| 9.3 | **等级保留**：保留某种等级的日志（ERROR/WARN 等） | ✅ 等级=关键词特例 |
| 9.4 | **等级过滤**：过滤掉某些等级的日志 | ✅ `filter.drop(...)` |
| 9.5 | 其它脚本功能「任由发挥」 | 🔄 uart.send / on.receive / on.send / log / sys 定时器 / wave / apiUtf8ToHex 已实现 |

用户确认的设计决策（AskUserQuestion 答复）：
- **高亮样式**：两种都支持——彩色文字（默认）+ 背景色块（`style="bg"`），每条规则可选
- **脚本编辑器**：内嵌 ImGui 编辑器（Ctrl+S 保存、热重载）+ 外部编辑器按钮；
  脚本列表 + 启用勾选 + 运行日志面板 + 单行 REPL 齐备

## 10. 串口助手功能需求

> 用户原话（编号列表）：「1. 接收串口数据并显示。可选"字符串"或"HEX"。2 中文显示无乱码，
> 支持多种字符编码（如：ASCII, GB2312, UNICODE, UTF-8, BIG5, shift_jis）。3. 支持多种预设
> 波特率（>115200bps需要硬件支持），同时支持自定义波特率。4. 支持扩展命令，预设命令，方便
> 调试。5. 自定义命令列表：将多条要发送的命令组合成一个列表，一次点击即可自动执行所有命令。
> 6. 自动断帧：在接收数据包间有时间间隔时自动换行，方便观测。7. 使用lua实现波形显示功能：
> 协议数据可显示为波形，支持波形回看和截图。」
> 补充：「lua弹出界面显示波形，很多可以通过luajit实现」

| # | 需求 | 状态 |
|---|------|------|
| 10.1 | 接收显示，字符串/HEX 切换 | ✅ 已有（receive_hex） |
| 10.2 | **多字符集中文显示**（ASCII/GB2312/UNICODE/UTF-8/BIG5/SHIFT-JIS） | 🔄 core/charset.lua 转码已实现（34 测试过）；CJK 字体渲染待 Phase 4 |
| 10.3 | **自定义波特率** | 🔄 Lua 侧 serial_config custom 优先已实现；C++ Custom InputInt 待 Phase 4 |
| 10.4 | 预设命令 | ✅ 多页快捷发送（8 槽 × 50 页） |
| 10.5 | **命令列表顺序执行**（一次点击 + 间隔） | 🔄 Lua 侧 Run 序列（uv 定时器链）已实现；C++ Run 按钮待 Phase 4 |
| 10.6 | **自动断帧**（包间时间间隔自动换行） | ⏳ Phase 5 core 侧（ABI v1.4 frame_gap_ms） |
| 10.7 | **Lua 波形显示**（回看 + 截图） | ✅ 脚本驱动：`core/waveform.lua` 的 `wave.push` 同时喂 ImPlot 面板；面板无独立入口，由脚本活跃度自动开关（首次 push 出现，静默约 2s 隐藏）。另提供独立 GDI 弹窗（`wave.show()`，含拖拽回看/F12 BMP 截图） |

## 11. 参考资源指引（用户指定）

| 指令 | 产出 |
|------|------|
| 「曲线绘制可以参考 pic\3.png」 | `core/waveform.lua` 视觉模型（示波器风格：黑底网格、多通道彩色曲线、通道标签+实时值） |
| 「pic\2.png 也可以参考，用来 lua 设置颜色、高亮和过滤等」 | 高亮/过滤规则设计参考 |
| 「imgui/examples 你要好好参考」×3 →「派 subagent 研究 ref/imgui/examples」 | `docs/imgui-patterns-reference.md`（v2 更新中） |
| 「使用 subagents 研究 ImHex」 | `docs/imhex-patterns-reference.md`（已完成：8 节，97 处行号引用） |
| 「使用 subagents 研究 implot_demos」 | `docs/implot-demos-reference.md`（生成中） |
| 「我们有 luajit，绘图可以找一些开源组件，C/C++ 的也可以，Lua 封装调用即可」 | ImPlot v1.1 WIP 克隆至 `third_party/xcom_imgui/implot`，Phase 4 静态链入 xcom_imgui.dll（与 ImGui 1.93 WIP 同代，API 匹配验证过） |
| 「charset.lua 在 ref 目录应该有封装的吧」→「去网上寻找 charset.lua」 | ref 内 winapi_wcs.lua 仅 UTF-8↔UTF-16；网上方案（lua-iconv/luautf8 等）与自研同模式（LuaJIT FFI 直调 MultiByteToWideChar 936/950/932/1200），自研保留并增强（跨批 DBCS 位置感知挂起、UTF-16 代理对） |

## 12. 实现架构（已批准计划，摘要）

- **Phase 1-3 纯 Lua（已完成）**：script_engine.lua（沙箱/钩子/行过滤/规则聚合，50 测试）、
  waveform.lua（GDI 示波器）、bmp_writer.lua、charset.lua（34 测试）、示例脚本 ×5
- **Phase 4 ImGui DLL（待做）**：接收区高亮渲染（ImHex 三层绘制模式：AddRectFilled 背景 +
  PushStyleColor 前景）、Script Console 浮窗（官方 ExampleAppConsole 模式 + InputTextMultiline
  CallbackResize + ImGui::Shortcut Ctrl+S）、Custom 波特、Run/gap 控件、charset/断帧控件、
  CJK 字体（GlyphRangesBuilder，栈上 builder + Runtime 持有 ranges 的生命周期模式）、
  ImPlot 示波器面板（ScrollingBuffer + ImPlotSpec.Offset/Stride + DragLineX 游标）
- **Phase 5 Core DLL（待做）**：ABI v1.4 XcomDisplayOptions.frame_gap_ms（16→20 字节，
  struct_size>=16 双向兼容）+ rx_format_block 断帧插行

关键契约：
- 接收漏斗：drain → log_append(**原始字节**) → charset.convert → scripts:process_rx
  （on.receive → 行过滤）→ _append_imgui_receive
- 行过滤半行契约：只裁决完整行，pending 挂起；8 KiB 强冲 / 200ms 空闲冲 / 关闭即冲
- Action 位：27=Script Console 开关、28=Run 序列；charset/断帧复用 ActionSyncDisplay(1<<8)
- 所有新 xcom_imgui_* 导出 Lua 符号探测守卫，旧 DLL 优雅降级
- 脚本模型：可信本地脚本（LLCOM 同款）、pcall 隔离、连败 3 次自动禁用钩子

## 13. 新增配置键（config.ini）

| 节 | 键 | 默认 | 状态 |
|----|----|------|------|
| [script] | enabled | "" | ✅ |
| [script] | autorun_console | false | ✅（读）/Phase 4（开关） |
| [script] | auto_reload | false | ✅ |
| [display] | charset | "ASCII" | ✅ |
| [display] | frame_gap_ms | 0 | ✅（读）/Phase 5（core） |
| [serial] | baud_custom | 0 | ✅（读）/Phase 4（UI） |
| [send] | multi_gap_ms | 100 | ✅（读）/Phase 4（UI） |
| [font] | mono_cjk | true | ⏳ Phase 4 |

## 14. 脚本 API（当前可用）

```lua
uart.send(data) / uart.send_hex("01 A2") / uart.is_open()
on.receive(fn)   -- fn(text) -> text' | nil(丢弃该批，仅显示侧)
on.send(fn)      -- fn(payload) -> payload' | nil(取消发送)
filter.keep(...) / filter.drop(...) / filter.clear()
highlight.rule(pattern, color_0xRRGGBB, "text"|"bg") / highlight.clear()
log.trace/debug/info/warn/error/fatal(tag, ...)   print(...)
sys.now() / sys.timer_start(ms,fn) / sys.timer_loop_start / sys.timer_stop
wave.config{...} / wave.push(series,x|y) / wave.show/hide/clear/set_follow/snapshot
apiUtf8ToHex(str) / apiAscii2Utf8(bytes)          -- GB2312 <-> UTF-8
string.toHex/fromHex/split/utf8Len
_SCRIPT / _PATH
```

示例脚本（xcom_lua/scripts/）：highlight_keywords / filter_log_level / auto_reply /
wave_demo / send_convert_demo

## 15. 测试

| 测试 | 断言 | 状态 |
|------|------|------|
| test_script_engine.lua | 50 | ✅ |
| test_charset.lua | 34 | ✅ |
| test_wave_ring.lua | 18 | ✅ |
| 既有（config/ansi/view_model/xcom_ffi/rx_fullblock） | — | ✅ 无回归 |
| test_frame_gap.lua | — | ⏳ Phase 5 |

---

# 第 1-2 轮需求（既有记录，视觉重设计）

## 1. 总体目标

参考外部串口工具截图（`pic/1.png`、`pic/2.png`、`pic/3.png`、`pic/4.png`、`pic/5.png`），
对 xcom_lua 的 ImGui 仪表盘做**全方位重设计**：

- **线条**（分隔线样式、位置、粗细、颜色）
- **配色**（每个区域的背景色、文字色、强调色）
- **对齐**（控件栅格、左边缘对齐、列对齐）
- **图标**（工具栏图标风格、来源）
- **布局**（面板分区、比例、排布）

用户原话（核心验收标准）：

> "我需要的线条、配色、对齐、图标和布局全方面对齐。就是一个左右的差别而已，
> 当然咱们没有的功能不要强行对齐。"

### 核心约束

1. **保持右侧栏布局** —— 咱们现有"左主区 + 右侧栏"的结构不变。
   参考图是"左工具栏 + 右内容区"，与咱们是**左右镜像关系**，
   借鉴的是风格而非方位。
2. **功能不能少，只可以多** —— 所有现有控件/功能必须保留：
   - 接收区：HEX/Time/Hold/Clear/Save 开关、自动清空阈值、日志路径/保存/清除、
     拖选复制、右键菜单、自动滚动
   - 发送区：Single/Multi 页签、8 槽位多页、HEX/NEWLINE/AUTO、周期、Loop、
     端口开关、串口参数、DTR/RTS
3. **没有的功能不要强行对齐** —— 只借鉴参考图中与咱们功能对应的部分。

## 2. 视觉规格

**完整规格见 `docs/reference-tool-design-spec.md`**（从 2.png/5.png 像素级提取）。
要点：

| 元素 | 规格 |
|---|---|
| 窗口底色 | `#F8F9FD` 蓝调白 |
| 接收 log 底 | `#F9F9FB` 中性白 |
| 发送编辑器底 | `#F8F8F0` **黄调白**（参考图特征） |
| 发送主按钮 | **纯绿 `#008000`**，圆角 8px，白字，大尺寸 |
| 时间戳 | 橙 `#FF7C24` 系 |
| TX 回显数据 | 红 `#F04C4D` 系 |
| RX 数据 | 近黑 `#101010` |
| HEX 字节高亮 | 品红 `#D010D0` |
| 面板分隔 | 20px 间隙 + 双线（深 `#8A8A8C` + 浅 `#EBE9EA`），**无硬边框** |
| 图标 | 线性描边 `#13161D`，1.5-2px 线宽 |
| 复选框 | 13-16px，1px 深边框，选中灰填充 |
| 工具栏活动芯片 | 浅蓝 `#DAE6FE` |
| 侧栏参数栅格 | 标签列右对齐 + 值列统一左边缘，行距 ~60px |

## 3. 已确认的设计决策

1. **范围**：配色 + 线条 + 布局微调（非推翻布局）。
2. **蓝色做选中高亮**（`#005A9E` 选中底色）。
3. **橙色做时间戳/标记**（`[HH:MM:SS.mmm]` 前缀着色，已实现）。
4. **发送区按钮排布**：方案 B —— 工具行在编辑器上方 + 大 Send 按钮
   （Single 页签右侧 96×48；参考图是通栏大绿按钮，已改为绿色 `#008000`）。
5. **面板底色分区**：接收区中性白 / 发送区黄调白 / 侧栏同窗口底色。

## 4. 差距清单（第二轮回设计，进行中）

- [x] 绿色大 SEND 按钮（`#008000`，圆角 8px，白字）—— SendAction() 已实现
- [x] 发送编辑器黄调白 `#F8F8F0` 底 —— FrameBg push 已实现
- [x] 面板间隙 20px + 双线分隔（去侧栏硬边框）—— 已实现
- [x] 橙色校正（`#B36B00` → `#E8681A`，参考 `#FF7C24` 的可读折中）
- [x] 接收 log 底色 `#F9F9FB`（was `#FEFEFE`）
- [ ] 工具栏浅蓝芯片按钮样式（`#DAE6FE` 底）→ Toggle ON 态
- [ ] 侧栏参数栅格对齐（标签右对齐 + 值列左对齐）
- [ ] TX 数据红色回显（新功能：发送内容回显到 log 时着红色）
- [ ] HEX 视图字节品红高亮（可选）
- [ ] 图标按参考风格统一 1.8px 线宽线性描边（现有 IconButton 已接近）

## 5. 参考资源（全部已下载到位）

| 资源 | 位置 | 状态/产出 |
|---|---|---|
| 参考截图 ×5 | `pic/1.png` ~ `pic/5.png` | 设计规格来源 |
| 官方 ImGui 仓库 | `ref/imgui/`（examples + docs） | 第 3 轮：`docs/imgui-patterns-reference.md` v2 更新中；第 2 轮：`docs/imgui-examples-reference.md` |
| ImHex | `ref/ImHex/` | 第 3 轮完成：`docs/imhex-patterns-reference.md` |
| implot_demos | `ref/implot_demos/` | 第 3 轮：`docs/implot-demos-reference.md`（生成中） |
| ImPlot 库源码 | `third_party/xcom_imgui/implot/`（v1.1 WIP） | 已克隆，Phase 4 编入 DLL |
| imgui-filedialog | `ref/imgui-filedialog/` | 已克隆 |
| cplayer | `ref/cplayer/` | 已克隆 |
| luajitImGui | `ref/luajitImGui/`（817 entries） | 已下载解压 |

## 6. 工程侧需求（用户在对话中提出的检查项）

以下已核实**无需改动**（现有代码已满足）：

1. **串口独占打开**：`serial_backend_win.cpp:84` `CreateFileW(..., 0U, ...)` share=0 独占。
2. **RAII 句柄**：`port_`/`*_event_` 均为 RAII 封装，失败路径统一 `close()`；
   线程终止由 stop_event 驱动；无泄漏风险。
3. **运行时统计**：footer 已有 RX/TX 字节计数。

可选增强（未排期）：
- 端口枚举时探测占用状态，下拉框标注 "busy"
- "强制关闭"配置项

## 7. 实施状态

第一轮（已完成，BUILD_OK + DLL 已部署）：
- [x] palette/kStyleColors/footer 常量换肤
- [x] 时间戳橙色前缀着色（15 字节 `[HH:MM:SS.mmm]` 检测 + draw_list 覆盖绘制）
- [x] Single 页签方案 B（工具行在上 + 右侧 Send）
- [x] Multi 页签（HEX/NEWLINE 上移 + Separator + 底部操作行）
- [x] legacy Win32 PAL 同步

第二轮（本节，BUILD_OK，待截图验证）：
- [x] SendAction 绿色大按钮（Single 96×48 / Multi 72×26）
- [x] 发送编辑器黄调白 FrameBg
- [x] 面板 20px 间隙 + 双线 + 侧栏去边框
- [x] palette 更新（kSendGreen/kTxRed/kTimestamp 校正/kSurfaceData 黄调白）
- [ ] 侧栏栅格对齐、Toggle ON 芯片色、TX 红色回显
- [ ] 构建 + 截图 + 与参考图对比验证

## 8. 相关文档

- `docs/reference-tool-design-spec.md` — 参考工具完整设计规格（像素级）
- `docs/imgui-patterns-reference.md` — 官方 examples + ImPlot demo 模式研究（本轮 agent 产出，v2）
- `docs/imhex-patterns-reference.md` — ImHex 研究与采纳清单（本轮 agent 产出）
- `docs/implot-demos-reference.md` — implot_demos 研究（本轮 agent 产出）
- `docs/imgui-examples-reference.md` — 官方 examples 研究（第 2 轮 agent 产出）
- `docs/uartassist-feature-analysis.md` — 功能对比分析（既有）
- `docs/receive-selection-highlight.md` — 选中高亮实现记录（既有）
