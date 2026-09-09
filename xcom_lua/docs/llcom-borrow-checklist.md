# LLCOM 借鉴清单（llcom-borrow-checklist.md）

> 四列：优先级（高/中/低） | 借鉴项 | 当前 xcom_lua 实现位置 | 实施成本与风险
> 覆盖 UI / API / 脚本 / 架构四个维度，至少 15 条。
> 参考前 4 份文档：`llcom-overview.md`、`llcom-ui-layout.md`、`llcom-lua-api.md`、`llcom-script-system.md`。

## A. UI 维度（WPF → ImGui）

| # | 优先级 | 借鉴项 | 当前 xcom_lua 实现位置 | 实施成本与风险 |
|---|---|---|---|---|
| 1 | **中** | **3 态 HEX 显示模式**（混合 / 只字符串 / 只 HEX）。LLCOM `Pages/DataShowPage.xaml:144-149` 用 `IsThreeState="True"` CheckBox + `Settings.cs:21` `_showHexFormat` 0/1/2。 | `xcom.h:127` `hex_view : 1`（uint8_t 0/1）+ `xcom_imgui_bridge.cpp` `receive_hex` bool | **成本**：改 ABI 1 bit + `XcomDisplayOptions` 加 enum + `ui::ReceiveContent` 改复选框（ImGui `CheckboxFlags` 或自定义 3 态按钮）。<br>**风险**：ABI v1.3→v1.4 升级，window.lua/imgui_bridge.lua 要同步改。**低**——纯 enum 扩展。 |
| 2 | **中** | **GridSplitter 拖拽手柄**（改变 sidebar_width）。LLCOM `MainWindow.xaml:262-266` `GridSplitter Width="5"`。 | `xcom_imgui_bridge.cpp:2167-2169` `sidebar_width` 常量 `runtime.layout_.sidebar_width` 不可拖拽 | **成本**：加 `ImGui::Button("‖", ...)` 在 monitor_column 和 serial_column 之间，`IsItemActive` 时按 `io.MouseDelta.x` 调 `runtime.layout_.sidebar_width`（写回 user settings）。<br>**风险**：需要在 layout_ 上加 min/max 边界（150px ~ 400px），与 `compact_threshold` 联动。**低**。 |
| 3 | **低** | **底栏补端口列表 + 波特率下拉**。LLCOM `MainWindow.xaml:159-258` 状态栏有 `serialPortsListComboBox` + `baudRateComboBox`。 | `xcom_imgui_bridge.cpp` `ui::Header()` 有端口信息，`ui::Footer()` 只有连接状态 + rx_bytes + tx_bytes | **成本**：把 `Header` 的端口下拉移到 `Footer`，或在 footer 加 1-2 个 mini combo。**风险**：底部空间有限，可能挤占已发送/已接收计数显示。**低**。 |
| 4 | **低** | **卡片式脚本列表 UI**（替代裸 Checkbox）。LLCOM `OnlineScriptsPage.xaml:79-122` 的「Author / 粗体 Name / 横线 / Version + 灰 Description」75px 高卡片。 | `core/script_engine.lua` 暴露的 `script_names` / `enabled_list` 在 ImGui 端的渲染（推测在 `ui/imgui_bridge.lua`） | **成本**：写一个 `ScriptCard()` ImGui 组件，~30 行。<br>**风险**：必须保持 a11y（keyboard nav、screen reader），ImGui 没有原生支持。**低**。 |
| 5 | **低** | **PlotPage 多线波形 1000 点**。LLCOM `PlotPage.xaml.cs:44-89` 用 ScottPlot 10 线 × 1000 点 + 100ms 刷新线程。 | `core/waveform.lua` GDI 示波器（未确认多线），计划 Phase 4 用 ImPlot | **成本**：等 ImPlot 集成后照搬 10 线 × 1000 点的 ring buffer。<br>**风险**：ImPlot 与 ImGui 版本兼容（ImPlot 0.16 + ImGui 1.93 已知可用）。**中**——依赖 ImPlot。 |

## B. Lua API 维度

