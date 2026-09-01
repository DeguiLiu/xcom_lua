# xcom_lua —— LuaJIT + Win32 FFI 串口客户端设计

> 版本: v0.2
> 日期: 2026-09-01
> 状态: Win32 + Dear ImGui 实现中

## 1. 目标与范围

用 **LuaJIT + Win32 FFI(+ GDI 自绘标题栏)** 实现一个在 Windows 上运行的串口调试工具,整体行为与已经实现的 Python 版 `xcom_client`(PySide6) 一致,复用其参考的 核心行为与界面布局。

串口与核心逻辑**复用现有 `xcom_core.dll`**,通过其版本化 C ABI(`xcom_core/include/xcom/xcom.h v1.2`)调用,并用 LuaJIT `ffi.cdef` 直接绑定该 DLL——不引入 librs232、不使用 wxWidgets/wxLua/DuiLib/LuaDui 这些库本身。`ref/wxlua-master`、`ref/LuaDui-master` 仅作为 Lua 绑定 Win32 GUI 的组织手法参考,可借鉴写法/抄写片段。

本客户端**先全部在 Linux 下写好并做静态检查与纯 Lua 逻辑单测,后期再上 Windows 联调**(Win32 GUI/串口 FFI 部分无法在本 Linux 环境运行)。

### 技术选型(已与用户确认)

| 维度 | 决策 |
| --- | --- |
| 运行时 | LuaJIT(Windows 侧用 `openresty-1.29.2.1-win64/luajit.exe` + `lua51.dll`;Linux 侧验证用 `/home/dgliu/.local/openresty/luajit/bin/luajit`) |
| 核心逻辑 | 复用 `xcom_core.dll`,LuaJIT FFI 直接 bind `xcom.h v1.2` C ABI |
| GUI 渲染 | Dear ImGui (Win32 + OpenGL2 后端),保留原生 Win32 控件作为故障回退|
| 窗口边框 | 无边框自绘标题栏(`WS_POPUP` + `HTCAPTION` 拖动 + `SC_SIZE` 边缘 resize)|
| 主题 | Siemens 工业浅色主题：`#EEF1F4` 背景、`#6FA8DC` 描边、`#0078D7` 焦点蓝、`#009999` 主操作|
| 字体 | `assets/fonts` 中的 Siemens Slab Roman / Bold；缺失时回退到 Segoe UI |
| 线程模型 | 单线程(Win32 消息循环所在线程直接调 ABI);`xcom_open/close` 阻塞 UI 至多约 2s,接受 |
| 接收视图 | 系统 `riched20.dll` 的 `RICHEDIT` 控件,`EM_SETCHARFORMAT` 按 ANSI 颜色段设色 |
| ANSI 解析 | 支持 ANSI/SGR 转义解析 + 跨批次残留,行为对齐 Python 端 `widgets/ansi.py` |
| 配置持久化 | 手写极简 key=value(INI 风格)解析器,配置文件 `config.ini`(与 Python 端 `config.toml` 不共享)|
| 发送面板 | 4 个 tab 框架,仅实现实用 2 个:单发 tab + 多发 tab;协议传输/帮助为占位文字 |
| 代码风格 | 对齐 OpenResty/LuaJIT 生态惯例(局部优先、模块返回表、`local` 一贯) |

### 明确不做(本次范围外)

深色主题切换、圆角/悬浮凹面等自定义 QSS 细描边、内嵌自定义字体、TCP/UDP/SSH/协议开发平台、多设备并发、多线程后台 worker、`librs232`、wxWidgets/DuiLib/LuaDui 库集成。

## 2. 总体架构

