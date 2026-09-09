# LLCOM UI 布局借鉴笔记（llcom-ui-layout.md）

> 注意：LLCOM 用 **WPF** 不是 ImGui，不能照搬 XAML，但**视觉分区/控件栅格/信息密度**值得对照。
> 涉及文件：
> - `D:\workspace\SSCOM_lua\ref\llcom\llcom\View\MainWindow.xaml`（主窗口 843 行）
> - `D:\workspace\SSCOM_lua\ref\llcom\llcom\Pages\DataShowPage.xaml`（接收 log 模板）
> - `D:\workspace\SSCOM_lua\ref\llcom\llcom\Pages\OnlineScriptsPage.xaml`（在线脚本市场）
> - `D:\workspace\SSCOM_lua\xcom_lua\native\xcom_imgui\xcom_imgui_bridge.cpp`（xcom_lua ImGui 仪表盘）

## 1. LLCOM 主窗口总览（MainWindow.xaml）

```
┌─ Window 900×500（最小尺寸由控件决定）─────────────────────────────┐
│ Row 0: *  Grid.Row=0 │ Row 1: Auto (工具+发送) │ Row 2: Auto (状态) │
├──────────────────────────┬───┬──────────────────────────────────────┤
│  Col 0: 11* 数据收发显示 │ ⎮ │ Col 2: 7* TabControl                  │
│  (dataShowFrame)         │ ⎮ │ ├─ Tab 0: 快捷发送（10 页可切）       │
│  DataShowPage            │ ⎮ │ ├─ Tab 1: Lua 编辑器 + 日志 + REPL    │
│  (RichTextBox per item)  │ ⎮ │ ├─ Tab 2: 在线脚本（GitHub Discussions│
│                          │ ⎮ │ ├─ Tab 3: 工具集（TCP/UDP/MQTT/...）  │
│                          │ ⎮ │ └─ Tab 4: 关于                       │
│                          │ ⎮ │                                     │
│  Row 1: Auto（按钮+输入）│ ⎮ │                                     │
│  [开/关串口] [清log] [更多]│ ⎮ │                                     │
│  [多行输入 toSendData ]   │ ⎮ │                                     │
│  [发送]                   │ ⎮ │                                     │
├──────────────────────────┴───┴──────────────────────────────────────┤
│ Row 2: 状态栏（21 列）：refresh │ COM │ ─ │ 端口 │ ─ │ 波特率 │ ─ │ │
│ 状态 │ ─ │ 已发送计数 │ ─ │ 已接收计数                              │
└────────────────────────────────────────────────────────────────────┘
```

**关键代码定位**：

```xaml
<!-- MainWindow.xaml:41-51 — 主网格 -->
<Grid Name="MainGrid" IsEnabled="False">
    <Grid.RowDefinitions>
        <RowDefinition Height="*" />
        <RowDefinition Height="Auto" />
        <RowDefinition Height="Auto" />
    </Grid.RowDefinitions>
    <Grid.ColumnDefinitions>
        <ColumnDefinition Width="11*" />     <!-- 左主区 = 数据收发 -->
        <ColumnDefinition Width="auto" />   <!-- GridSplitter -->
        <ColumnDefinition Width="7*" />      <!-- 右栏 = 控件 -->
    </Grid.ColumnDefinitions>
```

```xaml
<!-- MainWindow.xaml:262-266 — 中间分栏条 -->
<GridSplitter Grid.RowSpan="2" Grid.Column="1" Width="5" HorizontalAlignment="Stretch" />
```

```xaml
<!-- MainWindow.xaml:269 — 右侧 TabControl -->
<TabControl Grid.RowSpan="2" Grid.Column="3">
    <TabItem>...快捷发送（10 页）...</TabItem>
    <TabItem>...Lua 编辑器...</TabItem>
    <TabItem><fa:FontAwesome Icon="cubes" /></TabItem>  <!-- 在线脚本 -->
    <TabItem>...工具集...</TabItem>
    <TabItem>...关于...</TabItem>
</TabControl>
```

```xaml
<!-- MainWindow.xaml:128-259 — 底部状态栏 21 列网格 -->
<StatusBar Grid.Row="2" Grid.ColumnSpan="3">
    <StatusBar.ItemsPanel>
        <ItemsPanelTemplate>
            <Grid> <!-- 21 个 ColumnDefinition --> </Grid>
        </ItemsPanelTemplate>
    </StatusBar.ItemsPanel>
```

## 2. LLCOM 接收区布局（DataShowPage.xaml）

