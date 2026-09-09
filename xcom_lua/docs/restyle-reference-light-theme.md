# ImGui 仪表板换肤方案：借鉴参考截图的浅色主题

> 状态：方案已批准，实施中（进度见文末）
> 日期：2026-09-04
> 参考：`D:\workspace\SSCOM_lua\pic\1.png`（其他串口工具截图，像素级配色分析）

## 1. 目标与约束

借鉴参考截图的**线条、布局和配色**，同时：

- **保持右侧栏布局不变**：180px 右侧栏、面板结构、全部控件原位
- **功能不能少，只可以多**：只做加法，不删任何控件/行为
- 顶栏深色（`#1E1E1E`）保留——品牌识别，仅其强调色跟随新蓝

## 2. 参考配色（从截图像素提取）

| 元素 | 颜色 |
|---|---|
| 接收区主背景 | `#FEFEFE` 纯白 |
| 侧栏/面板 | `#EEEEF0` ~ `#EFEFF1` 浅灰 |
| 数据区 | `#F7FDF9` 淡绿白 |
| 主文字 | `#1B1B1B` |
| 蓝（选中/激活/链接） | `#005A9E`，深变体 `#004275` |
| 红（错误/危险操作） | `#C50500` / `#D3413D` |
| 橙（时间戳/标记） | `#FFAA00` |
| 水平分隔线 | `#E6E6E6` 细浅线 |

## 3. 改动文件

| 文件 | 改动 |
|---|---|
| `xcom_lua/native/xcom_imgui/xcom_imgui_bridge.cpp` | 全部核心：配色常量、kStyleColors、时间戳渲染、footer、面板背景 |
| `xcom_lua/native/xcom_imgui/layout.toml` | `panel_gap` 0→6、`window_padding` 1→2 |
| `xcom_lua/assets/layout.toml` | 同上（保持三份副本一致；构建自动同步 runtime/assets） |
| `xcom_lua/ui/window.lua`（可选） | legacy 回退路径 PAL 同步换色 |

## 4. 实施步骤

### Step 1 — palette 命名空间换色（bridge.cpp 205-222 行 + 57 行）

| 常量 | 旧 | 新 | 用途 |
|---|---|---|---|
| `kPanelBorder` | `0x4B5A63` | `0xE0E0E2` | 面板细浅边框 |
| `kAccentTeal` | `0x0078B8` | `0x005A9E` | 参考蓝主色（品牌 chip、顶栏下划线、toggle-on、主按钮、Tab 激活、footer ONLINE） |
| `kAccentHover` | `0x168DCA` | `0x2E7FC4` | 主按钮 hover |
| `kAccentPress` | `0x005A8A` | `0x004275` | 主按钮按下 |
| `kTextHeading` | `0x006A9B` | `0x004275` | 区块标题 |
| `kTextMuted` | `0x5A6B7A` | `0x6B7280` | 标签/禁用文字（中性灰） |
| `kTextBody` | `0x1F2933` | `0x1B1B1B` | 正文 |
| `kSurfaceLight` | `0xF1F5F8` | `0xFEFEFE` | 接收卡片纯白 |
| `kSurfaceDefault` | `0xEDF3F7` | `0xEEEEF0` | 侧栏浅灰 |
| **新增** `kSurfaceData` | — | `0xF7FDF9` | 发送区淡绿 |
| **新增** `kTimestamp` | — | `0xFFAA00` | 时间戳橙 |

不变：`kHeaderDark`、`kHeaderChrome*`、`kTextInverse`、`kStatusOnline/Offline`、`kHeaderSubtitle`、`kToggleOff`。

### Step 2 — kStyleColors 表（bridge.cpp 1371-1400 行）