```
xcom_lua/
  main.lua                  入口:固定工作目录,加载 dll 与 ui.window,进入消息循环
  config.ini                运行期生成:窗口几何/串口参数/显示选项/快捷发送项/自动保存路径
  core/
    xcom_ffi.lua            xcom.h v1.2 的 ffi.cdef 镜像 + xcom_core.dll 加载 + 封套
    config.lua              极简 INI(key=value)读写(纯 Lua,可单测)
    ansi.lua                ANSI/SGR 流式解析器 + 浅色 palette(纯 Lua,可单测)
  ui/
    win32.lua               Win32 API/GDI 的 ffi.cdef 封装(窗口类/消息/绘制/字体/定时器)
    window.lua              主窗口类:窗口过程、消息循环、标题栏、HWND->回调分发
    controls.lua            控件创建与封装(按钮/下拉/编辑/复选框/RICHEDIT + ID 分配)
    connection_panel.lua    连接参数面板
    receive_view.lua        接收视图(RICHEDIT + ANSI 着色 + 裁剪 + 滚到底)
    send_panel.lua          发送面板(单发 tab + 多发 tab)
    status_bar.lua          状态栏(端口状态/RX TX/丢弃/时钟)
  tests/                   纯 Lua 逻辑单测(busted 风格手写断言,luajit 直跑)
```

## 3. 线程与调用模型

**单线程**:整个程序只有一个真实线程——Win32 消息循环所在线程,`xcom_core.dll` 的所有 ABI 调用都在这个线程上串行发生。

- `xcom_create / xcom_list_ports / xcom_open / xcom_close / xcom_send / xcom_set_options / xcom_set_auto_template / xcom_drain_display / xcom_get_snapshot / xcom_take_error` 均由本线程调用。
- `SetTimer` 驱动轮询:显示 drain 周期与状态 snapshot 周期两个定时器(可对齐 Python 端节奏)。
- `xcom_open`/`xcom_close` 阻塞至多约 2s,期间 UI 不响应;这是已接受的取舍(避免 LuaJIT 手搓跨线程 FFI 同步的安全复杂度)。
- 关闭流程:先 `xcom_close`,再在消息循环空闲时确认接收尾批已渲染,最后 `xcom_destroy` 并退出循环。

## 4. GUI 渲染设计

### 4.1 主窗口(无边框)

- 用 `RegisterClassExW` 注册自定义窗口类,`CreateWindowExW` 用 `WS_POPUP` 建窗。
- 客户区分为:顶部自绘标题栏(高 ~32px)、中部工作区、底部状态栏。
- **标题栏拖动**:在客户区左键按下时把 `WM_NCHITTEST` 返回 `HTCAPTION`,由系统免费处理拖动;双击标题栏切换最大化(`SC_MAXIMIZE`/`SC_RESTORE`)。
- **边缘 resize**:`WM_NCHITTEST` 在边缘 6px 内返回 `HTLEFT/HTRIGHT/HTTOP/HTBOTTOM/HTTOPLEFT/...`,复用系统 `SC_SIZE` 逻辑,不手写几何。
- **自绘标题栏内容**(`WM_PAINT` GDI 绘制):品牌标记(↯)+ 标题 "XCOM" + 副标题 "SERIAL CONSOLE" + 连接状态徽章("ONLINE"/"OFFLINE",按端口状态换色)+ 右上角最小化/最大化/关闭三个自绘按钮(点击用 `WM_LBUTTONDOWN/UP` + 按钮矩形判定)。
- 标题栏背景用西门子蓝/深色条;状态徽章在 ONLINE 时用绿色系,OFFLINE 用灰。

### 4.2 控件

- **标准控件优先**:`Button`(`BS_PUSHBTN`) 用于 Open/Close/Clear/Save、单发 Send、多发页导航组;`ComboBox`(`CBS_DROPDOWNLIST`) 用于端口/波特率/数据位/校验/停止位/流控;`CheckBox`(`BS_AUTOCHECKBOX`) 用于 DTR/RTS、接收选项、发送选项;多行输入用 `Edit`(`ES_MULTILINE`)。
- **接收视图**:`riched20.dll` 的 `RICHEDIT`(`ES_MULTILINE|ES_READONLY|ES_AUTOVSCROLL`),用 `EM_SETCHARFORMAT` 按 ANSI 解析器切出的颜色段逐段设色;原生自带滚动/选择/复制。
- **事件路由**(借鉴 LuaDui `lcontrol.cpp` 的模式):一个 `id -> Lua handler` 哈希表;`WM_COMMAND`/`WM_NOTIFY` 里按控件 ID 查到处理函数调用。控件生命周期等于窗口生命周期,用普通表即可,不需弱表。
- **字体/刷子**:创建一次 `LOGFONT`(系统字体)+ 若干常驻颜色刷子;`WM_CTLCOLORBTN/STATIC/DLG` 返回对应刷子实现面板/编辑框背景着色。

