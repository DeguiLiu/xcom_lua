# xcom_lua —— Windows 联调交接清单

> 日期: 2026-09-01
> 状态: Linux 侧代码已写完并静态验证;Win32 GUI/串口 FFI 需在 Windows 实跑联调

## 1. 这是什么

`xcom_lua/` 是一个 **LuaJIT + Win32 FFI(+ GDI)** 的串口调试客户端,功能对齐现有 Python 版 `xcom_client`(PySide6),复用同一个 `xcom_core.dll`(通过 `xcom.h` v1.3 C ABI 调用)。接口行为与 `xcom_client` 尽量一致,但不引入 wxWidgets/LuaDui/DuiLib 等库本体(仅参考写法)。

设计文档见 `docs/design.md`(已冻结)、`docs/design-revision-v0.2.md`(评审/缺陷清单)。

## 2. 目录

```
xcom_lua/
  main.lua                 入口:package.path 设置 + 配置加载 + 窗口构造 + 消息循环
  core/
    config.lua             INI(key=value)持久化(纯 Lua,已单测)
    ansi.lua               ANSI/SGR 流式解析器 + 浅色 palette(纯 Lua,已单测)
    xcom_ffi.lua           xcom.h v1.3 的 ffi.cdef 镜像 + xcom_core.dll 加载/封套
                            (含 HEX 编解码 / build_send_payload / 异步 open,已单测)
  ui/
    win32.lua              Win32 API/GDI/公共控件/RICHEDIT 的 cdef + 颜色/常量
                            (含 CHARFORMAT2A/OPENFILENAMEW/UTF-8↔UTF-16 helper)
    controls.lua           控件工厂(Button/Combo/Edit/CheckBox/RichEdit + ID 分配)
    window.lua             主窗口:无边框标题栏、WndProc 分发、定时轮询、消息循环
    connection_panel.lua   连接参数面板(右侧)
    receive_view.lua       接收视图(RICHEDIT + ANSI 分段着色 fg/bg + FIFO 裁剪)
    send_panel.lua         发送面板(单发 + 多发,2 个实用 tab)
    status_bar.lua         状态栏(端口状态 / RX TX / drops / 时钟)
  tests/                   config 32 + ansi 30 + xcom_ffi 37 + view_model 44 = 143 断言
                            + lint_fields.lua 静态检查(luajit 直跑)
  docs/design.md           设计文档
  docs/design-revision-v0.2.md  评审: 六参考库调研 + 缺陷清单 + A/B/C 落地状态
```

## 3. Linux 侧已完成并验证的部分

| 项 | 状态 |
| --- | --- |
| `config.lua` 纯 Lua 逻辑 | ✅ 32 断言通过 |
| `ansi.lua` 纯 Lua 解析逻辑 | ✅ 30 断言通过(含跨批残留、颜色映射、背景色) |
| `xcom_ffi.lua` HEX 编解码 + `build_send_payload` + 异步 open 封套 + 结构体布局核验 | ✅ 37 断言通过 |
| `view_model.lua` HSM 互锁 | ✅ 44 断言通过 |
| 全部 12 个 lua 文件 | ✅ `luajit -bl` 语法编译通过;10 个模块 `pcall(require)` 可达 |
| `tests/lint_fields.lua` 静态检查(未定义全局/常量表字段缺失/拼写) | ✅ clean(12 文件) |
| `main.lua` 入口 | ✅ 在非 Windows 上打印 "requires a Windows host" 并 exit 2(符合预期) |

Linux 验证命令:
```bash
cd xcom_lua
/home/dgliu/.local/openresty/luajit/bin/luajit tests/test_config.lua
/home/dgliu/.local/openresty/luajit/bin/luajit tests/test_ansi.lua
/home/dgliu/.local/openresty/luajit/bin/luajit tests/test_xcom_ffi.lua
/home/dgliu/.local/openresty/luajit/bin/luajit main.lua   # 应报 Windows 提示
```

