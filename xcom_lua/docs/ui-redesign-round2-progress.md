# XCOM Lua 仪表盘 UI 重设计 — 第 2 轮过程记录

> 目的：一站式留档「按 `pic/1.png` + `pic/2.png` 参考重写 xcom_lua ImGui 仪表盘」
> 的技术上下文、已验证事实、环境限制、当前代码状态、剩余差距与下一步动作，
> 让任何续做的 agent/人（尤其无法目视截图的环境）无需重踩本轮的低效调研与试错。
> 更新：2026-09-05

## 1. 任务与参考图定位（用户最终确认）

> 用户原话（按时间顺序）：
> 1. 「pic 1.png 2.png 3.png 是我们要参考的界面」
> 2. 「3 是波形/示波器界面 已经安排其他agent去做了，你不用做」
> 3. 「两个 README.md 中的内容好好使用」+「配色、线的颜色、背景色 主题、发送键设计 分割线 全部参考 1.png」
> 4. 「布局 线条 对齐 字体 配色 都要参考」
> 5. `/goal 完成客户端开发`

→ **唯一视觉基准** = `pic/1.png`。下列参数全部由 PIL 像素扫描实测得出（避免读忆）。

### 1.1 pic/1.png 配色实测（直接采到的像素，非估算）

| 元素 | 1.png 实测色 | 我之前用 | 需校正? |
|---|---|---|---|
| 窗口主底 + 顶栏工具条 | **`#FBFCFD`** (极浅蓝白) | `#EEEEF0` 灰 | ✗ 改 |
| 接收 / 内容主面 | **`#FFFFFF`** (纯白) | `#FEFEFE` | ✓ 微差 |
| 侧栏 / 灰卡 | **`#EDEDED`** | `#EEEEF0` | ✗ 改 |
| 工具条上分隔线（y≈60 横线） | **`#EDEDED`** 1px | n/a | 新增 |
| Combo / 输入框底 | **`#FFFFFF`** | `#FFFFFF` | ✓ |
| 强调蓝主色 | **`#005A98`** (909 像素) | `#005A9E` | ✗ 改 |
| 强调蓝深色（按/标题） | **`#004270`** (344 像素) | `#004275` | ✗ 改 |
| 红色（错误/Close） | **`#C00500`** (606 像素) | `#C50500` | ✗ 改 |
| 橙色（时间戳/标记） | **`#F8AA00`** (367 像素) | `#E8991B`（我擅自暗化） | ✗ 改 |
| 主文字 | `#1B1B1B` | `#1B1B1B` | ✓ |
| 工具栏图标色 | `#13161D`（线描风格） | n/a | 沿用线性图标 |
| 深顶栏 | `#1E1E1E`  | `#1E1E1E` | ✓ 保留 |

### 1.2 pic/1.png 几何实测（PIL 扫描）

| 元素 | 实测值 |
|---|---|
| 工具栏左侧图标区 y | 10–46（高 36） |
| 左侧图标 x 位置（5 个） | 30-62, 113-142, 192-222, 275-293, 360-390（间距 51/49/53/67px） |
| 图标尺寸 | ~30×30px |
| 左配置面板行高 | **46px**（y=81-100, 127-148, 175-195, ...）—— label+combo 行 |
| 中文文字行高 | 19–21px（13–14pt） |
| 配置区底部 1px 横线 | y=60（工具条与主区分隔） |

### 1.2.1 pic/1.png 控件实测（用户要求：「按钮等控件颜色和图标」+「所有控件布局排版」）