| Slot | 旧 | 新 |
|---|---|---|
| `Text` | `0x243746` | `0x1B1B1B` |
| `TextDisabled` | `0x5A6B7A` | `0x6B7280` |
| `WindowBg` | `0xE6EDF2` | `0xE9EAEC` |
| `ChildBg` | `0xEDF3F7` | `0xEEEEF0` |
| `Border` | `0xAAB7BF` | `0xDDDDDF` |
| `CheckMark` | `0x0078B8` | `0x005A9E` |
| `SliderGrab` / `GrabActive` | `0x0078D7`/`0x005A9E` | `0x005A9E`/`0x004275` |
| `Tab`/`TabUnfocused` | `0xEEF1F4` | `0xE6E8EA` |
| `TabActive`/`TabUnfocusedActive` | `0x0078B8` | `0x005A9E` |
| `ScrollbarBg` | `0xD8E2E9` | `0xE8EAEC` |
| `ScrollbarGrab` | `0x8FA9B9` | `0xC4C8CC` |
| `ScrollbarGrabHovered` | `0x6D8EA3` | `0xAEB4BA` |
| `ScrollbarGrabActive` | `0x0078D7` | `0x005A9E` |
| **新增** `TextSelectedBg` | （ImGui Light 默认蓝） | `0x005A9E` @ **0.35** |
| **新增** `Separator` | （Light 默认黑@0.14） | `0xE6E6E6` @ 1.0 |

关键点：
- `TextSelectedBg` 一行使 707 行 `GetColorU32(ImGuiCol_TextSelectedBg)` 的拖选矩形和所有 InputText 内部选中自动变参考蓝——**选中绘制代码零改动**
- `Separator` 一行使侧栏分隔线（1005/1024 行）、右键菜单分隔线自动变浅灰细线
- `FrameBg/Button/Header` 系列保持白系——浅灰面板上白输入框正是参考观感

### Step 3 — 清屏色 + footer + 危险按钮

- `kClearColor`（1403 行）：→ `{233/255, 234/255, 236/255}`（与 WindowBg 一致）
- Footer 背景（1095、1107 行）：`0xDCE7EE`/`0xD6E3EA` → 统一 `0xEFEFF1` 扁平
- Footer 顶边线（1109 行）厚度 `1.5f` → `1.0f` 发丝线；竖分隔（1104 行）`0xAFC1CC` → `0xE6E6E6`
- DangerAction 红系（1068-1070 行）：`0xC0392B/0xD9534F/0x962D22` → `0xC50500/0xD3413D/0x9E0400`（Close 端口按钮；接收路径无 TX 回显，红仅落此处）
- 图标按钮 hover（384 行）：`0xC9D7E0` → `0xDDE1E5`

### Step 4 — 时间戳橙色两段式渲染（核心）

背景：时间戳由 `xcom_core`（`xcom_ao.cpp` `rx_timestamp_prefix`）烤进接收缓冲，**固定 15 字节 `"[HH:MM:SS.mmm] "`，仅注入行首**。ImGui 侧目前整行 `TextUnformatted` 无差别着色。

改动（bridge.cpp 接收 clipper 循环 719-791 行）：

1. 新 helper `timestamp_prefix_length(begin, end)`：严格 mask 匹配 `[NN:NN:NN.NNN] `（`[` + 8 数字 + `::.` + `]` + 空格，10 次比较），命中返回 15，否则 0。数据驱动——Time 开关关闭时缓冲无前缀，无需开关联动
2. 循环内 766 行处：无前缀走原 `TextUnformatted`（热路径不变）；有前缀改为：
   - `draw->AddText(...)` 橙色画前 15 字节
   - `draw->AddText(...)` 正文色画余下（x 偏移 `15*glyph_w`）
   - `ImGui::Dummy(text_width, line_h)` 注册行 item
3. 颜色循环前提升一次：`ts_color` / `body_color`

**选中与拖选 hit-test 数学兼容性**（已逐条核实源码）：

| 路径 | 为什么不受影响 |
|---|---|
| 选中矩形 746-765 行 | 画在行 item 之前，用 `GetCursorScreenPos()` 行原点 + `from/to*glyph_w`——两种路径行原点相同 |
| 拖选 hit-test 770-788 行 | 用 `GetItemRectMin/Max`；`Dummy(text_width, line_h)` 的 item Min=行原点、y 范围=line_h，与文本 item 完全等价（且 `hit_offset_in_row` 只消费 rmin.x/rmin.y/rmax.y） |
| clipper | 每行仍恰好一个 item、cursor 前进 line_h——滚动范围不变 |
| hex 视图 | 行首同样 15 字节前缀（`xcom_ao.cpp` 276-284 行），1 字节=1 glyph，橙色同样适用 |

