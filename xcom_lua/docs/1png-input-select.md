# pic/1.png 输入与选择控件 像素级规格（深度抠）

> 研究只读文档，不改任何文件。所有数值均由 PIL 对 `pic/1.png`（1802×1291 RGB）逐像素实测，
> 非估算。目的：给 `xcom_imgui_bridge.cpp` 的 ImGui 控件重绘作像素基准。
> 日期 2026-09-05。本图是中文版「串口终端」UI（SSCOM 风格），非标准 Windows 控件主题，
> 而是一套 custom 绘制（灰底 `#F8F8F8` / 卡片 `#FBFCFD`）。

---

## 0. 总览：本图用到的"输入/选择"控件家族

按横向结构分层（左参数列）：

| 控件家族 | 定位（x 范围） | 对应 bridge 实现 |
|---|---|---|
| 参数下拉 Combo（端口/波特率/数据/校验/停止/流控） | x=241–399 | `ComboField` / `GridComboField`（bridge.cpp:450/456）→ `ImGui::Combo` |
| 字符集下拉 CS | x 值列宽内 | bridge.cpp:768 `ImGui::Combo("##charset",…)` |
| 数字输入（帧间隔 ms） | 值列，Toggle 右侧 | bridge.cpp:780 `ImGui::InputInt("##frame_gap_ms",…)` |
| 端口下拉（可编辑） | sidebar 上 | bridge.cpp:1376 `ImGui::BeginCombo` + `Selectable`（:1381） |
| Custom'停止位'式"值+▼"复合框 | x=241–399 单行，**无内竖分隔** | —— |
| 大「打开/Open」按钮 | x≈8–425（宽 417） | bridge.cpp:1394/1397 `PrimaryAction/DangerAction`（:1463/1475）→ `ImGui::Button` |
| "线状态"大圆角切换墩（DTR/RTS 等） | 每个约 33×33px | 本图实为按钮/开关，见 §5 |
| Hex/Time/Hold/Clear/Save…开关 | sidebar | bridge.cpp:726–746 `Toggle()`（:1441 `InvisibleButton` 自绘） |
| 发送键 / Run / paging 按钮 | —— | bridge.cpp:1339–1344 PrimaryAction/SendAction |
| 滚动条 | （1.png 为文档图，主区无可见滚动条 UI） | bridge.cpp:2137–2140 + 2161 （仅样式） |

> 注意：1.png **没有** 13–16px 的 ImGui `Checkbox` 小方框网格（早期文档误判的"C3C2C7 方块"实为
> 左侧行分组竖轨 + 每行 18px 的"值列"底 ~#C0 灰，见 §6 修正）。真正接近复选框语义的是 Send 区
> 的每栏行内勾选（本图最宽幅区域），以及右侧 **大圆角切换墩**（§5）。

---

## 1. Combo 下拉（参数 5 + 复合框）—— 边框与几何

### 1.1 5 个串口参数下拉 bbox（x 完全一致）

全部 5 个参数下拉共享**同一 x 列**（右对齐同一值列），左 x=241，右 x=399，宽 **159 px**。
顶行 y=108，行距（上边框间距）**47 px**，故各框顶/内容：

| 名称 | 顶边框 y | 底(下一框) 顶 | 高(含边) | 注释 |
|---|---|---|---|---|
| 端口(COM3) | 108 | 155 | 47 | COM3 选中 |
| 波特率 | 155 | 202 | 47 | （图上文本"8"→115200 值一带） |
| 数据位 | 202 | 249 | 47 | 值"8"+HEX 后缀 |
| 校验位 | 249 | 296 | 47 | None |
| 停止位 | 296 | 337 | 47 | **带 ▼ 复合值，"1"** |

（另两个非参数 Combo 见 §1.4，坐标不同但边框风格一致。）

### 1.2 边框颜色（5–10 点采样，全部 #D5D5D5 系）

实测参考 `（以端口框 y108–156 x241–399 为例，5 框相同）`：