### 4.3 积分对齐(浅色,西门子 palette)

取 style.qss 的关键 token 转成十六进制常量,集中放在一个 Lua 表:

- 页面背景 `#EEF1F4`,卡片/输入框 `#FFFFFF`,文字 `#1F2933`
- 权威蓝(标题/激活)`#0078D7`,深蓝点缀 `#005A9E`
- 触发色(青色)`#009999`,触发 hover `#00B3B3`
- 状态绿 `#008000`,警示 `#C40000`
- ANSI 浅色 palette 沿用 xcom_client `widgets/ansi.py` 的 `_LIGHT` 表。

## 5. 模块职责

### 5.1 `core/xcom_ffi.lua`

- `ffi.cdef` 完整镜像 `xcom.h` 的 struct 与函数(注意 MSVC x64 自然对齐,`_pad` 明确存在,布局照抄)。
- `ffi.load` 加载 `xcom_core.dll`(路径优先取环境变量,缺省取可执行文件同目录/脚本同目录)。
- 提供 Lua 友好的封套:常量表(`XCOM_*`)、`list_ports()`、`create()`、`open(config)`、`close(timeout_ms)`、`send(data, flags)`、`set_options(opts)`、`set_auto_template(data, interval_ms, flags)`、`drain_display(capacity)`、`get_snapshot()`、`take_error()`、`destroy()`。
- 该模块在 Linux 上仅作静态检查(`luajit -bl` + 对 `xcom.h` 的逐字段复核),无法运行。

### 5.2 `core/config.lua`(纯 Lua,可单测)

- 极简 key=value 解析/序列化,支持注释(`;`/`#`)、`[section]` 节名、`key = value`。
- 值类型解析为 number/boolean/string;保存时按类型写回。
- 字段对齐 xcom_client 持久化的核心项:窗口 w/h、串口串口参数(port/baud/data/stop/parity/flow/dtr/rts)、显示选项(receive_hex/timestamp/pause/display/autoclear 阈值/autosave path)、20 个多发条目(每页 8 条 × 页内 index),用简单序列化格式(如 `page.0.0.text` / `page.0.0.enabled`)。
- 提供 `load(path) -> table` / `save(path, table)`。

### 5.3 `core/ansi.lua`(纯 Lua,可单测)

- 流式 ANSI/SGR 解析器,行为对齐 `widgets/ansi.py`:`ESC[` SGR 解析、颜色段(前景/背景/亮色映射到浅色 palette)、跨批次残留(residue)状态、非 SGR CSI 剥离。
- 输出段表:`{ text=..., fg=0xRRGGBB, bg=0xRRGGBB|nil }`,供 RICHEDIT 设色。

### 5.4 `ui/win32.lua`

- Win32 API/GDI/公共控件/RICHEDIT 的 `ffi.cdef`(只声明实际用到的子集):`RegisterClassExW`、`CreateWindowExW`、`DefWindowProcW`、`SendMessageW`、`MessageBoxW`、`GetWindowLong*/SetWindowLong*`、`LoadLibrary`、`SetTimer`、GDI 画笔/刷子/字体、`WM_*`/`HT*` 常量。
- 提供 `win32.const` 表(token 名 -> 数值),避免魔法数散布。

### 5.5 `ui/window.lua`(主类)

- 注册窗口类、创建主窗口、持有 `conn/recv/send/status` 四个面板的构造与排版。
- WndProc 分发:`WM_PAINT`(标题栏)、`WM_NCHITTEST`(拖动/resize)、`WM_COMMAND`/`WM_NOTIFY`(路由到面板 handler)、`WM_CTLCOLOR*`(着色)、`WM_SIZE/WM_MOUSEWHEEL`(布局)、`WM_CLOSE/WM_DESTROY`(关闭协议)。
- 持有一个全局 `struct XcomHandle` 与当前串口状态,把 ABI 调用串行化在此。