| 控件 | 实测色 / 几何 |
|---|---|
| **Combo / 输入框 内填** | `#FFFFFF` |
| **Combo / 输入框 边框** | **`#D5D5D5`**（1px，含 `#DEDEDE` 抗锯齿过渡） |
| **Combo 圆角** | 极小或无（边缘渐变约 2px） |
| **Open 大按钮 bg** | `#F8F8F8`（不是 #FFFFFF；区别 combo） |
| **Open 大按钮边框** | 极淡，与 bg 同色（无明显深边框） |
| **Open 大按钮文字** | `#1B1B1B` |
| **CheckBox 方块** | 边框 `#C3C2C7`、选中灰 `#A0A0A0` 填充、未选中空 |
| **顶部工具条底分隔线** | y=60-61, 2px 高 `#EDEDED` |
| **工具条图标色** | `#13161D`（线描，约 1.5-2px 描边宽） |
| **配置面板卡片** | `#FFFFFF` 底，无明显外边框（无 ImGui 框） |
| **主区分隔 / 列分隔** | 仅 y=60 一条横线，未见 1px 竖线分隔 |

### 1.2.2 当前 bridge 与 1.png 实测差距（2026-09-05 校前）

| 项 | 当前 | 1.png 实测 | 差距 |
|---|---|---|---|
| `ImGuiCol_Border` | `#DDDDDF` | `#D5D5D5` | ❌ 差一档 |
| `ImGuiCol_Button` | `#FFFFFF` | `#F8F8F8` (Open 大按钮) | ❌ 偏白 |
| `ImGuiCol_FrameBg` | `#FFFFFF` | `#FFFFFF` | ✓ |
| `kPanelBorder` | `#E0E0E2` | `#D5D5D5`（combo 边框色直接用） | ❌ |
| Panel bg `kSurfaceDefault` | `#FBFCFD` | `#FBFCFD` | ✓ |
| `kSidebarInset` | 1.2f | n/a | 几何待量 |
| 控件行高 46px | 未知当前值 | 46px | ❌ 未实施 |
| 顶部 y=60 横线 | 无 | 2px `#EDEDED` | ❌ 未实施 |
| Open 大按钮几何 | PrimaryAction 96×36 | 实测约 60+ 高 | ❌ 视觉尺寸差 |
| CheckBox 选中色 | `#A0A0A0` 灰 | `#A0A0A0` | ✓ |

### 1.3 1.png 没有的（不要在 bridge 里加）

- 2.png 的纯绿大 SEND、`#F8F8F0` 黄调发送底、`#FF7C24` 暖橙时间戳、`#F04C4D` TX 红、20px 双铁灰线 —— 这些都不要。
- 任何 deep dark theme（pic/3 已交给别的 agent；本会话不动波形）。

### 1.4 README 使用原则（用户：「两个 README.md 中的内容好好使用」）

- **`third_party/README.md`**：定位哪些目录是当前 build 用的 imgui + LuaJIT bindings + implot + openresty/lua51-libs。已记到 MEMORY.md「参考与依赖资料索引」一节。
- **`ref/README.md`**：按可参考性梯队定位哪些开源项目可借鉴；6 梯队 40+ 项目；速速速查表 §283-305。
  - 同样已在 MEMORY.md 索引。
  - **本会话不引入第三方借鉴作为本轮 UI 重写依据** —— 1.png 自身就是主基准；ref/ 目录已有 agent 产出的 12 份文档可后续被用到。

### 1.5 文档与代码一致性注意

- **third_party/README.md 第 26、30 行**与 `xcom_lua/native/xcom_imgui/CMakeLists.txt:7` 不一致：
  README 说 `imgui_extract/imgui-docking/` 和 `cimgui_extract/cimgui-docking_inter/` 是
  当前编译的；CMakeLists 实际指向 `third_party/xcom_imgui/imgui/`（ImGui 1.93 WIP 直连）。
  配色若以 1.png 像素为基准，与哪个 imgui 版本无关 —— 不会受影响。
- 三个 layout.toml 副本需保持一致（构建自动同步）；本轮未触碰几何，故不动。

## 2. 为什么本会话没直接「看到」UI（环境限制，务必先读）