| # | 优先级 | 借鉴项 | 当前 xcom_lua 实现位置 | 实施成本与风险 |
|---|---|---|---|---|
| 6 | **高** | **`apiAddPoint(num, line)` ABI** —— 让 Lua 脚本把数据推到波形图多线。LLCOM `LuaApis.cs:88-91` + `PlotPage.xaml.cs:88` `LuaApis.LinePlotAdd += (s, e) => AddPoint(e.N, e.Line);`。 | `core/waveform.lua` 直接 GDI 绘制，Lua 不能通过 ABI 推数据 | **成本**：在 `xcom.h` 加 `xcom_plot_push(h, line, value)`，bridge.cpp 注册 C 回调 → C ABI → Lua。<br>**风险**：要做 ABI 边界（ring buffer + lua 端读 + ImGui 渲染）。**中**——ABI 边界 + 渲染线程安全。 |
| 7 | **高** | **`sys.publish` / `sys.subscribe` / `sys.waitUntil` 事件总线**。LLCOM `head.lua:108-125` + `LuaEnv.cs:447-503` 实现完整发布订阅 + 协程等消息。 | `core/script_engine.lua` 无任何事件总线 | **成本**：在 `script_engine.M` 加 `publish(event, ...) / subscribe(event, fn) / wait(event, ms)` 3 个方法 + 内部 queue。<br>**风险**：要做 3-strikes 隔离（订阅者的 fn 失败不能影响发布者）。**低**——已有 pcall 模式可复用。 |
| 8 | **高** | **`string.formatNumberThousands` + `string.urlEncode`**（5 行可加）。LLCOM `strings.lua:75-83` + `:133-135`。 | `core/script_engine.lua:85-125` 已实现 4 个 string 扩展，缺这 2 个 | **成本**：5 行 Lua。<br>**风险**：无。**极低**。 |
| 9 | **中** | **`apiQuickSendList(id)` 返回 hex/string 区分**。LLCOM `LuaApis.cs:62-65` 返回值首字母 `S`/`H` 标记，`head.lua:73-81` 二次包装自动 fromHex。 | xcom_lua 多发送条目（`multi_text`/`multi_hex` 字段）目前是 Lua-side 状态，没暴露给引擎 | **成本**：在 `script_engine.lua` `build_env` 加 `api_quick_send_list` 函数 + 持久化多发送条目。<br>**风险**：跨调用持久化要做弱引用，避免关闭脚本时循环引用。**中**。 |
| 10 | **中** | **`apiGetPath()` 暴露 ProfilePath**。LLCOM `LuaLoader.cs:24` `apiGetPath = CS.llcom.LuaEnv.LuaApis.GetPath`。 | 无——xcom_lua 的 runtime 目录是启动常量，没有暴露给脚本 | **成本**：在 `build_env` 加 `env.apiGetPath = function() return runtime_dir end`。<br>**风险**：脚本可借此写文件到 runtime 目录，需考虑安全性（但 xcom_lua 当前模型是 trusted-local）。**低**。 |
| 11 | **低** | **`string.toValue`（十进制字符串 → 字节串）**。LLCOM `strings.lua:44-46` `"123" → "\1\2\3"`。 | 无 | **成本**：1 行。<br>**风险**：使用场景窄（解析十进制数字节流），可延后。**极低**。 |

## C. 脚本系统维度