```xaml
<!-- DataShowPage.xaml:21-63 — 每行一个 RichTextBox，自带 FlowDocument -->
<Style x:Key="DataShowStyle" TargetType="{x:Type ListBoxItem}">
    <Setter Property="Template">
        <Setter.Value>
            <ControlTemplate TargetType="{x:Type ListBoxItem}">
                <RichTextBox IsReadOnly="True" FontFamily="Consolas,Microsoft YaHei,微软雅黑" FontSize="12">
                    <FlowDocument>
                        <Paragraph Margin="0">
                            <Run Foreground="DarkSlateGray" Text="{Binding TimeText}" />
                            <Run Foreground="DarkSlateGray" Text="{Binding ArrowText}" />
                            <Run FontSize="15" Foreground="{Binding DataTextColor}" Text="{Binding DataText}" />
                            <Run FontWeight="Bold" Foreground="Black" Text="{Binding RawTitle}" />
                            <Run FontSize="15" Foreground="{Binding RawTextColor}" Text="{Binding RawText}" />
                            <Run Foreground="{Binding HexTextColor}" Text="{Binding HexText}" />
                        </Paragraph>
                    </FlowDocument>
                </RichTextBox>
            </ControlTemplate>
        </Setter.Value>
    </Setter>
</Style>
```

**关键设计**：
- **每条 log 一行**（`Paragraph Margin="0"`）
- **6 段颜色 Run**：时间戳(灰) + 箭头(灰) + 字符串数据(主色) + RAW 标题(黑粗体) + RAW 字节(主色) + HEX(灰)
- **虚拟化**：`VirtualizingStackPanel.CacheLength="2,2"` + `IsVirtualizing="True"` + `VirtualizationMode="Recycling"`

```xaml
<!-- DataShowPage.xaml:133-172 — 底部选项条（8 个 CheckBox 横排）-->
<StackPanel Grid.Row="1" Orientation="Horizontal">
    <CheckBox Content="RTS" />
    <CheckBox Content="DTR" />
    <CheckBox Content="HEX显示" IsThreeState="True" />  <!-- 三态 -->
    <CheckBox Content="HEX发送" />
    <CheckBox Content="附加\r\n" />
    <CheckBox Content="显示控制字符符号" />
    <CheckBox Content="禁用日志" />
</StackPanel>
```

注意 **`HEX显示` 是三态 CheckBox（IsThreeState="True"）**，对应 `Settings.cs:21` `_showHexFormat` 的 0=混合 / 1=只字符串 / 2=只 Hex。xcom_lua 当前只有 2 态 `receive_hex`（bool），缺这个 3 态。

## 3. LLCOM 快捷发送区（MainWindow.xaml 行内）

```xaml
<!-- MainWindow.xaml:343-453 — toSendListStyle：每条目 5 列 -->
<Grid Name="ItemGrid" Margin="0,3,0,0">
    <Grid.ColumnDefinitions>
        <ColumnDefinition Width="Auto" />     <!-- 序号 -->
        <ColumnDefinition Width="4*" />       <!-- 文本 -->
        <ColumnDefinition Width="auto" />     <!-- 发送按钮 -->
        <ColumnDefinition Width="20" />       <!-- hex 复选框 -->
        <ColumnDefinition Width="25" />       <!-- 脚本图标 -->
    </Grid.ColumnDefinitions>
```

**复用模式**：
- 序号 → 文本（绑定 `text, UpdateSourceTrigger=PropertyChanged`）→ 按钮（绑定 `commit`）→ hex → 关联脚本图标
- **图标悬停放大**（`FontSize 16 → 20`）
- `VirtualizingPanel.CacheLength="1,2"` + `CacheLengthUnit="Page"` + `Recycling`

## 4. LLCOM 在线脚本市场（OnlineScriptsPage.xaml）