### 5.6 `ui/controls.lua`

- 控件创建封装:`new_button/text/send_button/cb_combo/multi_edit/multi_checkbox/rich_edit` 等。
- 统一 `id -> handler` 分发表 + ID 分配器。

### 5.7 面板实现要点

- **ConnectionPanel**(连接参数,右侧固定宽 `~160px`):Port(下拉+刷新按钮)、Baud/Data/Parity/Stop/Flow(下拉)、Line(DTR/RTS 复选)、Open/Close(主/危险色按钮)、Clear/Save……
- **ReceivePanel**(接收,左侧主区):Receive HEX / Timestamp / Pause display / Auto clear(复选 + 字节 spin)/ Auto save,右侧 monitor status(`● LINK LIVE` / `● LINK IDLE`);下方 RICHEDIT 接收视图。
- **ReceiveView**(行为对齐):ANSI 分段着色、HEX 视图(把 drain 出的 "AA BB CC " 文本直接按 hex 显示,FIFO 有界(4000 段、每段 4096 字符上限)、仅保留最近窗口、清空时重置 residue、挂到底部则自动滚动)。
- **SendPanel**:Tab 页签(单发/多发/协议传输占位/帮助占位)。单发 tab:多行输入 + HEX/换行/循环复选 + 周期 spin + Send 按钮。多发 tab:8 行(复选+编辑+数字按钮)、底部导航(Remove/Add page、First/Prev/Next/Last、Page spin + Go、Send enabled)、支持数字键绑定(Alt+N)与 Auto cycle 循环发送、HEX/CRLF 标志。
- **StatusBar**:端口状态文字、`RX x  TX y`、`drops: z  trim: ..  pause: ..`、时钟(`yyyy-MM-dd  HH:mm:ss`)。

## 6. 串口数据流

- 发送:Send/快速/循环 → 按 `flags`(HEX 预编码 + CRLF)构造 `data` → `xcom_send`。HEX 解码在 Lua 侧用 `string`/FFI 手写(对齐 Python `bytes.fromhex`)。
- 自动循环发送:对单发 tab 调 `xcom_set_auto_template`(interval_ms>0 启用,0 禁用);多发 tab 的 "Auto cycle" 用 Lua 侧 `SetTimer` 按 multi_period 发多个已启用的条目(多发循环不走 core 的 auto-template,因为它是多条)。
- 接收:drain 出的显示批次是 **UTF-8 文本**(text 视图原样 + 可选时间戳前缀,hex 视图已是 "AA BB CC " 序列)。`ReceiveView` 直接获得该 UTF-8 文本,经 `ansi.lua` 分段着色后填入 RICHEDIT。

## 7. 错误与健壮性

- 所有 ABI 调用检查返回码;`xcom_take_error` 弹出的错误显示到状态栏。
- 打开/关闭失败不置 UI 于死锁:保持互锁(端口参数在 OPEN 时禁用)。
- 配置读写失败时使用默认值,不崩溃。
- 关闭窗口:若端口开着,先调用 `xcom_close(timeout)` 再退出循环;不追求 Python 端复杂的多轮 close-drain 管线,接受简化。

## 8. 验证策略

- **Linux 阶段(本会话)**:纯 Lua 模块(`config.lua`、`ansi.lua`,以及扩展的发送编码/HEX 解码等纯逻辑)写成无 Win32 依赖,并在 `/home/dgliu/.local/openresty/luajit/bin/luajit` 下以手写断言脚本跑单测。`xcom_ffi.lua`、`win32.lua`、`window.lua` 等含 FFI 定义/需要 Windows DLL 的模块无法运行,只做 `luajit -bl` 语法检查 + 对照 `xcom.h`/Win32 头逐字段静态 review。
- **Windows 阶段(用户后期)**:把本目录连同 `openresty-1.29.2.1-win64` 运行时与 `build/native-release/bin/xcom_core.dll` 带到 Windows,`luajit.exe main.lua` 实跑。留下一份 Windows 联调待办清单(见 `docs/windows-handoff.md`)。