| # | 优先级 | 借鉴项 | 当前 xcom_lua 实现位置 | 实施成本与风险 |
|---|---|---|---|---|
| 12 | **高** | **中文目录加载保护**（utf8_to_gbk → require/loadfile/io.open monkey-patch）。LLCOM `head.lua:25-29 + :38-52`。 | 无——`package.path` 直接传给 luv，中文路径会触发 ERROR_INVALID_NAME | **成本**：在 `xcom_lua/main.lua` 启动时 monkey-patch `require/loadfile/io.open`。<br>**风险**：所有 require 都被包，性能损失 < 0.1ms；但调试时不友好（stack trace 显示 GBK 路径）。**中**——只在 Windows + 中文路径下启用。 |
| 13 | **高** | **send-convert 与长跑沙箱分离**（禁用定时器 / sys）。LLCOM `LuaLoader.cs:37-42` + `head.lua:55` `if runType == "send" then return end`。 | `core/script_engine.lua` 单 engine，send hook 与 run hook 共用 env，`sys.timer_start` 在 send hook 里也能调 | **成本**：拆 `M.new` 为 `M.new_long()` 和 `M.new_send()`，env 构建时 send 版不挂 sys/wave/highlight。<br>**风险**：send hook 脚本如果 try 了 `sys.timer_start`，会得到 nil 而不是崩——要做防御性 nil check。**中**。 |
| 14 | **中** | **chunk 缓存避免 enable 时重跑顶层代码**。LLCOM `head.lua:71-79` `_G["!once!"]` + `script[_G["!file!"]]` 缓存 `load()` 结果。 | `core/script_engine.lua:382-414` `load_script` 每次 `loadfile + setfenv + pcall`，enable 时顶层代码又跑一遍（如 `sys.taskInit` 又会创协程） | **成本**：加 `record.cached_chunk = chunk` 字段，`load_script` 优先用 cached，只重建 env + 重跑顶层。<br>**风险**：如果脚本顶层有 `local t = os.time()` 这种状态代码，cached chunk 会拿旧值——需要在 env 里注入 `os` 而不是用 Lua 内置。**中**。 |
| 15 | **中** | **3-strikes 失败后保留脚本但禁用 hook** + **重 enable 重置 strikes**。xcom_lua 已实现 `HOOK_STRIKES = 3`（`script_engine.lua:70`）。 | `script_engine.lua:556-563, :586-592, :466-470` | **0 成本**——已实现。**记录为借鉴成功**。 |
| 16 | **中** | **REPL 行内表达式回显**（尝试 `return EXPR` 失败后 fallback 到 statement）。xcom_lua 已实现 `eval_command`（`script_engine.lua:780-817`）。 | 同上 | **0 成本**——已实现。 |
| 17 | **中** | **`head.lua` 的 4 文件分层**（head/log/strings/sys 各一个文件）。LLCOM 把核心模块拆 4 个文件。 | xcom_lua 的 sandbox 代码全在 `core/script_engine.lua`（819 行），一个文件 | **成本**：拆分为 `core/script_engine.lua`（env 构建 + dispatch）+ `core/script_runtime.lua`（log + string 扩展）+ `core/script_events.lua`（新增 publish/subscribe）。<br>**风险**：纯文件拆分，导入路径要改。**低**。 |
| 18 | **低** | **Lua 脚本执行超时熔断**（`debug.sethook(trace, "l")` + `os.time() - start >= runMaxSeconds` 时 error）。LLCOM `head.lua:8-22`。 | 无——xcom_lua 用 3-strikes 限制错误次数，但不限制单次执行时间 | **成本**：在 `load_script` 末尾包一层 `debug.sethook`，3 秒超时（send-convert）或无超时（long-run）。<br>**风险**：`debug.sethook` 性能开销大（每条 Lua 指令调用一次），要限速（`count = 1000` 每 1000 条指令检查一次）。**中**。 |
| 19 | **低** | **`runType == "send"` 单例 XLua.LuaEnv 复用**（避免每次 send 重建 VM）。xcom_lua 当前 dispatch_send 也是复用同一 env。 | `script_engine.lua:382-414` `load_script` 不重建 env，只重建 record（已复用） | **0 成本**——已实现。 |

## D. 架构维度