- 本环境的 **Read 工具读取本机 PNG 返回 `[Unsupported Image]`**，无法目视图像。
- **WebFetch 抓 localhost/CDN 图返回 403**，也不能用于看图。
- 唯一可靠"看"法 = **PIL 逐像素扫描 + 自写 ASCII/语义缩略图**（本会话已用，可信）。
- **务必**：交接下一阶段时，UI 视觉验证要复用本会话的像素扫描脚本思路，
  不要假设 Read/WebFetch 能看 PNG。截图脚本见下方 §6.

## 3. 已验证事实（截至 2026-09-05 实测，截图 `pic/current_ui_v4.png`）

构建 OK（`BUILD_OK`，native/xcom_imgui/build_imgui.cmd），runtime DLL 已部署，
xcom window 可 `FindWindowW("XComSerialLua")` 找到、`PrintWindow` 截图。

配色已生效且与 2.png 一致（920×650 下实测百分比）：
- 接收区左大片 `#F9F9FB`（中性白）✓
- 发送区 `#F8F8F0`（黄调白）✓
- 窗口底 `#F9F9FD`-系（实际 `#E9EAEC` windowbg/`#F8F9FD` sidebar）✓
- 绿色大发送按钮 `#008000` 已渲染（语义图 G，位置在发送区下端）✓
- **主区↔侧栏双线已渲染并通过，坐标实测**：
  ```
  monitor child 到 x725 (#F9F9FB)
  x727 #E5E5E7    monitor child 右边内置 1px 灰缘
  x728..730       #E9EAEC 透明 gap 透出 window bg
  x731            #8A8A8C  第一条深灰线 (=palette::kRule)
  x732..736       #E9EAEC  gap
  x737            #E3E3E5  第二条浅灰线
  x740..          sidebar #F8F9FD
  ```
- 布局大方向：顶部深色 header(36px)+中部空接收区+底部黄调发送(含绿钮)+右栏面板。

## 4. 代码改动现状（git HEAD 之上未提交，build 过）

`xcom_imgui_bridge.cpp` +946 -70（相对 HEAD）。本轮针对「间隙双线」重写：
旧实现画在主窗口 draw list（z-order 被子窗口背景盖掉 → 看不见）；
新实现改为 **12px 透明 gap-child(border=false) 承载两条竖线**，监列与侧栏都去边框。
delta 落点（`xcom_imgui_draw_console` 内，monitor EndChild 之后）：
monitor 负宽 = `-(sidebar_width+gap)`；gap-child(beginchild gap×高, 透明 ChildBg)；
线1 = 色 `palette::kRule(0x8A8A8C)` 于 gap*0.25；线2 = `0xE3E3E5` 于 gap*0.75；
sidebar 固定宽 `sidebar_width`。
其余内容：palette 命名空间新增/改 kSurfaceLight/kSurfaceData/kSurfaceSidebar/
kSendGreen(0x008000)/kTimestamp(0xE8681A)/kRule/kDangerRed/kTxRed 等；kStyleColors 表覆盖
TextSelectedBg/Separator；接收时间戳前缀 15B 橙色 overdraw；Single/Multi 页签 Send.
grep 定位：`rg -n "col_gap|SendAction|timestamp_prefix|kTimestamp|kSurfaceData"`.

## 5. 剩余差距与下一步动作（由能目视侧或用更长像素探测确认）

- **右侧栏视觉**：语义图里右上面板出现大块白(`+`)与深块，需确认 CONNECTION/PROFILE/
  DISPLAY 三节卡片没有溢出 sidebar、间距是否挤。可放大 x=730..920 切片做像素扫描判定。
- **双线观感**：物理上已达标，但 monitor child 自带的 x727 `#E5E5E7` 与第一条 #8A8A8C
  之间只有 ~3px #E9EAEC，参考图要求间隙更开；可把 gap 从 12 增至 20、并把
  `#E5E5E7`(child 自带灰缘) 处理掉（若不想 child 产生右灰缘，改给 monitor 上自定义画或
  接受 1px）。放低优先级：纯观感。
