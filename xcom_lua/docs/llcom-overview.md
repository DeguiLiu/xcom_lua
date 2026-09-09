# LLCOM 项目总览（llcom-overview.md）

> 研究只读。不修改任何 LLCOM 源码。
> 参考路径：`D:\workspace\SSCOM_lua\ref\llcom\`（已解压的 tarball，无 `.git`）。
> 项目主页：https://github.com/chenxuuu/LLCOM

## 1. 项目身份

| 字段 | 值 | 证据 |
|---|---|---|
| 名称 | LLCOM | `README.md:1` |
| 作者 | chenxuuu（主），whc2001 / neomissing / RuoYun / 王龙 / linhongz 贡献 | `README.md:163-175` |
| 协议 | Apache 2.0 | `README.md:159` |
| UI 技术栈 | **WPF**（C# .NET Framework 4.6.2+），不是 ImGui | `llcom/llcom.csproj` + `View/MainWindow.xaml` |
| 脚本引擎 | **XLua**（腾讯 C# ↔ Lua 桥，Lua 5.3） | `llcom/Lib/XLua.Mini.dll`，`LuaApi.md:5` |
| 主要功能 | 串口调试 + Lua 脚本可编程 + TCP/UDP/MQTT/WinUSB 通道 | `README.md:35-56` |
| 中文界面 | 是，主语言 | `View/MainWindow.xaml` 全中文 `TextBlock` + `DynamicResource` |

> **重要差异**：ref/README.md 第 14 行说「Lua 脚本 + ImGui UI + 串口收发」—— 这是对 LLCOM 的概括，**实际上 LLCOM 用的是 WPF + XLua，不是 ImGui**。这是它与 xcom_lua **真正不同**的一点。

## 2. 架构（Lua/C++/C# 三层，对照 xcom_lua 的 Lua/C++ 双层）

LLCOM 是真正的 **三层栈**：

```
┌──────────────────────────────────────────────────┐
│  C# WPF UI 层                                    │
│  ├─ View/MainWindow.xaml                         │
│  │   ├─ 顶部：标题栏/工具栏（菜单 + 状态栏 21 列）│
│  │   ├─ 中部左：DataShowPage.xaml（接收 log）    │
│  │   ├─ 中部右：GridSplitter + TabControl        │
│  │   │   ├─ 快捷发送 10 页                       │
│  │   ├─ 底部：状态栏（端口/波特率/Sent/Recv）   │
│  ├─ Pages/：14 个 Page 子控件                    │
│  └─ View/SettingWindow.xaml                      │
├──────────────────────────────────────────────────┤
│  C# 业务逻辑（Model + Tools）                     │
│  ├─ Model/Uart.cs        System.IO.Ports.SerialPort│
│  ├─ Model/Settings.cs    串口参数 + 编码 + 快捷发送│
│  ├─ LuaEnv/LuaEnv.cs     XLua 虚拟机 + sys 框架   │
│  ├─ LuaEnv/LuaRunEnv.cs  全局 Lua 上下文管理      │
│  ├─ LuaEnv/LuaApis.cs    暴露给 Lua 的 C# 静态方法│
│  ├─ LuaEnv/LuaLoader.cs  初始化 + 脚本加载        │
│  ├─ Tools/Global.cs      全局状态机 + 设置 JSON    │
│  ├─ Tools/Logger.cs      UART log + Lua log 文件  │
│  └─ Pages/PlotPage.xaml.cs ScottPlot 绘图        │
├──────────────────────────────────────────────────┤
│  Lua 脚本层（运行时由 XLua 解释）                  │
│  ├─ core_script/        启动注入                  │
│  │   ├─ head.lua        路径 + 中文路径 hack + 重写│
│  │   ├─ log.lua         log.* 6 级                │
│  │   ├─ strings.lua     string.toHex/fromHex/split│
│  │   └─ sys.lua         sys.wait/taskInit/...     │
│  └─ user_script_run/    长期任务脚本              │
│      ├─ example.lua     教程样例                  │
│      ├─ channel-demo.lua 通用通道演示             │
│      └─ 循环发送快捷发送区数据.lua                │
└──────────────────────────────────────────────────┘
```

对应 xcom_lua（双层，C++ + Lua，**无 C#**）：

```
xcom_lua/
├─ C++17 ImGui DLL（DLL + 桥接 C ABI）
│  ├─ xcom_core/          （跨语言 C ABI）
│  ├─ xcom_imgui/         （DX11 + Dear ImGui 1.93 仪表盘）
│  └─ native/xcom_imgui_bridge.cpp 1747 行 ImGui UI
├─ Lua 层（LuaJIT + FFI）
│  ├─ ui/window.lua, imgui_bridge.lua  Lua UI
│  ├─ core/                业务模块
│  └─ scripts/             Phase 4 脚本系统（已实现）
└─ C ABI 头文件  xcom_core/include/xcom/xcom.h v1.3
```

## 3. 模块 1:1 对应表

| LLCOM | xcom_lua | 1:1? | 说明 |
|---|---|---|---|
| `Model/Uart.cs`（`System.IO.Ports.SerialPort`） | `xcom_core` C ABI（Win32 串口） | **结构同构** | 都是独占式串口句柄 + 事件驱动接收 |
| `LuaEnv/LuaApis.cs` `Send(string channel, byte[] data, XLua.LuaTable table)` | `xcom_core` `xcom_send(h, data, size, flags)` | **结构同构** | 都是把 Lua 字节流送进核心驱动 |
| `LuaEnv/LuaApis.cs` `SendChannelsRegister("uart", cb)` | FFI 回调注册 | 同构 | 「通道」概念 = 多生产者 |
| `LuaEnv/LuaRunEnv.cs` `triggerCB` + `toRun` ConcurrentBag | `core/script_engine.lua` `M:dispatch_receive` | **功能重叠** | 都是把外部事件派发到 Lua 协程 |
| `DefaultFiles/core_script/head.lua` + `sys.lua` | `core/script_engine.lua` 自己实现 env | **不一致** | LLCOM 沿用合宙 Luat 框架，xcom_lua 重新设计 |
| `DefaultFiles/core_script/log.lua` 6 级 | `core/script_engine.lua` `LEVEL_TAG` 6 级 | **几乎相同** | `trace/debug/info/warn/error/fatal` 完全对齐 |
| `DefaultFiles/core_script/strings.lua` `string.toHex/fromHex/split/utf8Len/urlEncode/formatNumberThousands` | `core/script_engine.lua` `str_toHex/str_fromHex/str_split/str_utf8Len` | **子集重叠** | xcom_lua 已经实现了核心 4 个，缺 `urlEncode` 和 `formatNumberThousands` |
| `LuaApi.md` 的 `apiSend/apiSetCb/apiUnsetCb` | FFI 调 `xcom_send` + 自定义 `on.receive` | **API 形态不一致** | LLCOM 是「订阅-发布」，xcom_lua 是「回调注册」 |
| `Pages/PlotPage.xaml.cs` ScottPlot 10 线 × 1000 点 | `core/waveform.lua` GDI 示波器 | **不同库** | LLCOM 用 ScottPlot（WPF 控件），xcom_lua 计划用 ImPlot |
| `MainWindow.xaml` 三段式（接收 / 输入+快捷 / 状态栏） | `xcom_imgui_bridge.cpp` 两列式（monitor_column + serial_column） | **结构相似，但镜像** | LLCOM 是「左中右」，xcom_lua 是「左主区 + 右栏」 |
| `Global.cs` `ProfilePath` = `%LocalAppData%\llcom\` | xcom_lua runtime 同目录 | 同 | 用户数据目录都在应用根 |
| 14 个 `Pages/*.xaml`（TCP/UDP/MQTT/WinUSB/编码/绘图等） | xcom_lua 无对应 | **缺位** | xcom_lua 当前只做串口，没有多通道 |
| `OnlineScriptsPage.xaml` 在线脚本市场（GitHub Discussions 拉取） | xcom_lua 无 | **缺位** | 这是 LLCOM 的「分发生态」功能 |
| `lua.xshd` AvalonEdit Lua 语法高亮 | 无（可能用 ImGui InputTextMultiline） | 不同 | |
| `Lua.xshd` 实际是 `llcom/Lua.xshd`，AvalonEdit 配色 XML | | | |

## 4. 借鉴价值排序（按对 xcom_lua 当前痛点的契合度）

### Tier 1（直接照搬就能解决 xcom_lua 现有问题）

1. **LLCOM 的 Lua env 设计模式** —— `head.lua` + `log.lua` + `strings.lua` + `sys.lua` 的 4 文件分层，比 xcom_lua 现在所有 sandbox 代码全塞在 `core/script_engine.lua` 一个文件里清晰得多。我们已经有等价实现，但**目录拆分值得做**。
2. **`sys.publish`/`sys.waitUntil`/`sys.subscribe` 的发布订阅模式** —— xcom_lua 当前没有跨脚本事件总线，3 个示例脚本之间没法通信。
3. **`apiUtf8ToHex` 中文路径 hack** —— `head.lua:25-29` + `head.lua:38-52` 把 `require/loadfile/io.open` 都包了一层 UTF-8 → GBK 转码，**解决中文目录下的 Lua 加载崩溃**。xcom_lua 没有这个保护。
4. **`string.toHex/fromHex/split/utf8Len/urlEncode/formatNumberThousands` 全套 string 扩展** —— xcom_lua 只实现了前 4 个，缺 `urlEncode` 和 `formatNumberThousands`。
5. **`apiAddPoint(num, line)` 多线波形 API** —— 直接对应 `core/waveform.lua` 的「多通道」需求（目前只有 1 线）。

### Tier 2（架构层面值得参照）

6. **「通用通道」抽象**（`LuaApis.SendChannelsRegister("uart", cb)` + `LuaApis.Send` + `LuaApis.SendChannelsReceived("uart", data)`）—— Lua 端用 `apiSend("uart", data)` 就能发串口，`apiSend("mqtt", nil, {topic=, payload=})` 发 MQTT，**Lua 侧不感知底层通道细节**。xcom_lua 目前 `uart.send(data)` 把通道写死，未来加 TCP/MQTT 时会想扩展。
7. **LuaRunEnv 与 LuaEnv 的两层** —— `LuaEnv.cs` 是单脚本长跑沙箱（带 sys 调度），`LuaRunEnv.cs` 是「一次性 send-convert 沙箱」（不带 sys，没有 log/print）。xcom_lua 的 `script_engine.lua` 把这两种混在一起，应该参考 LLCOM 分开。
8. **Lua 脚本超时熔断** —— `head.lua:8` `runMaxSeconds = runType == "send" and 3 or -1` + `head.lua:17-22` `debug.sethook(trace, "l")` 在 `os.time() - start >= runMaxSeconds` 时 `error("代码运行超时")`。xcom_lua 用「连续 3 次失败自动禁用」（`core/script_engine.lua:70` `HOOK_STRIKES = 3`）—— 不同策略，可互补。

### Tier 3（小功能可抄）

9. **3-strikes 自动禁用 hook** + **启用时重置 strikes** —— LLCOM 没有这个，但 xcom_lua 已实现，是 LLCOM 缺的安全网。
10. **`apiInputBox` 输入框** —— LLCOM `LuaApis.cs:72-79` 通过 `App.Current.Dispatcher.Invoke` 弹模态。xcom_lua 用 ImGui，可以直接 `ImGui::OpenPopup` 模态。
11. **`apiQuickSendList(id)` 返回值带 `S`/`H` 前缀表示 string/hex** —— `LuaApis.cs:62-65` + `head.lua:73-81` 二次包装。xcom_lua 的多发送条目目前没有 hex/string 区分。
12. **`apiGetPath()` 返回 ProfilePath** —— LLCOM 是 `%LocalAppData%\llcom\`，xcom_lua runtime 同目录（不同策略，无好坏）。

## 5. 不应借鉴的部分

- **WPF 整套 UI** —— 我们用 ImGui，没必要反着抄 XAML。LLCOM 的 WPF 控件、AdonisUI 主题、VirtualizingStackPanel、XAML GridSplitter、StatusBar 21 列布局…… 都是 WPF-only。
- **`XLua` C# ↔ Lua 桥** —— 我们是 C++ + LuaJIT FFI，技术栈完全不同。
- **`.NET Framework` 4.6.2+ 依赖** —— 跨平台目标不需要。
- **`scripts/channel-demo.lua` 里 `mqtt/tcp-server/socket-client/netlab/winusb` 5 个通道 demo** —— 我们还没有这些通道，抄过来是「画饼」。
- **`OnlineScriptsPage.xaml` 在线脚本市场（GitHub Discussions 拉取 + RestSharp）** —— 这是 LLCOM 的「产品」功能，不是工程能力。需要运营成本（GitHub token、镜像站、签名校验），xcom_lua 当前不需要。
- **`lua.xshd` AvalonEdit 高亮配色** —— WPF 专属。

## 6. LLCOM 的 Lua 5.3 vs xcom_lua 的 LuaJIT 差异

LLCOM 用 Lua 5.3（XLua 内置），xcom_lua 用 LuaJIT：
- **bit 库**：LuaJIT 内置 bit 库（`bit.band`/`bit.bor`/`bit.lshift`），Lua 5.3 用 `bit32` 或 `bit.`。`sys.lua` 里的 id 生成（`msgId = TASK_TIMER_ID_MAX`、`bit.band`）是 5.3 风格，要移植需改写。
- **`goto` / `continue`**：Lua 5.3 支持，LuaJIT 不支持。LLCOM 代码中没出现。
- **整数子类型**：Lua 5.3 整数 vs 浮点有区分；LuaJIT 全是 double（除非用 cdata）。
- **`string.pack`/`unpack`**：5.3 新增，LuaJIT 没有（用 FFI struct 替代）。

## 7. 文件地图（接下来 4 份文档会引用）

```
D:\workspace\SSCOM_lua\ref\llcom\
├─ README.md                       项目说明 + 功能列表
├─ LuaApi.md                       完整的 Lua 端 API 文档（816 行）
├─ llcom/
│  ├─ llcom.csproj                 C# 工程文件
│  ├─ LuaEnv/
│  │  ├─ LuaEnv.cs                 XLua 沙箱 + sysCode 内嵌 sys.lua
│  │  ├─ LuaRunEnv.cs              全局长跑脚本上下文
│  │  ├─ LuaApis.cs                C# 静态方法注册
│  │  └─ LuaLoader.cs              Initial() 入口
│  ├─ Model/
│  │  ├─ Uart.cs                   System.IO.Ports.SerialPort 封装
│  │  ├─ Settings.cs               所有可序列化设置
│  │  └─ ToSendData.cs             快捷发送条目模型
│  ├─ Pages/
│  │  ├─ DataShowPage.xaml         接收 log 渲染模板
│  │  ├─ OnlineScriptsPage.xaml    在线脚本市场 UI
│  │  ├─ PlotPage.xaml.cs          ScottPlot 10 线绘图
│  │  └─ SerialMonitorPage.xaml    串口监听子页面
│  ├─ Tools/
│  │  ├─ Global.cs                 全局状态 + 配置加载 + UTF-8 工具
│  │  ├─ Logger.cs                 UART log + Lua log
│  │  └─ InputDialog.cs            apiInputBox 后端
│  ├─ View/
│  │  └─ MainWindow.xaml           主窗口 3 段布局
│  └─ DefaultFiles/
│     ├─ core_script/              启动注入
│     │  ├─ head.lua               路径 + 中文 hack + print 重写
│     │  ├─ log.lua                6 级日志
│     │  ├─ strings.lua            string 库扩展
│     │  ├─ sys.lua                sys 调度框架（内嵌在 LuaEnv.cs）
│     │  └─ JSON.lua               JSON 库
│     ├─ user_script_run/          长期任务脚本
│     │  ├─ example.lua            教程样例
│     │  ├─ channel-demo.lua       多通道演示
│     │  └─ 循环发送快捷发送区数据.lua
│     ├─ user_script_send_convert/ 一次性 send-convert 脚本
│     │  └─ default.lua            `return uartData` 原样
│     └─ user_script_recv_convert/ 一次性 recv-convert 脚本
│        └─ default.lua            `return uartData` 原样
├─ scripts/                        工程脚本
│  ├─ tcptest.lua
│  ├─ 自动回复.lua
│  └─ readme.md
└─ serial_monitor_rs/              Rust 串口监听辅助进程（与 LLCOM 主程序配合）
```