## 4. 必须在 Windows 上核验/联调的部分(设计 §8)

以下模块含真正的 Win32/FFI 调用,**无法在本 Linux 环境运行**,只能靠 Windows 实跑 + 手工 review。按风险从高到低:

### 4.1 Win32 FFI cdef 的正确性(最高风险)
`ui/win32.lua` 的 `ffi.cdef` 声明了许多 Win32 API。若某签名与 `user32.dll`/`gdi32.dll` 实际导出不一致,调用会 **LuaJIT crash 进程**。当前在 Linux 仅验证了"C 声明自洽"(require 不报),**没有运行时校验**。建议逐个 smoke:先跑一个最小窗口(`RegisterClassW` → `CreateWindowExA` → 消息循环)确认 `WndProc`/`WM_*` 常量/zOrder/COLORREF 全部正确。

已知需重点核对:
- `RegisterClassW(WNDCLASSW*)` 与 `CreateWindowExA(...)` 尾参 `LPVOID` 对齐;`wc.lpszClassName` 类型。
- **x64 位宽**:`WPARAM`/`LPARAM` 已设为 `intptr_t`,`SendMessageA`/`DefWindowProcW` 已设为返回 `intptr_t`(避免截断)。**联调时如仍有 crash,优先怀疑其它 API 的签名与 64 位实际导出不一致**,尤其是回调(如 `EnumWindowsProc`)与需要传指针的 `lParam`。
- RICHEDIT `EM_SETCHARFORMAT`(`WM_USER+68 = 0x444`)与 `CHARFORMAT` 布局(见 §4.3)。

### 4.2 xcom_core.dll 加载路径
`core/xcom_ffi.lua:find_dll` 默认找 `<script>/../build/native-release/bin/xcom_core.dll`,可用环境变量 `XCOM_CORE_DLL` 覆盖。Windows 上把 `xcom_core.dll` 放到脚本同层或设 `XCOM_CORE_DLL` 指向 release 产物后联调。

### 4.3 RICHEDIT ANSI 着色(高复杂度)
`receive_view.lua` 用 `EM_SETCHARFORMAT` + `SCF_SELECTION` 对刚插入的段逐段设前景色与背景色。**背景色已实现**(用 `CHARFORMAT2A` 的 `crBackColor` + `CFM_BACKCOLOR`,见 `ui/win32.lua` 的 `CHARFORMAT2A` cdef;`CHARFORMAT` 无该字段故改 `CHARFORMAT2A`)。`view._doc_len` 用 UTF-8 字节计数作为 RICHEDIT 字符偏移,对纯 ASCII 是精确的,对多字节 UTF-8 字符会**偏移不准**(RICHEDIT 按 UTF-16 码元计数)。列在这里:联调时重点测试含中文的日志段下颜色是否错位。

### 4.4 无边框窗口的拖动/resize
`on_nchittest` 返回 `HTCAPTION`/`HTLEFT..` 让系统处理拖动与尺寸;`WM_PAINT` 自绘标题栏 + 最小/最大/关闭三个按钮。**点击处理已接上**(C1):`on_lbuttonup`/`_header_button_at`/`_toggle_maximize` 命中后分别发 `SC_MINIMIZE`/`SC_MAXIMIZE`/`SC_CLOSE`。仍待联调的是**按钮视觉/状态**:自绘矩形按钮无 hover/按下态,最大化图标字形固定(用 `self._maximized` 跟踪状态,见 `window.lua`)。

### 4.5 单线程 UI 阻塞(已加异步 open,待编译联调)
`xcom_open`/`xcom_close` 在消息循环线程直接调用会阻塞 UI。**v1.3 已提供 `xcom_open_async`/`xcom_take_open_result`**(`xcom.h`/`xcom_abi.cpp` 已实现,`core/xcom_ffi.lua` 已加封套),旨在把 ~2s 打开操作移到 coact Dispatcher 排队、UI 线程轮询完成。**但 `ui/window.lua` 尚未切换到 async 路径**(`window.lua:466` 仍同步 `xcom.open`)。需在 Windows 编译 `xcom_core.dll`(v1.3,本机无 MSVC 未编译)后,决定是否切 async 并复测单线程不冻结。