- 顶边、底边、左边绝大部分：**`#D5D5D5`**（顶 5 点 246/251/320/394 全 #D5D5D5 已证实）。
- 右边最外 1px（x=399）处：**`#D8D8D8`** 渐变抗锯齿（y108 →采样 216,216,216）。
- 左右垂直中段内缩 1px（x241,y113/118）实测 **#FEFEFE→#F6F6F6** = 圆角内收，非纯白。
- 顶边框外面 1px（y=107，外上）实测 **#FFFFFF**，无额外 1px 投影 → **无投影阴影**。
- 顶边外面在 x=242 处 y108 上是 #EAEAEA、x398 #ECECEC —— 仅**圆角过渡淡晕**，非边框：
  4px 角内缩可见（TL: D5→F2/E0→FEFE）。BR 4px 逐层 E9/EC/DEDE/FCFC 是右+下双重圆角 AA。
- 圆角：可视一个极小的 ~2px AA 过渡（不是大 radius）。**≈7F 圆角即 0–1px**。

### 1.3 内部

- 填充：** `#FEFEFE`/`#FFFFFF`**（中心 320,179=#FFFFFF；内边 1px =#FEFEFE 至 #FFFFFF）。
  **不是纯 #F8F8F8**（按钮才是）。面板底色是浅蓝白 #FBFCFD 卡片（上边框外 y107 ~#FFFFFF/卡）。
- 内部下边 2px 采 #FFFFFF，顶内 2px #FEFEFE ——近乎无内阴影。
- 文本：选中的单色黑字 **`#1B1B1B`**，字形起始 x=261，字形高 **15px**（y129–143 for COM3），字号≈12–13px 系。
- 文本左内边：x=241 → 字形起始 x≈258-261，约 **17–20px** 内边距。

### 1.4 其余 Combo（非参数值列）

整图还发现 #D5D5D5 高密度横线行，逐对列成白框（规则一致）：

| 顶 y | 边框宽度/区间 | 推断 |
|---|---|---|
| 390 | 整 388px：(x≈12..399 x 全宽到按钮左侧)? 见 §4（大按钮标题/虚线边缘带） | 顶栏大按钮行（非纯 Combo） |
| 443/471…(对) | 18px 线段 x15..32 逐行 ✓ | 左侧"行值"灰底 ~#C0（§6 修正，非框） |
| 510 | (x324–399) 宽 76 | 值列内某状态量 |
| 558 | (x364–399) 宽 36 | 尾部小子控件 |
| 603 | 大 (x111–354, 宽 244) + 尾 (x364–399, 36) | 发送/帧长 文本+复合（"xx 字符/自动帧"） |
| 819 | 同上大 (111–354)+尾(364–399) | 同批参数（自定义文本/自动重发区间） |
| 925 | (x256–399) 宽 144 | 值列框 |

这些边框风格与 §1.2 一致（#D5D5D5 顶/左右、边角 #F9–#FC AA、外 #EF）。

---

## 2. 下拉箭头（combo 右侧 ▼）

5 个参数下拉同一位置、同型（COM3 实测最全）：

- 位置：相对右缘 x=241+159=399，箭头包围盒 **x≈367–378（宽 12），y≈132–138（高 7/dark 顶 132）**。
  距右边框 ~20px，距右缘 2px（箭头右到 x378）。
- 形状 = 小等边**向下三角形** ▼：
  ```
  y 132:              .
  y 133:            ## ##
  y 134:          .##   ##.
  y 135:          ##     ##
  y 136:        .##       ##.
  y 137:      .##  ###.##  ##.   (中心合拢)
  y 138:        .# #  #  ...
  ```
  ASCII（x367..378, 210 步进）中心 y列显示左右两道斜腿 —— **实为空心 V（两道 1px 线）** 非实心。