| # | 优先级 | 借鉴项 | 当前 xcom_lua 实现位置 | 实施成本与风险 |
|---|---|---|---|---|
| 20 | **高** | **「通用通道」抽象**（Lua-side `apiSend(channel, data)` + C-side `SendChannels[channel]` 注册表）。LLCOM `LuaApis.cs:96-117` + `Uart.cs:65-74`。 | xcom_lua `core/script_engine.lua:251-269` `env.uart = { send = ..., is_open = ... }`，**通道名写死** | **成本**：把 `env.uart.send` 改为 `env.apiSend = function(channel, data) return channel_send[channel](data) end`，在 `script_engine` 构造时注册 `channel_send["uart"] = ...`。<br>**风险**：未来加 TCP/MQTT 通道时要保证 ABI 边界清晰（每个通道的 Lua-side 配置不同）。**中**——API breaking change。 |
| 21 | **中** | **错误环形队列（C ABI）**。LLCOM `LuaApis.cs:117` `SendChannelsReceived` + `Logger.AddUartLogDebug` 全程 log 到文件。xcom_lua 已有 `xcom_take_error`（`xcom.h:273`）。 | `xcom.h:171-177` `XcomError { code, source, message[256] }` + `xcom_take_error(h, output)` 已实现 | **0 成本**——已实现。 |
| 22 | **中** | **Snapshot 单结构多计数器**（rx_bytes, tx_bytes, rx_pool_exhausted_bytes, tx_rejected, auto_tick_coalesced, ui_trimmed_bytes, save_rejected_bytes, display_paused_bytes, callback_count, generation, display_pending, port_state 共 12 项）。xcom_lua 已实现 `XcomSnapshot`（`xcom.h:143-166`）。 | 同上 | **0 成本**——已实现。 |
| 23 | **低** | **Lua 沙箱里中文路径 hack**（`apiUtf8ToHex` + `fromHex` 转义）。LLCOM `LuaApis.cs:28-31` + `head.lua:38-52`。 | `core/script_engine.lua:351-356` `env.apiUtf8ToHex = function(s) return cs.utf8_to_cp(s, 936) end` **已经实现了编码转换**，但**没有应用到 require/loadfile/io.open** | 见第 12 条。 |
| 24 | **低** | **`OnlineScriptsPage` 在线脚本市场**。LLCOM `OnlineScriptsPage.xaml` + `Global.cs:615-679` 拉 GitHub Discussions。 | 无 | **成本**：高（需要运营：GitHub token、镜像站、签名校验、下载计数、版本管理）。<br>**风险**：依赖外部服务，单点失败。**极高**——可作为未来 1-2 年的产品方向，**当前不做**。 |

## 5 项「不要借鉴」（明确拒绝清单）

| 借鉴项 | 不借鉴的原因 |
|---|---|
| WPF XAML 控件（Grid/GridSplitter/RichTextBox/VirtualizingStackPanel/StatusBar/AvalonEdit/AdonisUI/FontAwesome） | xcom_lua 用 ImGui，控件栈完全不同；抄过来要做 XAML-to-ImGui 转换，价值低于直接设计 ImGui 风格 |
| XLua C# ↔ Lua 桥（`CS.llcom.X` 全局前缀） | xcom_lua 用 LuaJIT FFI + C ABI，技术栈不同 |
| `.NET Framework 4.6.2+` 依赖 | 跨平台目标不需 .NET |
| `serial_monitor_rs` Rust 串口监听辅助进程 | LLCOM 用它来监听其他软件的串口（sniffer），xcom_lua 还没需求 |
| ScottPlot WPF 控件 | xcom_lua 用 ImPlot 或自绘 GDI（`core/waveform.lua`），ScottPlot 是 WPF 专属 |
| Costura.Fody 单文件 exe 打包 | xcom_lua 是 DLL 套 DLL，不需打包成单 exe |

## 总览矩阵

| 维度 | 高 | 中 | 低 | 总计 |
|---|---|---|---|---|
| UI | 0 | 2 | 3 | **5** |
| Lua API | 3 | 3 | 1 | **7** |
| 脚本系统 | 2 | 4 | 2 | **8** |
| 架构 | 1 | 2 | 1 | **4** |
| **总计** | **6** | **11** | **7** | **24** |

## 推荐落地顺序（Top 6 高优先级）

按实施性价比排：

1. **#8 `string.formatNumberThousands` + `string.urlEncode`**（5 行，0 风险）—— 5 分钟
2. **#12 中文目录加载保护**（monkey-patch require/loadfile/io.open）—— 30 分钟
3. **#14 chunk 缓存**（避免 enable 重跑顶层代码）—— 2 小时
4. **#13 send-convert 与长跑沙箱分离**（拆 M.new）—— 半天
5. **#7 sys.publish/subscribe/waitUntil 事件总线**（3 方法 + queue）—— 1 天
6. **#20 「通用通道」抽象**（apiSend/channel 注册表）—— 1-2 天

每个完成后跑 `xcom_lua/tests/test_script_engine.lua` 验证不破坏现有功能。