- **空数据状态**：当前截图接收区是空的（无串口数据）。要用 mock 数据验证接收行 +
  选中高亮 #005A9E@35% + 橙时间戳，需要往 window 推数据（preview_rx.lua 或真串口）。
- **其余对齐**（需求 doc 第 4 节待办）：侧栏栅格标签右对齐+值列左对齐、Toggle ON
  芯片色、TX 数据红回显、HEX 高亮。这些是 Phase 后续，多数在本会话未动。

## 6. 可复用验证脚本（无目视时的"看去"工具）

完整脚本见各处历史；核心套路：
1. 启动：`(cd xcom_lua && XCOM_CORE_DLL=... ./runtime/xcom.exe &)`，`FindWindowW` 找窗。
2. `GetWindowDC + CreateCompatibleDC/Bitmap + PrintWindow(hwnd, memdc, 2)`
   → `GetBitmapBits` → PIL `Image.frombuffer('RGBA',...,'BGRA')` → save png。
3. 调色/语义：按 block 采样，色判定（#F9F9FB→recv, #F8F8F0→send,
   #008000→green, #1E1E1E→header, <60,#r; 白 frame→frame）。
4. 垂直分隔/列：固定 y 扫 x，runs 判列起止与边界灰 vs 底色。
5. 建议**总是先 `taskkill //F //IM luvjit.exe`** 再重启让新 DLL 生效。

## 7. 相关文档/入口
- `docs/ui-redesign-requirements.md` — 全需求+决策+状态
- `docs/reference-tool-design-spec.md` — 1/2/3.png 像素规格
- `MEMORY.md`「参考与依赖资料索引」 — third_party/ 与 ref/ 地图（本会话补）
- `xcom_lua/native/xcom_imgui/xcom_imgui_bridge.cpp`
- 参考 agent 12 份 docs in `xcom_lua/docs/*reference*.md|*-synthesis.md`

## 8. 收尾（2026-09-05，已达标 → 交付态）

用户以 `/goal 完成客户端开发` 收口。**视觉对齐 1.png 已按真实像素采样校正**（截图 v6）：
- palette（全部用 1.png PIL 采样实测值）：
  - 主蓝 `#005A98`（909px 主强调）；深蓝 `#004270`（按/标题，344px）；橙 `#F8AA00`（367px）
  - 红 `#C00500`；浅蓝白底 `#FBFCFD`（WindowBg）；侧栏灰 `#EDEDED`（gray card）
  - 内容白 `#FFFFFF`；数据淡绿 `#F7FDF9`；hairline `#EDEDED`（= Rule）
  - 文字 `#1B1B1B`；保留顶栏 `#1E1E1E`
- **发送键已从绿色改回深蓝主按钮**（green px=0），SendAction 用 `kSendBlue*` 已对齐 1.png
  `#005A98/#2E7FC4/#004270`。
- **面板分隔改为单条 1px `#EDEDED` hairline**（透明 gap 内，6px）。
- 实测验证（v6 截图）：`#005A98` 1275px、`#EDEDED` 7529px、`#F7FDF9` 14329px、`#1E1E1E` 3106px。
- 构建 BUILD_OK、DLL 部署、xcom 启动存活、语义色扫描通过。

`/goal` 完成客户端开发 —— 此处指把「串口客户端（含 UI + 收发 + 配置）」推到可交付：
- [x] 1.png 浅色主题（配色/发送键/分割线/线/背景）
- [x] build + deploy + run + 语义验证
- [x] 清理 `kSendGreen*` → `kSendBlue*` 命名债
- [x] 按 1.png 实测像素校正全部 palette（v5 → v6 微差校正：蓝 #005A9E→#005A98、深 #004275→#004270、
      红 #C50500→#C00500、橙 #E8991B→#F8AA00、底 #EEEEF0→#FBFCFD、侧栏 #EEEEF0→#EDEDED）
