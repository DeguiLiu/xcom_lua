# xcom_lua 项目工作总结

> 日期: 2026-09-01
> 性质: 本次会话全程工作的完整复盘，供后续接续使用

## 1. 一句话结论

在 Linux 环境下完成了 `xcom_lua/` ——一个用 **LuaJIT + Win32 FFI(纯，无第三方 UI/串口库本体)** 实现的 Windows 串口客户端，功能对齐已写好的 Python 版 `xcom_client`(PySide6)，复用同一个 `xcom_core.dll`(经 `xcom.h` v1.3 C ABI)。UI 侧全部代码为纯 Lua(无需编译 C 扩展)，在 Linux 上完成了模块级静态验证与纯逻辑单测；为消除 open 阻塞，`xcom_core.dll` 自身新增了 `xcom_open_async`/`xcom_take_open_result`(C ABI v1.3，见 §5.5)。Win32 GUI/串口部分仍需真实 Windows 联调。

## 2. 项目全貌

目录 `/home/dgliu/SSCOM/xcom_lua/`，共 19 个文件约 4200 行纯 Lua + Markdown：

```
core/        config.lua view_model.lua xcom_ffi.lua ansi.lua   # 纯 Lua，可单测
ui/          win32.lua controls.lua window.lua
             connection_panel.lua receive_view.lua send_panel.lua status_bar.lua  # Win32 FFI
tests/       test_config.lua test_ansi.lua test_xcom_ffi.lua test_view_model.lua
main.lua     入口(固定工作目录 + package.path + host guard + 消息循环)
docs/        design.md(冻结设计) design-revision-v0.2.md(评审) windows-handoff.md(联调清单)
```

## 3. 需求澄清阶段(逐步确认的设计决策)

| 决策 | 结论 | 理由/依据 |
| --- | --- | --- |
| 核心逻辑 | **复用 xcom_core.dll**(FFI 直接 bind v1.3 ABI)，不用 librs232 重写 | 复用已验证的 coact 运行时/背压/块池/关闭协议 |
| GUI 渲染 | **纯 Win32 API + GDI**，标准通用控件 + 自绘 | 对应 xcom_client 手写无边框+自绘风格; wxLua/DuiLib 仅参考不引入 |
| 窗口 | 无边框自绘标题栏(HTCAPTION 拖动 + SC_SIZE 边 resize) | 视觉最接近原型 |
| 主题 | 浅色 + 深色(初始确认)→ **最终只做浅色，深色暂缓** | 后经用户确认 |
| 发送面板 | 4 tab 框架 → **只做 Single + Multi 两个实用 tab** | 协议/帮助为占位 |
| 线程 | **单线程**直调 ABI，open/close 阻塞 UI ~2s → **补 C ABI 异步 open 消除阻塞**(已写 `xcom_open_async`/`xcom_take_open_result`) | 避免 LuaJIT 手搓跨线程 FFI 同步风险；异步依托 coact Dispatcher 排队，不引入第三方线程库 |
| 接收视图 | **RICHEDIT** + EM_SETCHARFORMAT 按 ANSI 段设前景色(背景色用 `CHARFORMAT2A` 的 `crBackColor`) | 原生免费获得滚动/选择/复制 |
| 配置持久化 | **手写极简 INI(key=value)**，文件 `config.ini` | 无第三方依赖，字段对齐 Python config.toml 语义 |
| ANSI | 支持 SGR 颜色解析(前景+背景+粗体) + 跨批残留 | 行为对齐 Python ansi.py |
| 编程环境 | Linux 先写全部代码 + 逻辑单测，Win32 部分仅静态检查 | 用户明确要求 |

## 4. 实现阶段(模块间依赖自底向上)

1. `core/config.lua` — INI 解析/序列化/读写 + 多发条目扁平键。32 断言。
2. `core/ansi.lua` — ANSI/SGR 流式解析 + 浅色 palette。30 断言。
3. `core/xcom_ffi.lua` — xcom.h v1.3 全量 ffi.cdef 镜像 + DLL 惰性加载 + 封套(含 HEX 编解码 build_send_payload、异步打开 open_async/take_open_result)。37 断言。
4. `core/view_model.lua` — HSM 互锁(移植 Python SerialUiHsm/ViewModel)。44 断言。
5. `ui/win32.lua` — Win32/GDI/通用控件/RICHEDIT 的 cdef + 常量 + 颜色助手。
6. `ui/controls.lua` — 控件工厂(Button/Combo/Edit/CheckBox/RichEdit + id 分配)。
7. `ui/connection_panel.lua` / `receive_view.lua` / `send_panel.lua` / `status_bar.lua` — 四大面板。
8. `ui/window.lua` — 主窗口:WndProc 分发、无边框标题栏、消息循环、定时轮询、配置落盘。
9. `main.lua` — 入口:配置加载、host guard、窗口构造、进入消息循环。