```xaml
<!-- OnlineScriptsPage.xaml:22-128 — 列表态 -->
<ScrollViewer Grid.Row="1" VerticalAlignment="Top" VerticalScrollBarVisibility="Auto">
    <ItemsControl x:Name="ScriptListItemsControl">
        <ItemsControl.ItemTemplate>
            <DataTemplate>
                <Button Height="75" Margin="0,2" HorizontalContentAlignment="Stretch">
                    <Grid VerticalAlignment="Center">
                        <Grid.RowDefinitions>
                            <RowDefinition Height="*" />     <!-- Author + Name -->
                            <RowDefinition Height="auto" /> <!-- 1px 横线 -->
                            <RowDefinition Height="*" />    <!-- Version + Description -->
                        </Grid.RowDefinitions>
                        <Grid Margin="10,0,0,0">
                            <Grid.ColumnDefinitions>
                                <ColumnDefinition Width="*" />   <!-- Author 左 -->
                                <ColumnDefinition Width="4*" />  <!-- Name 居中粗体 -->
                            </Grid.ColumnDefinitions>
                            <TextBlock FontSize="18" Text="{Binding Author}" />
                            <TextBlock FontSize="18" FontWeight="Bold" Text="{Binding Name}" />
                        </Grid>
                        <Canvas Grid.Row="1" Height="1" Background="Black" />
                        <Grid Grid.Row="2">
                            <Grid.ColumnDefinitions>
                                <ColumnDefinition Width="*" />    <!-- Version -->
                                <ColumnDefinition Width="4*" />   <!-- Description -->
                            </Grid.ColumnDefinitions>
                            <TextBlock FontSize="18" Text="{Binding Version}" />
                            <TextBlock FontSize="18" Foreground="#FF8C8C8C" Text="{Binding Description}" />
                        </Grid>
                    </Grid>
                </Button>
            </DataTemplate>
        </ItemsControl.ItemTemplate>
    </ItemsControl>
</ScrollViewer>
```

**卡片视觉**：75px 高，左 Author + 居中粗体 Name，黑色横线分隔，Version + Description（灰）。**这个卡片模式很适合做 xcom_lua 的「脚本启用列表」UI**——目前 xcom_lua 的脚本启用是裸 `Checkbox + 文件名` 列表。

## 5. xcom_lua 当前布局（xcom_imgui_bridge.cpp）

```cpp
// xcom_imgui_bridge.cpp:2149-2223 — Dashboard() 主函数
if (ImGui::Begin("##xcom_dashboard", nullptr, flags)) {
    ui::Header(actions, connected != 0);   // 行 2151
    ImGui::SetCursorPosY(layout.header_height);
    // 5 个串口参数组合框（CompactSpec 数组）
    const std::array<ui::ComboSpec, 5> serial_fields{{...}};
    // monitor_column = 左主区
    if (const auto monitor = ui::Panel(
            "##monitor_column", ImVec2(-sidebar_width + 1.0f, -kFooterHeight), false,
            ImGuiWindowFlags_NoScrollbar | ImGuiWindowFlags_NoScrollWithMouse); monitor) {
        actions |= ui::ReceiveContent(...);   // 接收 log + 选项
        const auto send_workspace = ui::Panel("##send_workspace", ...);  // 发送区
        actions |= ui::TransmitContent(...);
    }
    // 双线分隔（20px gap + 1px 深灰 + 1px 浅灰）
    ImDrawList* const bg_draw = ImGui::GetWindowDrawList();
    bg_draw->AddLine(..., palette::kRule, 1.0f);
    bg_draw->AddLine(..., rgb(0xEBE9EA), 1.0f);
    ImGui::SameLine(0.0f, gap);
    {
        // serial_column = 右栏
        const auto serial_column = ui::Panel("##serial_column", ImVec2(0, -kFooterHeight),
                                             false, 0, rgb(palette::kSurfaceSidebar));
        actions |= ui::ConnectionContent(...);  // 端口+5个参数+DTR/RTS+Rx/Tx
    }
    // 底部 footer
    ImGui::SetCursorPosY(ImGui::GetIO().DisplaySize.y - kFooterHeight);
    ui::Footer(connected != 0, rx_bytes, tx_bytes);
}
```

## 6. LLCOM ↔ xcom_lua 布局对照