## 5. Windows 上如何跑

1. 准备运行时:
   - LuaJIT:用 `openresty-1.29.2.1-win64` 里的 `luajit.exe` + `lua51.dll`(同目录)。
   - 核心 DLL:`build/native-release/bin/xcom_core.dll`(放到脚本同层或设 `XCOM_CORE_DLL`)。注意 ABI 已升 **v1.3**,需用最新 `xcom.h`/`xcom_abi.cpp` 重新编译(含 `xcom_open_async`/`xcom_take_open_result`)。
2. 运行:
   ```bat
   openresty-1.29.2.1-win64\luajit.exe xcom_lua\main.lua
   ```
   或在 `xcom_lua` 目录下 `..\openresty-1.29.2.1-win64\luajit.exe main.lua`。
   首次运行需改 `core/xcom_ffi.lua` 的 DLL 路径或设环境变量 `XCOM_CORE_DLL`。

### 5.1 Windows 实机联调记录(2026-09-01,已实跑)

本机经核实是 Windows 10 x64(MSYS2/Git Bash shell),并具备完整**MSVC 14.44 + Ninja 1.13 + Windows SDK 10.0.22621** 工具链(此前几轮误判为"本机无 MSVC")。据此完成了首次真实编译与窗口实跑,发现并修复了 Linux 静态检查(143 断言全绿)完全覆盖不到的 **Windows 运行时缺陷**。

**编译 xcom_core.dll(v1.3):**
- 装 Windows 原生 cmake 4.4.3 + ninja 1.13.2(`python -m pip install cmake ninja`),避开 MSYS2 cmake 输出 POSIX 路径导致 MSVC 编译器 ABI 探测失败的问题。
- 新增 `build.cmd`(根目录):`vcvars64.bat` 设 MSVC/SDK 环境 → `cmake --preset native-release` → `cmake --build`。产物在 `build/native-release/bin/xcom_core.dll`。
- 修复 C++ 编译错误:`xcom_abi.cpp` 里 `queue_open` 定义在全局作用域(非 `namespace xcom`),却被 `xcom::queue_open(...)` 限定名调用(第 211/249 行),改为非限定名;`port_state_2_status` 同理(第 222/274 行)。
- 新增 `tests/async_open_test.cpp`(VIRTUAL 端口)验证 v1.3 async open,并接入 `xcom_core/CMakeLists.txt`。

**host 测试全部通过(Windows 实跑):**
- `xcom_async_open_test.exe` PASS:未 open 直接 `take_open_result` 返回 `-6`(err_io,非 OK);async open 排队→轮询到 OPEN→close 成功;同步 `xcom_open` 回归一致。
- `xcom_session_churn_test.exe` PASS(句柄无泄漏)。`xcom_smoke_test.exe` PASS(64 断言全绿)。

**Lua 侧窗口实跑(luajit.exe main.lua):**
- 把 `openresty-1.29.2.1-win64/luajit.exe` + `lua51.dll` 复制到 `xcom_lua/`(同目录,Windows 加载器按 exe 目录找 lua51.dll)。使用 `run_xcom_lua.cmd`。
- 逐项修复 7 类 Windows 运行时必崩缺陷(均 Linux 单测未覆盖):