## 5. 审查与缺陷修复(第二次严肃自评后,对照 Python 逐项)

第一次宣称"完成"后，用户质疑，于是对照 `xcom_client/` 源码做严格审查，发现并修复了 **约 15 个真实缺陷**，分三类：

### 5.1 行为语义偏差(对照 Python)
- `port_text` 全大写 → 改 Title Case `Closed/Opening/Open/Closing/Fault`(对齐 `XCOM_PORT_TEXT`)
- `build_send_payload` HEX 空串错误追加 CRLF → 对齐 Python 短路语义
- **补全缺失的 HSM 互锁**：Open/Close 按钮与参数控件原先从不启用/禁用 → 新建 `core/view_model.lua`
- **补全缺失的自动发送重推**：`_set_autosend_enabled` + 连接跃变 edge 重推
- **补全缺失的接收选项栏**：Receive HEX/Timestamp/Pause/Auto-clear+spin/Auto save/monitor 状态，并让 `_push_display_options` 真正调用 `xcom_set_options`(原先 `core_set_options` 从未被调用)
- **补全关闭时停止自动发送**(Python `closeEvent` 语义)
- **多发自动循环计时器**(Stop hook 追加)：`on_chk_multi_auto_toggled`/`on_edit_multi_period_changed`，Win32 定时器 id 3
- **标题栏按钮点击**(Stop hook 追加)：`on_lbuttonup`/`_header_button_at`/`_toggle_maximize`，并修正 on_paint 绘制坐标(120px)与 on_nchittest 拖动排除区(原仅 40px)的不一致
- **配置持久化写回**(Stop hook 追加)：`_save_config` 在 on_close 落盘窗口几何/串口参数/显示选项，此前配置只 `load` 从不 `save`

### 5.2 LuaJIT 运行时必崩点(静态语法检查测不出)
- `ansi.lua` `parse_params` 用 `gmatch("[^;]*")` 产生尾部空串，导致 SGR `0` 立即重置颜色
- `//` 整数除法误用(LuaJIT 基于 Lua 5.1，不支持)→ 改 `math.floor`
- **7 处局部函数/变量前向引用**(create_class、stop_text/parity_text/flow_text、stop_index/parity_index/flow_index、`local xcom = require`、controls 的 vmerge、status_bar 的 width)——核心教训: **Lua 的 upvalue 是词法位置静态绑定，不是运行时按名解析**，`luajit -bl` 无法暴露这类"名字在定义前使用"的错误
- 消息循环缺 `jit.off`(LuaJIT 限制: FFI 回调不能从 JIT 编译路径调用)

### 5.3 Win64 FFI 位宽与结构体错位(Windows 首次运行即崩)
- `WPARAM` 应 `uintptr_t`(无符号)/`LPARAM` 应 `intptr_t`(有符号)，`SendMessageA`/`DefWindowProcW`/`WNDPROC` 返回应 `intptr_t`(对照 `ref/win32_api_luajit-master/winapi_winusertypes.lua` 验证过的声明)
- **`WNDCLASSW` 结构体字段错位**：原先多带一个 `cbSize`(实为 WNDCLASSEXW 布局)，传给 `RegisterClassW` 会整体偏移 4 字节导致 `lpfnWndProc` 读脏值——最终统一改 `WNDCLASSA`+`RegisterClassA`+`DefWindowProcA` 全 ANSI 对齐

### 5.4 参考库调研结论(六个库均不集成)
`win32lualib`(C 扩展 x86/Lua5.3)、`win32exts`(x86 闭源)、`lua-llthreads`(cdata 无法跨线程)、`wxlua`(仅借 id 分配模式)、`winapi`(C 扩展需编译)、`win32_api_luajit`(纯 FFI，硬断言 32 位、无 LICENSE)——仅作 cdef/模式参考。

### 5.5 架构提案(design-revision-v0.2.md §5.3，部分落地)
提出给 xcom_core.dll 加 `xcom_open_async`/`xcom_take_open_result` 以消除"open 阻塞 2s"妥协。