### Step 5 — 发送区淡绿背景

bridge.cpp 1580 行 `ui::Panel("##send_workspace", ...)` 增加背景参数 `rgb(palette::kSurfaceData)` → 发送区淡绿 `#F7FDF9`。与白接收区、浅灰侧栏形成三色分区。**右侧栏本身保持 `kSurfaceDefault` 浅灰不动**。

### Step 6 — 布局微调（加法）

- `layout.toml`（两份手工改，构建自动同步第三份）：`panel_gap = 0` → `6`、`window_padding = 1` → `2`（沟槽透出 WindowBg，参考截图的留白感）
- **伴生修正**（bridge.cpp 1573 行）：monitor_column 宽 `-sidebar_width + 1.0f` → `-sidebar_width - layout.panel_gap + 1.0f`，否则非零 gap 挤窄侧栏
- 不触碰 `sidebar_width`/`send_height`/`header_height` 及任何控件

### Step 7 —（可选）legacy PAL 同步

`window.lua` 50-61 行：`page 0xEEF1F4→0xE9EAEC`、`text 0x263238→0x1B1B1B`、`accent 0x0078D7→0x005A9E`、`danger 0xC40000→0xC50500`。仅影响无 ImGui 桥的回退路径。

## 5. 构建与验证

1. 重建 DLL：`cmd //c "D:\\workspace\\SSCOM_lua\\xcom_lua\\native\\xcom_imgui\\build_imgui.cmd"`
2. 部署：rust-coreutils `cp .../build/xcom_imgui.dll .../runtime/xcom_imgui.dll`
3. 离线验证时间戳橙（mock 行自带精确前缀，无需硬件）：`cd xcom_lua && runtime/luvjit.exe preview_rx.lua`
4. 客观 UI 审计：`"D:/Python314/python.exe" "C:/Users/Administrator/.claude/skills/xcom-ui-audit/scripts/audit.py"` → 读 `xcom_lua/audit.png`，检查 #E6E6E6 分隔线、无截断/重叠、footer 可读
5. 选中验证：拖选多行截图，确认 `#005A9E@35%` 高亮、橙色前缀内起拖偏移正确
6. Lua 冒烟：`runtime/luajit.exe tests/integration_test.lua`、`tests/test_view_model.lua`（ABI 未变）

## 6. 风险与回滚

| 风险 | 处置 |
|---|---|
| 橙 `#FFAA00` 白底对比度 ~1.9:1 偏低 | 用户指定色；若审计不可读，单点调暗 `palette::kTimestamp` → `~0xD68900` |
| Dummy-item hit-test 等价性 | 已分析等价 + 验证步骤 5 实测；最坏单独回滚 Step 4（无前缀路径与今日字节等价） |
| panel_gap 挤窄侧栏 | 1573 行伴生修正必做；否则保持 gap=0 |
| 选中蓝 @0.35 偏淡 | 单行调 alpha 0.45 |
| 浅边框弱化面板边界 | 面板靠背景对比（白/灰/绿）分区，正是参考观感 |

每步独立 commit（A: Step1-3 常量换肤 / B: Step4 时间戳 / C: Step5-6 背景+布局 / D: Step7 可选），可单独 revert；revert 后需重建+重拷 DLL。

## 7. 实施进度

- [x] Step 1 palette 常量换色（kPanelBorder / 命名空间 / 新增 kSurfaceData、kTimestamp）
- [x] Step 2 kStyleColors 表换色 + 新增 TextSelectedBg、Separator
- [x] Step 3 之 kClearColor（footer/DangerAction/icon-hover 尚未改）
- [ ] Step 3 剩余：footer、DangerAction、icon hover
- [ ] Step 4 时间戳橙色两段式渲染
- [ ] Step 5 发送区淡绿背景
- [ ] Step 6 layout.toml + 1573 行补偿
- [ ] Step 7 legacy PAL（可选）
- [ ] 构建 + 验证（预览/审计/选中/冒烟）