| # | 缺陷 | 修复 |
| --- | --- | --- |
| 1 | `WndProc` FFI 回调内 Lua 错误逃逸成 `0xC000041D` 崩溃,无诊断 | `dispatch` 包 `pcall`,错误打印 `[wndproc] error msg=0x...` 并返回 0 |
| 2 | `GetModuleHandleA` 误归 `w.user32`(实为 kernel32) | `window.lua:104`、`controls.lua:44` 改 `w.kernel32.GetModuleHandleA` |
| 3 | `controls.combo` 工厂多传 `opts` 作第 10 参,`id` 变成 table → `ffi.cast("void*")` 崩 | `combo` 删多余 `opts` 参数,让 `id` 走 `alloc_id()` |
| 4 | `on_size` 对 cdata `lparam` 做 `math.floor` 报 `bad argument #1 (cdata)` | `local lp = tonumber(lparam)` 后按整数拆 LOWORD/HIWORD |
| 5 | `combo_count`/`combo_cur`/`CB_GETLBTEXTLEN` 返回的 cdata 直接进 `for` limit/`ffi.new` 尺寸报错 | 统一 `tonumber(... or 0)` |
| 6 | `FillRect` 误归 `w.gdi32`(实为 user32) | `window.lua` on_paint 4 处改 `w.user32.FillRect` |
| 7 | `WM_CTLCOLOR*` 返回 `ffi.cast("long", HBRUSH)`,x64 截断 8 字节指针 | 改 `ffi.cast("intptr_t", ...)` |

**当前状态:** `xcom_core.dll`(v1.3,含 async open)编译成功;`xcom_async_open_test` 等 4 个 host 测试全绿;`luajit.exe main.lua` 成功创建窗口并稳定进入消息循环,WM_PAINT 自绘无 `[wndproc] error` 残留。

**Win32 符号→DLL 陷阱速查(subagent 研究 ref/win32_api_luajit 输出):** `GetDC`/`ReleaseDC`/`FillRect`/`DrawTextA`/`GetSysColorBrush`/`InvalidateRect`/`SetTimer` 均属 **user32**(非 gdi32);`GetModuleHandle*`/`MultiByteToWideChar`/`MulDiv` 属 **kernel32**;`CreateSolidBrush`/`TextOutA`/`GetStockObject`/`SetTextColor`/`GetTextMetrics*` 属 **gdi32**;`GetSaveFileNameW` 属 **comdlg32**。

**尚未验证(仍需 Windows 交互):** 黄金路径"打开 COM→收/发→关闭"、async open 的 UI 免冻结体验、RICHEDIT 中文着色偏移、标题栏按钮视觉态、文件保存对话框(含中文路径)。这些已无编译/崩溃阻塞,剩 UI 交互验收。

## 6. 联调优先级建议

1. **先把 §4.1 的 `WPARAM/LPARAM/SendMessage` 改成 64 位类型**,再跑最小窗口 smoke——不解决这个,后续一切联调都会 crash 在前几个 API 调用上。
2. 跑通"窗口显示 → 端口枚举(刷新)→ 打开 COM → 收/发 → 关闭 → 退出"黄金路径。
3. 再逐项验证:ANSI 着色(§4.3)、标题栏按钮(§4.4)、保存日志、多头页面分页、配置读写。
4. 全部通过后回来更新本文档并把"已完成"项勾格。

## 7. 与 Python 版的行为差异(有意简化,文档承诺)

| 项 | 差异 |
| --- | --- |
| 主题 | 仅浅色(西门子 palette),无深色切换 |
| 窗口 | 无边框自绘标题栏;最小/最大/关闭点击已接(C1),但按钮视觉/hover 态待补齐(§4.4) |
| 发送 tab | 仅"Single" + "Multi" 两个实用 tab(协议/帮助为占位),用两个按钮切换而非系统 Tab 控件 |
| ANSI 背景色 | 已实现(`CHARFORMAT2A` 的 `crBackColor`),待 Windows 联调 |
| 保存 | 手动保存"Save..." 走 `GetSaveFileNameW` 文件对话框(C2),路径含中文待 Windows 联调 |
| 配置 | `config.ini`(非 TOML),字段语义对齐 |