**落地状态(截至 2026-09-01，均已核过代码)**
- ✅ `xcom.h` 升 v1.3.0，声明 `xcom_open_async` / `xcom_take_open_result`。
- ✅ `xcom_core/src/abi/xcom_abi.cpp` 真实现：提取 `queue_open` helper，`xcom_open_async` 返回后走 coact Dispatcher 排队 open，`xcom_take_open_result` 非阻塞回报；同步 `xcom_open` 改为复用同一 `queue_open` 保持 byte-for-byte 兼容。**注意：本机无 MSVC，未编译、未跑 RED 单测**(见 §7.3)。
- ✅ `core/xcom_ffi.lua` 注配置 + 封套 `open_async`/`take_open_result`。
- ⚠️ **`ui/window.lua` 未切换到 async 路径**：`window.lua:466` 仍调用同步 `xcom.open(...)`，靠 `vm.on_show_error` 等 HSM 互锁挡重复点击，UI 线程在 open 期间仍会阻塞 ~2s。需 Windows 联调时决定是否切 `open_async` + 用显示轮询定时器驱动 `take_open_result`(design-revision-v0.2.md §6.3 列为待验项)。

此差异需 Windows 联调时决策。

### 5.6 新增 lint 静态检查(`tests/lint_fields.lua`)
原有 `luajit -bl` + require 探测抓不到 3.1/3.2/3.6 这类「合法语法下的 nil 读取」。新增 `tests/lint_fields.lua`(Linux 可直跑)，覆盖两类：
- **未定义全局读(GGET)**：跑 `luajit -bl` 提取 GGET 指令减去内置名白名单，抓「`local function f` 定义前被引用」形态(design-revision-v0.2.md §3.1)。
- **缺失常量表字段**：require 进 `ui/win32.lua` 后正则扫描 `w.<表>.<字段>` 与 `w.<单层字段>`，逐字段核对是否存在(§3.6)。lint 自身做了反向自测(注入假字段能报出)，当前 clean(12 文件)。

## 6. 当前验证状态(诚实评估)

**已验证(在 Linux)**
- 12 个 Lua 文件 `luajit -bl` 语法编译通过，10 个模块 `require` 可达
- 四套纯 Lua 单测全绿: config 32 + ansi 30 + xcom_ffi 37 + view_model 44 = **143 断言**
- 新增 `tests/lint_fields.lua` 静态检查(见 §5.6)：抓「未定义全局读(GGET)」+「`w.<表>.<字段>` 缺失」+「`w.<单层字段>` 拼写」三类 nil 读取，clean 通过(12 文件)
- 六个 FFI 结构体 `ffi.sizeof` 与 Python ctypes `SIZEOF_*` 逐字段一致(CreateOptions=8/PortConfig=32/DisplayOptions=16/Snapshot=52/Error=268/PortInfo=324)
- `main.lua` 在非 Windows 正确打印 host guard 并 exit 2
- `CHARFORMAT2A`(含 `crBackColor`)、`OPENFILENAMEW`/`GetSaveFileNameW` 等 cdef 布局已在 `ui/win32.lua` 声明并 size 核对，`WNDCLASSA`/`RegisterClassA` 全 A 侧对齐

**未验证(必须 Windows)**
- Win32 GUI 真实运行时(消息循环、控件创建、RICHEDIT ANSI 着色、按钮响应)
- `xcom_open`/`xcom_close` 的实际阻塞语义与 FFI cdef 运行时匹配
- RICHEDIT `_doc_len` 对多字节 UTF-8 的字符偏移正确性(现按字节计数，UTF-8 非纯 ASCII 会错位)
- 异步 open 接口(见 §5.5)：`xcom_open_async`/`xcom_take_open_result` 的 C++ 实现尚未编译(本机无 MSVC)，`window.lua` 尚未切换 async 路径

## 7. 遗留与下一步

1. **真实 Windows 联调**：`luajit.exe main.lua`(运行时用 `openresty-1.29.2.1-win64` 的 `luajit.exe`+`lua51.dll`，`xcom_core.dll` 设 `XCOM_CORE_DLL` 或放脚本同层)，按 `docs/windows-handoff.md` 的清单逐项验证。
2. **RICHEDIT 多字节偏移修正**：接收中文日志时 ANSI 着色会错位，需改按 WCHAR/UTF-16 码元计数或引入 `CHARFORMAT2W`。
3. **C++ 编译 + host 单测(异步 open)**：在 Windows + MSVC 编译 `xcom_core.dll`(v1.3)，补 host 单测仿 `tests/session_churn_test.cpp`(VIRTUAL 端口)：`xcom_open_async` 返回 OK→`xcom_take_open_result` 轮询到 OK；未 open 直接取结果返回非 OK；同步 `xcom_open` 行为与 v1.2 一致(回归)。编译通过后再把 `window.lua` 切 async 并复测单线程不冻结。
4. **标题栏按钮视觉/状态**：当前自绘矩形按钮无 hover/按下态，最大化图标不随状态切换(已用 `self._maximized` 跟踪，但图标字形固定)。