| 维度 | LLCOM (WPF) | xcom_lua (ImGui) |
|---|---|---|
| **分区方向** | 左主区 + 右 TabControl | 左 monitor_column + 右 serial_column |
| **主区 / 侧栏比** | `11* / 7*` ≈ 1.57:1 | `monitor_column / sidebar_width` 估算约 1.6:1 |
| **可拖拽分栏** | `GridSplitter Width=5` | **无**（固定 sidebar_width）—— 改进点 |
| **底栏** | `StatusBar` 21 列，含端口/波特率/状态/Sent/Recv | `ui::Footer()` 含连接状态 + Rx/Tx —— **缺端口列表 / 波特率显示** |
| **顶栏** | **无独立顶栏**（与状态栏混合） | `ui::Header()` 含 Logo + 端口列表 + 打开按钮 + Lua 按钮 |
| **接收 log 字体** | `Consolas, Microsoft YaHei, 微软雅黑` 12pt | `Consolas` 15px（详见 `kReceiveFontSize`） |
| **每行 log 结构** | 6 个 `Run`（时间戳/箭头/数据/RAW标题/RAW/HEX） | xcom_lua 拆成更细（详见 `core/charset.lua`） |
| **log 虚拟化** | `VirtualizingStackPanel` + `CacheLength=2,2` + `Recycling` | `ImGuiListClipper`（cpp:869, 1666）—— 等价方案 |
| **快捷发送栅格** | 5 列（序号/文本/按钮/hex/脚本） | xcom_lua `TransmitContent` 多页支持（`multi_page`/`multi_page_count`），栅格未拆分 |
| **底部选项条** | 8 CheckBox 横排（RTS/DTR/HEX3态/HEX发送/附加\r\n/符号/禁用） | xcom_lua `ReceiveContent` 有 5 个左右（hex/timestamp/pause/auto_clear/auto_save）—— 缺 DTR/RTS/附加\r\n |
| **HEX 模式** | **3 态**（混合/只字符串/只 HEX）—— `IsThreeState="True"` | **2 态** bool —— 改进点 |
| **多通道 Tab** | TabControl 5 个 Tab | **无**（只有 1 个串口通道） |
| **在线脚本市场** | GitHub Discussions 拉取 + 卡片列表 | **无** |
| **配色** | 浅色白底 + AdonisUI 主题；强调色橙红蓝绿 | `palette::kSurfaceData` `#F8F8F0` 发送区、`kSurfaceSidebar` 侧栏、`kRule` `#8A8889` 分隔线 |
| **图标** | FontAwesome（fa:FontAwesome） | 自绘矢量 `ui::IconButton` |

## 7. 关键借鉴点（直接可落地的）

1. **3 态 HEX 模式** —— `DataShowPage.xaml:144-149` `IsThreeState="True"`。xcom_lua 当前 `receive_hex` 是 0/1 bool，可扩为 0=混合 / 1=只字符串 / 2=只 HEX。
2. **底部选项条横排** —— `DataShowPage.xaml:133-172` 把所有 show/format 开关做成一行 `CheckBox`。xcom_lua 的 `ReceiveContent` 选项可以参考这个密度（目前散在多处）。
3. **底栏补端口信息** —— LLCOM `MainWindow.xaml:159-258` 状态栏同时含端口列表（`ComboBox Name="serialPortsListComboBox"`）、波特率、状态、Sent、Recv。xcom_lua `ui::Footer()` 只显连接状态 + Rx/Tx 计数。
4. **可拖拽分栏** —— 加 `GridSplitter` 等价物（ImGui 没有原生 splitter，需要 `ImGui::Button("‖")` 拖拽手柄 + 计算鼠标位置改变 `sidebar_width`）。
5. **虚化 log** —— `VirtualizingStackPanel.CacheLength="2,2"` 对应 ImGui `ImGuiListClipper` 的步长参数（xcom_lua 已在用）。
6. **快捷发送条目的 5 列栅格**（id/text/button/hex/script）—— LLCOM 的 `toSendListStyle` 比 xcom_lua 的 `TransmitContent` 多了一个 hex 列独立显示。
7. **卡片式脚本列表** —— `OnlineScriptsPage.xaml:79-122` 的「Author | 粗体 Name | 横线 | Version + 灰 Description」结构，可直接套到 xcom_lua 的 `Script Console` 列表（当前是裸日志）。

## 8. 与 pic/2.png 参考工具的对照（间接相关）

`xcom_lua/docs/reference-tool-design-spec.md` 已分析过的「浅色现代串口工具」（不是 LLCOM）有：
- 顶栏高 60px 一体化，左右面板 20px 间隙双线分隔
- 绿色 `#008000` 大 SEND 按钮 + 圆角 8px
- 发送区黄调白 `#F8F8F0` 底
- 时间戳橙 `#FF7C24`

LLCOM **不遵循**这个参考工具的视觉（它是 WPF 灰白配色 + AdonisUI），但**信息架构相似**：
- 都是「左主区（数据）+ 右栏（控件）」的两段式
- 都是底部状态栏
- 都是顶栏工具 + 侧栏选项的混合

具体像素级借鉴继续走 `reference-tool-design-spec.md` 路线，LLCOM 主要借鉴**WPF 虚拟化 / 3 态 HEX / 卡片列表 / GridSplitter 拖拽**这些工程模式。