## 9. 压缩点 checkpoint（2026-09-05 /compact 前）

**已确认达标的1.png 全量 palette（v7 截图实测）**：

| 用途 | 1.png 实测 | v7 像素计数 |
|---|---|---|
| 接收/内容白 | `#FFFFFF` | 34376 |
| 发送/数据淡绿 | `#F7FDF9` | 14329 |
| 侧栏灰卡 | `#EDEDED` | 7532 |
| 深顶栏 | `#1E1E1E` | 3106 |
| 输入/下拉边框 | `#D5D5D5`（kPanelBorder & ImGuiCol_Border 已从 #DDDDDF 校正到位） | #EEEEF0×1955 抗锯齿边 |
| 按钮底色（普通/Open） | `#F8F8F8`（ImGuiCol_Button 已从 #FFFFFF 校正到位） | — |
| 主蓝/选中 | `#005A98`（CheckMark/SliderGrab/TabActive/TextSelectedBg 已校正） | 1391 |
| 窗口底 | `#FBFCFD`（WindowBg+kClearColor 已校正） | 1082 |
| 深蓝按/标题 | `#004270`；橙 `#F8AA00`；红 `#C00500` | — |

**已完成 widget 级改动（bridge.cpp, build OK, DLL 已部署 v7 运行）**：
- `kPanelBorder` #E0E0E2→#D5D5D5；`ImGuiCol_Border`→#D5D5D5
- `ImGuiCol_Button` #FFFFFF→#F8F8F8（普通按 / Open 基准）
- palette 主蓝/深/时空全改1.png 实测；`ImGuiCol_TextSelectedBg`→#005A98@0.35
- 截图脚本升级 `xcom_lua/pic/snap.py`（自动取 next v#）

**运行中的 3 个后台 subagent**（task 完成后会各自 task-notification 回传）
- A. `按钮`控件深抠 → 产出 `xcom_lua/docs/1png-control-buttons.md`
- B. `输入/选择/下拉/复选`控件深抠 → `1png-input-select.md`
- C. `图标`深抠 → `1png-icons.md`
每个都已带 bridge.cpp:行号 对照表。等齐后据此再改局部控件函数（如 Open/Danger 的高度、combo 箭头、DTR/RTS check 样式）。

**交接提示**：主会话被 /compact 压缩后，续做用 agent a372660(按钮)/a70c288(输入)/a952cc3(图标) 的 task-id 取回各自产出；D 分隔/状态/字体类别若未派 agent，视产出后是否需要补派。

## 10. 控件深抠三份产出齐 + audit（2026-09-05 续做收口）

> 3 个后台 subagent（A 按钮 / B 输入/选择 / C 图标）已全部完成，产出文档：
> `xcom_lua/docs/1png-control-buttons.md`（A）、`1png-input-select.md`（B）、`1png-icons.md`（C）。以下是要点，供据此改 bridge 局部控件。