- 颜色为中间灰，非黑非蓝：实测像素 `#7F7F7F`/`#6B6B6B`，下尖 `#616161`。是 **~60–70% 中性灰**。
- 每行都拿一个测（115200/8/None 同 bbox x=370–378,高度 6（y180-185/227-232/274-279），相对其框内同样置中偏下）。

> 结论：combo 箭头不是主蓝，而是中性灰（近似 ImGui `ArrowButton` / `FrameBgActive` 灰色但这里用 ~#6B–#7F）。

**5 框中唯一例外**——停止位行（y296-337, x241-399）：其内部除了下拉箭头，主体文本占了几乎整宽
（文本到 x≈365 含"1"值）+ 无明显内竖分隔（早期疑似 x313 有内线，实为文字AA）。可视为"可下拉+带当前值的
复合框"在宽框右缘的 ▼（仍 x~370-378 → 检查其箭头呈现如常）。该框文本宽度大，第 316-329 行字高 14px。

---

## 3. 输入框 / 数字输入（InputInt / 文本）

本图"文本/数字输入框"与 Combo 视觉采用**同一白色 frame**（#FFFFFF 内 + #D5D5D5 1px 边框圆角极小），
即 ImGui `FrameBg/Border` 同源；差异只在：值可编辑、无右侧 ▼。

桥实现对应：
- `ImGui::InputInt("##frame_gap_ms",…,0,0)` 宽 52px（bridge.cpp:780）—— 帧间隔"20 ms"里 20。
- charset 行用 Combo（768）。
- Serial 值列仍有少数 Input（可查 < 值列中 > 子框）。
本图里这些输入框采样与 §1 frame 相同（底 #FFFFFF、边 #D5D5D5），例：行 y510 值 (x324..399) 内部
中心大量 #FFFFFF，无箭头 → 判定为可编辑数字（非下拉）。

---

## 4. 主按钮（Open / Send / Run）

实测 **「打开」大按钮**（Open 状态 → PrimaryAction，#F8F8F8 浅按钮）：

- 占用行 y≈390–435，x≈8–425 → 近乎总面板宽，中间 400px+ 高 46（其上边框竖排文字/点亮效果见 y398..430 两侧）。
- 底色：中心 px(210,410) 采样远处实际大多 #FEFEFE（见 410 历史多数），文字黑 #1B1B1B。
  早期误作 #F8F8F8：正确是**更白 #FEFEFE/白**，仅边条#EF。
- 无深色外框（仅极淡 AA #EF）。文字中央（打开）黑字 1 行。
- 对应 PrimaryAction bbox=(-1,0)（bridge.cpp:1394），DangerAction（Close）红（1397）不在本图空闲态。

主蓝 SEND / 绿不可见：左下发送键在本图为**主流蓝色(#005A9E 主导、约 8px 圆角、白字)primary**（SendAction，bridge.cpp:1344/1490），
本像素集里蓝 `#005A9E` 分布 781px（在左侧+底部）。

**几何高宽经验**：桥 `kControlHeight=26`（bridge.cpp:55），但 1.png 的成行按钮/下拉实际高(含 AA)≈47px
（行距 47）。即本图按钮比 ImGui 帧更高更矮胖 —— 是串口终端用 46px 行模式，行内控件 ≈ 41px 内容高。

---

## 5. "线状态"DTR/RTS 圆角切换墩（2 大圆钮样）

y≈306–336，两枚相邻约 33×33px（x≈5–40 与右侧第 2 枚 x≈60 后）圆角近似圆角大方钮：
- 灰描边（#C0C0C0 / 中间 ~#8B8B8B），内粉底（#F8F8F8），右上高光+圆角阴影（#FEFEFE→#8B）。
- 语义是串口线 DTR/RTS 状态 readout（y315–329 处框内部有一块 - - - 高亮方 = 触点）。
- 非 ImGui checkbox；对应桥无此类，但可 → 参考全局手绘。本像素仅记录"若重绘 DTR/RTS 指示，用 33px 圆角晶".

---

## 6. 修正早期误读（对比 ui-redesign-round2-progress.md §1.2.1）

早期表引 "CheckBox 方块 边框 #C3C2C7、选中灰 #A0A0A0、未选空"（§1.2.1 第57行) **在本 1.png 中未见**：
在 x≈15..32 的"18px C3 行"经放大其实是**行左侧引导一条竖直 #C0–#8B 描边 + 相邻行的 ~#F8 fill 值单元格**，
而非可选复选框。真实左右可选切换是 33px 墩(§5)+右侧 large toggle chips。色 #C3C2C7/#A0A0A0 在图上像素统计
中几乎缺失（top colors 无），需复核真实用哪个版本。

