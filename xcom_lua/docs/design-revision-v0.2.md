# xcom_lua 方案修订 v0.2: 参考库调研与缺陷发现

> 版本: v0.2
> 日期: 2026-09-01
> 状态: 评审稿, 缺陷清单待确认后进入实施
> 运行时: openresty-1.29.2.1-win64 (luajit.exe + lua51.dll)

## 1. 结论

六个参考库均**不集成**。原因分四类:

| 库 | 形式 | 弃用理由 |
| --- | --- | --- |
| win32lualib | C 扩展, Lua 5.3 | x86, 链 debug CRT, 无 Win32 GUI / 串口内容 |
| win32exts | x86 闭源 DLL | x86; 内部静态链 LuaJIT 2.0.3, 与 2.1 VM 冲突; 无 LICENSE |
| lua-llthreads | C 扩展 | cdata 无法跨线程传递, 运行中线程无通道, 见 5.2 节 |
| wxlua | C++ 绑定生成器 | 只借 ID 分配与 registry-ref 保活模式 |
| winapi | C 扩展 (Steve Donovan) | 需编译; 只借 BuildCommDCB 串口解析思路 |
| win32_api_luajit | 纯 LuaJIT FFI cdef | cdef 供体, 但硬断言 32 位, RICHEDIT 为空 stub, 无 TextOut; 无 LICENSE |

真正影响方案的是两类产出: 一是 **8 个现有 bug**（Linux 上可测出来, 143 条单测全绿却没盖住）, 二是 **一个 C ABI 能力应当从 xcom_core.dll 补上**, 从而删掉设计 v0.1 的"接受 2 秒 UI 冻结"妥协（对应 `docs/design.md` 3 节、`docs/windows-handoff.md` 4.5 节）。

## 2. 现状核验

- 现有 4 个单测全绿（config 32 + ansi 30 + xcom_ffi 37 + view_model 44 = 143 断言）。
- 静态检查仅 `luajit -bl` + require 探测, **抓不到局部函数前向引用、未定义变量、cdef 与 API 错配**。
- `docs/windows-handoff.md` 4.1 节已列出 `WPARAM`/`LPARAM` 等联调风险, 但未覆盖本地即可测出的必崩缺陷。

## 3. 缺陷清单与修复状态

标记: `[必崩]` 首次调用即失败; `[x64]` 64 位截断; `[可测]` Linux 上可静态/逻辑验证。3.1 至 3.5 均已修复, 验证见 6.1 节。

### 3.1 局部函数前向引用（4 处 `[必崩][可测]` 已修）

`create_class`、`stop_text/parity_text/flow_text`、`stop_index/parity_index/flow_index`（均在 `ui/window.lua`）、`vmerge`（`ui/controls.lua`）四组均在定义行之前被调用。Lua 按词法位置解析同作用域 `local function` 引用, 因此调用处读到的是 nil 全局, 主窗口建不出来。

修法: 在首个使用点之前加前向声明（`local create_class` 等）, 原 `local function f()` 改为 `f = function()`。见 `ui/window.lua:114`、`:181` 与 `ui/controls.lua:194`。

### 3.2 未定义变量（`[必崩][可测]` 已修）

`ui/status_bar.lua` 原 `make(..., width or 200, ...)` 引用的 `width` 只是 `make` 自己的形参, 在调用点 `M.create` 作用域内未定义。

`make` 内部对该形参的用法为零（只用 `label_counts`、`height`、`y`）, 所以删掉形参与实参, 而非补字面量。现签名 `make(parent, label_counts, height, y)`, 见 `ui/status_bar.lua:17`。

### 3.3 FFI cdef 位宽（`[x64]` 已修）

`WNDPROC` 返回类型原为 `LONG`, x64 上截断 `DefWindowProc` 的指针尺寸返回值与 `WM_CTLCOLOR*` 回传的 HBRUSH。现为 `intptr_t`（`ui/win32.lua:278`）, 与已改好的 `SendMessageA`/`DefWindowProcA` 一致。

另有四个声明从未被调用: `NMHDR`（字段名也不对, 真实布局是 `hwndFrom/idFrom/code`）、`SetWindowLongA`、`GetWindowLongA`、`GetWindowLongW`。后三者在 x64 上会截断, 但因无调用点不构成当前缺陷。按"先简化再叠加"原则删除, 待真正需要窗口长指针时再按 ABI 分支补 `SetWindowLongPtrA`（写法可对照 win32_api_luajit `winapi_window.lua:391-405`）。

### 3.4 窗口类注册: struct 与 API 不匹配（`[必崩]` 已修）

两个独立错误叠在一起:

- **struct 布局**: 原 struct 名为 `WNDCLASSW` 但带首字段 `cbSize`, 那是 `WNDCLASSEX` 的布局。`RegisterClass` 期待无 `cbSize` 的 10 字段版本, 传入后每个字段偏移一位, `lpfnWndProc` 会读到 `style` 的值, 首次注册即损坏窗口过程指针。
- **A/W 混用**: `RegisterClassW` 按 UTF-16 解析 `lpszClassName`, 但代码传的是 ANSI 字面量 `"XComSerialLua"`, 且 cdef 里该字段声明为 `LPCSTR`。注册出来的类名是乱码, 随后 `CreateWindowExA` 按 ANSI 名查找必然失败, `init_window` 走进 `not self.hwnd` 分支返回 false。

修法: 统一到 **A 侧**, 因为 UI 层全部入口已是 `*A`（`CreateWindowExA`/`SetWindowTextA`/`TextOutA`）, 改 A 侧是最小改动。struct 去掉 `cbSize` 并更名 `WNDCLASSA`（`ui/win32.lua:290-302`）, API 改 `RegisterClassA`/`UnregisterClassA`/`DefWindowProcA`（`:399-401`）, 调用点同步（`ui/window.lua:122`、`:142`、`:262`）。

这与 4 节的 `*W` 迁移方向相反, 取舍见 4 节说明。

### 3.5 JIT 陷阱（`[必崩][可测]` 已修）

FFI 回调无法从 JIT 编译过的代码所调用的 C 函数中安全触发, 消息循环正是该场景: `DispatchMessageW` 会回调进 `WndProc`。修法是对消息循环函数整体关闭 JIT, 见 `ui/window.lua:685` 的 `jit.off(run_message_loop)`。

### 3.6 缺失的常量表字段（`[必崩][可测]` 已修）

`ui/receive_view.lua:92` 读 `w.em.EM_GETTEXTLENGTH` 查询文档长度, 但 `ui/win32.lua` 的 `M.em` 未定义该字段, 取到 nil 后作为 message 参数传进 `SendMessageA`, 长度查询静默返回错值, 进而使 3.4 之后的着色偏移与裁剪预算全部失准。

RichEdit 没有专用的 `EM_GETTEXTLENGTH`, 长度用通用的 `WM_GETTEXTLENGTH`（`0x000E`）查询。已补进 `M.em` 并注明出处（`ui/win32.lua:171-175`）。

这类"表字段取到 nil"的缺陷与 3.1 的"全局取到 nil"同源, 但 GGET 扫描抓不到, 因此扩展了检查手段, 见 6.1 节。

## 4. 现有 v0.1 设计文件: 需要落盘的修订点（待确认）

合并到 v0.1 后成为 v0.2 的可实施基线, 截至 2026-09-01 落地状态:

| 项 | 状态 | 落地说明 |
| --- | --- | --- |
| 线程模型 | 已实施(B) | `xcom_open_async` + `xcom_take_open_result` 已加进 `xcom.h`/`xcom_abi.cpp`/`xcom_ffi.lua`, 标注待 Windows 编译验证 |
| `core/xcom_ffi.lua` 职责 | 已实施(B) | 新增 `open_async` / `take_open_result` 封套 + cdef |
| 接收视图 ANSI 背景色 | 已实施(A) | `CHARFORMAT2A`(加 `crBackColor`), `color_range` 增加 bg 参数 |
| `ui/win32.lua` 全 `*A` 入口 | 暂缓(C3) | 仅止血到 A 侧一致; 全量 `*W` 迁移推迟, 用户 2026-09-01 确认 |
| 无文件对话框 | 已实施(C2) | `OPENFILENAMEW` + `GetSaveFileNameW` + `utf8_to_utf16`/`utf16_to_utf8` helper + `Window:_save_file_dialog` |
| 标题栏按钮点击 | 已修复(C1) | 实际早已实现; 仅修掉 `SW_MINIMIZE` 缺常量导致的死代码 `SW_HIDE==0 and 6 or 6` |

## 5. C ABI 层的取舍（方案实质性变更）

### 5.1 `xcom_send` 不需要异步

`xcom.h:212-221` 注明 `xcom_send` 是 SYNCHRONOUS-COPY 语义: DLL 把 `data[0:size]` 复制进 TxBlockPool 后即返回, 不阻塞等待 WriteResult, 结果经 `xcom_get_snapshot` / `xcom_take_error` 异步回报。发送路径无需改动。

### 5.2 llthreads 救不了阻塞

`lua-llthreads` 每线程独立 `lua_State`, 数据仅参数入 / `join()` 返回出, 运行中无通道。`src/thread.nobj.lua:345-355` 明确拒绝 function/userdata/thread 类型, FFI cdata 属 userdata 类, 因此**串口句柄传不回 UI 线程**。README 建议自行引入 ZeroMQ 或 LuaSocket 做线程间通信, 那是再多两个原生依赖。结论: 编译不是瓶颈, 设计上就表达不了"worker 开口、UI 用口"。

### 5.3 在 `xcom_core.dll` 加异步 open（推荐）