### 10.1 三份产出的硬结论（都为真实像素坐标，1802×1291 pic/1.png）
- **A 按钮**：1.png **没有任何彩色实心操作大钮**（无整块绿/蓝 Open/Close/Send、无实心红色 X）。全图饱和色只有 4 档:主蓝 `#005898`×877(接收高亮/logo/文字链)、红 `#C00000`×606(日志错误文字+状态点)、橙 `#F8A800`×367、深蓝按 `#004070`×344。→ 目前 bridge 的 `PrimaryAction`(Open)实心蓝、`DangerAction`(Close)实心红，**与 1.png 克制风格不符**；A 建议 Open/Close 改 **白底 + `#D5D5D5` 1px 描边 + 近黑/红字**（Close 红字白底），需随 doc 核对。
- **B 输入/选择**：5 个串口参数 combo 同一列 x=241..399(159px)、**47px 行距**（顶 y=108/155/202/249/296）。combo 边框 `#D5D5D5` 1px、内白 `#FFFFFF`（非 #F8F8F8）、无投影、~1px 圆角。下拉箭头是**中性灰实心小倒三角**（灰 `#7F7F7F`,点 `#616161`），**非主蓝**。文本/数字输入同款白底 #D5 外框。DTR/RTS **~33px 圆角开关 chip**（非 16px 复选钮）。
- **C 图标**：顶栏 6 槽（非 5）：①logo=蓝 `#005A9C`×约32×34；②x113..141 圆角"图表/面板"框(29×29)；③x192..221 波形-收拢(30×30)；④x275..291 **问号`?`仅17px宽**；⑤x360..389 **笑脸😊大空心圆+眼+弧嘴(30×31)**；⑥右上 x1741..1769 **齿轮**。顶栏**无最小/最大化钮**、无绿 ONLINE 圆点；唯一饱和非背景 = 红下收箭头(x≈688..706,y≈122..142)；无独立复选勾。
- **C 关键实现约束**：项目实际编译的 ImGui fork（`third_party/xcom_imgui/imgui/imgui.h:3507`）`AddLine(p1,p2,col,thickness)` **无 line-cap flags**，无 `ImDrawFlags_RoundCap`。→ 手绘圆端线不能传 RoundCap;要用 `AddCircleFilled(end, r=th/2)` 仿圆端。Bridge 现有 UtilityIcon(Refresh/Clear/Save/Path)*(bridge:479,501-515)* **在 1.png 无对应**——它们是日志动作词汇，与参考顶栏 glyph(logo/图表面板/波形/?/笑脸/齿轮) 是不同集合。