---

## 7. 对照 bridge.cpp：用哪些 ImGui 项 + 实装行号

| 1.png 控件 | ImGui 原语 / 内部 | 桥架实现 | 行号（相对 bridge.cpp） |
|---|---|---|---|
| 参数下拉（5 串口） | `ImGui::Combo`（自带 frame▼） | `SerialFields` ComboField → `GridComboField`（value column 右缘） | 450 定义 / 456 值列 → 环迭代 1409–1411；specs 2350–2356 |
| 行内 label 布局 | `ImGui::Text` + 表位 | GridComboField 里 table 列计算 / `ImGui` Table(2,col) | 461–464 |
| 字符集下拉 | `ImGui::Combo` | `##charset` | 768 |
| 值帧样式 | FrameBg #FFFFFF / Border #D5 | kStyleColors FrameBg=0xFFFFFF,Border=0xD5D5D5 | 2120, 2116 |
| 帧圆角 AA ~2 | FrameRounding | style.FrameRounding=5(但 1.png 需 ~0–1) | 2150 |
| 文本色 | #1B1B1B | ImGuiCol_Text 0x1B1B1B | 2111 |
| 下拉箭头灰 | （combo 内部 ImGui 绘 Arrow） | 受 FrameBgActive / SliderGrab? 主灰 ~#6B–7F 需改 | （无显式箭头样式 → 建议用 Border (#D5)较暗 ~ 覆写） |
| 端口下拉(popup) | `BeginCombo`+`Selectable` | `##port_combo`：选中默认焦点(int) | 1376–1387 |
| Open 蓝/浅大钮 | `ImGui::Button`(+ rounding) | PrimaryAction(-1,0) / DangerAction(Close) | 1394/1397 ; util 1463/1475 ; WithRounding |
| SEND 蓝钮 | Button(8px) | SendAction → #005A9E系 | 1344,1490–… |
| 数字输入 ms | `ImGui::InputInt` | `##frame_gap_ms` 宽52 | 780–782 |
| 帧间隔单位 ms | TextDisabled | "ms" | 784 |
| toggle(开关芯) | `InvisibleButton`+自绘圆 | Toggle() 28×20 | 1441–1460 |
| HEX/Time/Hold/Clear/Save… | (Toggle) | 726‑746 |
| Scrollbar | 根：NoScroll + 主 monitor NoScroll | Scrollbar styling（配色/12px） | 2339 etc + styles 2137–
| child 卡片 | `BeginChild`(border) | Panel helper | 341 |

上面右键 → 灰色 info：头/卡片底 #FBFCFD(WinBg) 、内卡片底 #EEEEF0(ChildBg)（2133-2155）。

---

## 附：再测关键像素锚（给复核）

```
param combo:  (241,108)-(399,155) 外; (241,108)-(399,156)帧，内 241+1..398, 高41 白
箭头顶:  x367..378, y~132..138 (V形两道，col ~#7F/#6B 下尖 #6161)
文字bbox(COM3): x258..322 y129..143 (h15,#1B1B)
行距:     47px (y 108→155→202→…)
边框:     #D5D5D5(1)外再沿 #EF/#EA 过渡 2px; 右缘x399 #D8
fill:     #FFFFFF (中心), FrameBg #FFFFFF
```