你已维护 `CMakeLists.txt` 与 `CMakePresets.json`, MSVC 工具链在手, `xcom_core.dll` 本就是自编产物, 所以改 C ABI 的成本远低于引入第三方线程库。

`xcom.h:11-15` 已声明设计意图: 只有一个调用线程, 且"No exported function blocks the caller thread waiting on a Win32 HANDLE"。而 `:203-207` 的 `xcom_open` 是唯一例外, 注明阻塞至多约 2 秒。建议补齐这个例外:

- `xcom_open_async(XcomHandle, const XcomPortConfig*)`: 立即返回, 内部走已有的 coact Dispatcher 排队 open。
- `xcom_take_open_result(XcomHandle, XcomOpenResult*)`: 与 `xcom_take_error` 同构的轮询接口, 回报 open 完成或失败。

UI 侧复用现成的 10ms 显示轮询定时器驱动, 无需新增线程, 也不触碰 LuaJIT 跨线程回调。此举可删掉 v0.1 "接受 2s 冻结"的妥协。`xcom_close` 同理可加异步变体, 优先级低于 open。

备选方案（不改 C ABI）: 阻塞期间禁用按钮并显示进度提示, 让冻结被告知而非被消除。`xcom_open` 是单次不可分割调用, 无法用 coroutine 分片, 所以只能改善观感。

## 6. 验证与回归

### 6.1 新增 lint: `tests/lint_fields.lua`

原有静态检查（`luajit -bl` + require 探测）漏掉了 3.1、3.2、3.6 三类共 6 处必崩缺陷, 因为它们都是**合法语法下的 nil 读取**。新增 `tests/lint_fields.lua`, 在 Linux 上直跑, 覆盖两类:

- **未定义全局读**: 对每个文件跑 `luajit -bl`, 提取字节码的 `GGET` 指令, 减去内置名白名单。`local function f` 在定义行之前被引用时会编译成全局读, 正是 3.1 的形态。白名单须含 `debug`, 因 `core/xcom_ffi.lua` 用 `debug.getinfo` 定位脚本目录。
- **缺失常量表字段**: `require` 进 `ui/win32.lua` 后按 `w.<table>.<FIELD>` 模式正则扫全部源码, 逐个核对该字段在模块里是否存在。这抓的是 3.6, GGET 扫描对此无能为力, 因为 `w.em` 本身是有定义的。

`ui/win32.lua` 把 `ffi.load` 推迟到 `M.load()` 内, 所以模块能在 Linux 上 require 并内省常量表, 无需 Windows 运行时。

第二类检查还有"单层 `w.<name>` 模块字段"变体: 对每个 `w.<标识符>` 引用, 若其后不是 `.`（即非 `w.<表>.<字段>` 双层访问）, 则 `<标识符>` 必须作为 `M.<name> =` 或 `function M.<name>` 出现在 `ui/win32.lua` 里。这抓的是 `w.utf16_to_ut8` 这类模块直接字段的手误, 双层常量表检查覆盖不到。

lint 自身经过反向验证: 向 `ui/status_bar.lua` 注入一个假全局与一个不存在的 `w.em` 字段, 两者都被报出且退出码为 1; 向 `ui/window.lua` 注入 `w.utf16_to_ut8` 单层 typo 也被报出; 还原后重新 clean。避免出现"扫描器静默通过"的假绿。

当前状态: lint clean（12 文件）, 4 个单测全绿（143 断言）。

### 6.2 C ABI 单测（5.3 节已实施, 待 Windows 编译）

`xcom_open_async` / `xcom_take_open_result` 已写进 `xcom.h` 与 `xcom_abi.cpp`, 但本机无 MSVC/MinGW, **未编译、未跑 RED 单测**, 违反 TDD 铁律的例外已与用户确认。Windows 上补一个 host 单测（仿 `tests/session_churn_test.cpp`, 用 `VIRTUAL` 端口）:

1. `xcom_open_async` 返回 `XCOM_OK` → `xcom_take_open_result` 轮询到 `XCOM_OK`（open 完成）。
2. 未 open 直接 `xcom_take_open_result` → `XCOM_ERR_BUSY` 或其它非 OK。
3. 同步 `xcom_open` 行为与 v1.2 完全一致（回归）。

### 6.3 Windows 联调

`docs/windows-handoff.md` 的 4.1 至 4.5 各项保留。新增待验项: 标题栏 min/max/close 点击（C1）、文件保存对话框（C2, `GetSaveFileNameW` 路径含中文）、`CHARFORMAT2A` 背景色着色（A）、`xcom_open_async` 异步 open（B）。

## 7. 下一步（更新后）

1. ~~实施 3.1、3.2、3.5~~（已完成, 见 3 节）。
2. ~~实施 3.3、3.4~~（已完成）。
3. ~~5.3 改 C ABI~~（已写代码, 待 Windows 编译 + host 单测）。
4. C3 `*W` 全量迁移: 用户确认暂缓, 中文乱码作为已知非阻塞缺陷保留。