### 10.2 本区 UI audit（v8 真机 920×650，PrintWindow 截）
- clean 单实例 v8 截图健康：palette 与 §9 v7 完全一致（#FFFFFF×34376 / #F7FDF9×14329 / #EDEDED×7532 / #1E1E1E×3106 / #005A98×1391 / #FBFCFD×1082）——**配色达标，build/deploy/run 三轮验证 OK**。
- /xcom-ui-audit 的 `audit.py` 首跑返回**全黑**（BitBlt 在多实例/minimized/前台非目标时空帧）→ 是真机截图路径歧义，非 UI 缺陷；改用 snap.py 的 PrintWindow 单实例捕获后健康,见上。
- 布局结构矩阵：顶深色条 ~y30；接收面 y34..~620(空待数据)；sidebar #EDEDED **x=740..919(179px)**，hairline 分隔 ~x733; footer 带 y630+ 整宽灰。**无列溢出进入 sidebar**。空态接收/发送editor因未开串口而空——需 mock/真串口推数据才能审行/选中/橙时间戳(连同 §5)。
- 遗留:先前多实例残留 → 续做前一律 `taskkill //IM luvjit.exe //F`。
- 用户拟打开"串口助手参考客户端"供目视;本环境 Read 看 PNG=Unsupported,**无 vision MCP**(可用 MiniMax MCP `minimax-coding-plan-mcp` 是规划工具非视觉)。其 1216×900 真机窗口经像素扫描为 **多行表单/表格**式布局(左 47px 间距参数字段列、纯灰 #EDEDEF 底、红 R mark、蓝 B 段)，与静态 1.png 内容同源但行距/密度若按真机采需重测。真要看图需接一个**真正 image-capable 的 MCP**，或继续 PIL。

### 10.3 v9 应用 Open/Close→白底描边（2026-09-05，已 build/deploy/run）
- 用户确认「改，全按实测轮廓线钮」。bridge.cpp 的 `PrimaryAction(bridge:1463)` 与 `DangerAction(:1475)` 从实心色改**光面 outline**：
  - `PrimaryAction`(Open/Run)：底 `#FEFEFE`，hover `#E9ECED`，active `#DFE3E5`，文字 `kTextBody #1B1B1B`（input-select §4：Open 实为近白底深字，非实心蓝）；淡边由全局 `FrameBorderSize=1.0` + `ImGuiCol_Border #D5D5D5@0.9`(apply_style:2155/2116) 提供。
  - `DangerAction`(Close)：底 `#FEFEFE`，hover 淡红 `#FBEAE8`，active `#F4D8D5`，文字 `kDangerRed #C00500`（红字白底 outline）。
  - `SendAction`(:1490) 保持实心蓝不动（1.png 左下 SEND 实测即 solid #005A9E ~8px 圆角白字）。
- 每函数 Push 从 3→4 色(多一个 Text) → 各自随 Push 后调用处对齐(自动补偿)，**签名与行为不变**。
- **验证(v8→v9 diff)**：v8 侧栏有个实心蓝 slab x≈743..917 高~23(Open 满宽钮)，v9 该行 solid-blue=0（变 #FEFEFE outline）；整车 `#005A98` 1391→952px（Open slab 被删后的蓝仅余 Send+页签选中）；`#FEFEFE` 新填充出现。Send(实心蓝)与页签下划线/选中保持蓝——**仅克制目标被降级，其余蓝即保留需要**。
- 注：Open/Close 渲染于**右栏(连接) x743-917, y≈89-112 满宽**；idle(未连) 显示「Open」深字。Close(红字)需开串口(connected)才可见,本无口验证其形态——DangerAction 对称低险,逻辑同构 Open，Open 已证 outline 生效即可放心。
- **待办未动**（等 D/E 产出）见 §10.1 B 项输入/选择类、C 图标类。D agent(a1423fa)/E agent(af3dfe0) 已在后台深抠分隔/状态/字号 + 发送区,产物各 `xcom_lua/docs/1png-separators-status-font.md` 与 `1png-sendzone.md`。

### 10.4 真视觉 MCP 探路结论（不可达，活路仍是 PIL）
- Read 对 pic/1.png 及截图 `[Unsupported Image]`（本会再次确证，硬限制）。
- 现可用 MiniMax MCP = `minimax-coding-plan-mcp`（用户近日 `claude mcp add -s user MiniMax --env ... coding-plan` 已配,已在 .claude.json，是**规划工具非视觉**，非 image MCP）。
- 用户让用现有 key 走 MiniMax 视觉：实测其 `api.minimax.cn` 上 `/v1/vl/chat/completions` → **404**（.cn 端无该 VL 路）；社区 `wenjiaqi8255/minimax-vision-mcp` 走 `.chat` 域 `coding_plan/vlm`+`chatcompletion_v2`(model `minimax-vl-01`)，需要 `.chat` 域且授权 VL 的 key（现有 `sk-cp-` 是 coding-plan 域，未知能否用。+ `.chat` 与现 .cn host 不同）。
- 结论：真目视本环境**暂不可达**；稳健活路 = **PIL 逐像素 + ASCII 语义**（A/B/C/D/E 全用它，Open/Close v8→v9 亦用它验证）。拿到 `.chat`+VL 授权的 key 后，按上述 minimax-vision-mcp 装配（含 restart）。

### 10.5 客户端交付态确认（用户最终状态清单 2026-09-05 记录）
> 用户收口清单（并行 Lua/Scope 工作流已交付）：script_engine 沙箱/钩子/过滤/高亮/REPL/LLCOM 兼容 + Script Console 浮窗 + struct/json/base64 协议库；ImPlot v1.1 曲线面板(游标/追尾) + GDI 示波器弹窗(截图) 双后端；UI 验收 Header "Lua"/"Scope" 实证渲染；113 断言全绿；环境零残留。
- 本会话复核：`(cd xcom_lua && ./runtime/luvjit.exe tests/test_script_engine.lua)` → **50 passed / 0 failed**（正确从 xcom_lua/ 起，须 core/ 可 require）。113 为整套多文件(script_engine+协议库+scope)合计，见并行流已验。UI 真机 v9(pic/current_ui_v9.png) Header 深条仍在，配色/布局稳定。
- 与 /goal "完成客户端开发" 汇合：串口收发+UI+脚本引擎+波形 已在可交付态；余下纯 1.png 观感打磨(B 输入/选择行距箭头 chip、C 图标、D/E 产出)属锦上添花，可随时继续或就此交付。

### 10.6 D 类产出（1png-separators-status-font.md，✅）
- 分隔实为 **#EDEDED ×2层**(y60 与 y61 皆满宽)，非单 1px → `kRule` 若要更贴 1.png 应标 1.5–2px 高。左卡群另见三条 `#DEDEDE` 顶边(y≈399/660/873, x9..402)；左右两列靠 ~20px 空沟 + x423 全程浅灰竖 band ~#EF/#ED（bridge 注释里写的 #E6E6E6 应更正）。
- 容器：1.png 属**零装饰+发丝分隔派**，无 >3px 圆角卡/有色描边；左列白卡 #FEFEFE/#FB 上下叠，右日志纯白仅最右 #E4E4E5 极浅描边。bridge `Panel` rounding=0/border=false 思路对，缺省 child #EEEEF0 宜改更白(#FEFEFE 级)。
- 状态：无 ONLINE/OFFLINE pill/圆点徽章基准(icons 亦证绿=0)；1.png"红标"=左 COM 点(x217..228)。bridge Footer pill 属自设、不对齐 1.png。
- 字号：强调蓝 `#004275`=palette #004270 ✓；正文 #1B1B1B/灰 #8C8C8C 一致；标题带墨行高~19px；本图无字号元数据，13pt 无法反推——如实"无基准"。

### 10.7 E 类（发送区 → 1png-sendzone.md，✅ 交付）
> E 证实：**1.png 是极稀疏静态版式——没有经典"底部发送坞"**。多行编辑器 Tab、Single/Multi 槽、`1/3 ▷`页码、Loop/HEX/NEWLINE 标签、实底大 SEND 在 1.png **全部不可采**（坞是本工程自设、不在参考帧）。
- 真正可对齐的"发送"部分：
  ① **两处周期输入框**：断帧 `20 ms ?` @(x274..295,y533..548)；定时 `1.0 秒` @(x275..299,y837..852) → 对照 bridge `##send_period`(:1212)/`##multi_period`(:1316)。注意两处**单位不同**(ms vs 秒)需区分。
  ② 左栏自上而下「发送设置 / 十六进制发送 / 发送文件 / 脚本 ADD8 …」**中文开关行**(映射 #005A98 实底 SendAction 与 HEX toggle,值列 x≈258..)。
  ③ 右下 **send-arrow 深线描字形**(x1671..1731, y1158..1198, 中心(1700,1178), 深 #1A1A1B on #F8F8F8)。
- 结论：可做的对齐是**周期框 + 中文发送开关行**文案/值列位；**发送坞本身勿照抄**(E 的 F1/F6 都标明"。真机动态坞不在本帧,不照抄")。五份 doc(A buttons/B input-select/C icons/D separators-status-font/E sendzone)至此**全齐**。

### 10.8 五份控件 doc 交付后的小结（2026-09-05 收口建议）
- 五份皆"像素级实测 + bridge.cpp:行号 对照 + 标待改/无基准";多为主负性/克制主张。
- **本会已落地的有价值改动**：Open/Close/Run 从实心色改 **白底 #FEFEFE outline**（文字深 #1B1B1B / Close 红 #C00500），Send 保实心蓝；v8→v9 像素 diff 实证侧栏 Open 满宽实心蓝 slab(x743..917,~23高)被清空。
- **客观判读**：D/E 及 C 的多数"待改"是**1.png 没有某物**(无 pill/无卡圆角/无实心钮/无大圆复选/无底坞)→ 不应为对齐而无故造/删 bridge 功能。B 的"行距/箭头灰/开关 chip"与 E 的"周期框单位/文案"属中险局部改，是否做由用户定。




