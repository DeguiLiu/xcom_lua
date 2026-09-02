# 最近八轮对话开发总结

更新时间：2026-09-03

本文按最近八轮对话的主题归纳开发结果，重点记录目标、实现位置、验证情况和当前边界。它是开发交接文档，不替代具体模块设计文档。此前轮次（窗口启动、多发送、ImGui 迁移初版、Siemens 视觉调整、桥接层与 Lua 结构化重构等）见 git 历史 `029b4d8`、`2ddd857`。

## 1. 串口功能补全（对照 PySide6 版差距盘点）

经子代理对照 `xcom_client` 盘点功能差距后，按优先级补齐：

- 错误环消费：`Window:_poll_errors()` 在 250 ms 状态轮询中弹出 `xcom_take_error`，`E<code>: <message>` 显示到状态栏第 4 槽（实测 COM99 打开失败可弹出 "Win32 serial open failed"）。
- 两阶段关闭 drain：`on_close` 重排为 停定时器 → `_final_drain()`（64 KiB/轮 × 500 轮硬上限）→ 存配置 → 日志 flush/close → 关串口 → 销毁窗口，退出不再丢尾部数据。
- 窗口置顶生效：`always_on_top` 配置经 `SetWindowPos(HWND_TOPMOST)` 真正应用（此前只存不用）。
- Alt+0..7 快捷发送：`WM_SYSKEYDOWN` 分支（含小键盘），imgui 与原生面板两路。
- 日志错误反馈与重试：`_log_close_with_retry()`（500 ms × 4 次有界重试）、三处 `log_open` 检查返回码并回退 UI 勾选、`STATUS_TEXT` 状态码映射；修正"ABI 状态码是 cdata、`not rc` 把 0 误判为真"的隐蔽 bug（全部改为 `tonumber(rc) == xcom.ok`）。

相关代码：`xcom_lua/ui/window.lua`、`xcom_lua/ui/win32.lua`（补 SWP/HWND 常量）。

## 2. "bad callback" PANIC 崩溃排查与修复

症状：客户端启动后 6-18 秒 `PANIC: unprotected error in call to Lua API (bad callback)`，HEAD 版本同样复现（既有 bug，非当轮引入）。

排查过程：二分法（禁 `_poll_errors`、禁 display timer）、全局 `jit.off()` 对照（215 秒稳定，确认 JIT 相关）、`jit.attach` trace-abort 探测（修复后 0 abort）。

根因与修复：LuaJIT 禁止 FFI callback 从 JIT 编译代码重入；`jit.off(run_message_loop)` 只关了外层函数，回调链仍可能被追踪。修复为对所有 C→Lua 重入点显式禁用：`Window.dispatch`、`poll_display`、`poll_status`、`render_imgui`、`_send_imgui_multi` 及全部 luv timer 回调闭包 `jit.off(fn, true)`（递归子函数），回调引用保存到 `self._*_callback` 防 GC。

验证：200 秒长时运行零 PANIC。诊断中曾出现的"30 秒崩溃"经查为并发多进程日志互扰的误判。

相关代码：`xcom_lua/ui/window.lua`（各 jit.off 标注点）。

## 3. DX11 渲染后端与接收文本 ABI 下沉

渲染后端从 OpenGL 迁移到 DX11，并把每帧 64 KiB 字符串的 FFI 传递下沉到 DLL 内部：

- `xcom_imgui_bridge.cpp` 改用 `imgui_impl_dx11`：`D3D11CreateDeviceAndSwapChain`（FLIP_DISCARD 双缓冲）、`create_render_target`/`cleanup_render_target`/`release_dx_resources`、`WM_SIZE` 时 `ResizeBuffers` 重建 RTV。
- 新增 C ABI `xcom_imgui_set_receive_text(text, length)`：接收文本存 DLL 内 `receive_text_`，Lua 侧 `render_imgui` 仅在 dirty 时推送一次，`xcom_imgui_draw_console` 的 receive 参数传 `nil, 0`。
- Lua 配套：`_append_imgui_receive`（分块追加，列表预修剪 ≤64 KiB）+ `_flush_imgui_receive`（单次 `table.concat`，返回 dirty 标志）。
- 资源路径修复：`module_resource_path` 从 exe 目录改为 DLL 目录优先 + 父目录探测 + exe 回退，解决运行时包 `Could not load font file!` 断言崩溃（字体在 `<app>/assets/` 而 DLL 在 `<app>/runtime/`）。
- 新增 `xcom.exe` 启动器（`native/launcher/`，CMake WIN32 target + 图标），Explorer 双击即可启动。

## 4. C++17 与 stdint 改进

按 `MEMORY.md` 提取的编码基准二次加固桥接层：

- 样式表表驱动：28 行重复 `style.Colors[x] = rgb(...)` 收敛为 `constexpr std::array kStyleColors` + `apply_style()`。
- `[[nodiscard]]`/`noexcept`：`create_render_target`；wndproc 里 best-effort 调用用 `(void)` 显式丢弃并注释。
- `IM_ARRAYSIZE` → `std::size`；魔法数收敛为 `kReceiveFallbackHeight`/`kClearColor` constexpr。
- stdint：`DWORD owner_thread_` → `std::uint32_t`、`DWORD length` → `std::uint32_t`（API 边界必须的 Win32 类型保留）。
- 核心侧（会话早期）：log/display 池预算下调（`kFileBlockCount` 256→16、`kRxBlockCount` 1024→256、`kDisplayBatchCount` 256→64 等），`LogWriter` 改为惰性 `start`，降低启动常驻内存。

## 5. 热点函数性能优化

帧循环（16 ms）与显示轮询（10 ms）的四项优化：

- 接收区渲染 O(64 KiB)→O(可视行)：`ImGuiListClipper` 裁剪 + `receive_line_offsets_` 行偏移缓存（`set_receive_text` 时一次 O(n) 扫描），并新增尾随自动滚动（贴底跟随、上滚脱离）。
- `_flush_imgui_receive` 双拷贝→单分配：chunk 列表已预修剪，去掉二次 `..`/`:sub`；单 chunk 时零拷贝。
- `controls.lua set_text` 等值短路：`ctl._last_text == text` 跳过 `SetWindowTextA`（已审计全部调用点均只读 status label，缓存安全）。
- `poll_status` 变化检测：port_state / RX/TX / drops 三组统计值未变时跳过 `string.format` 分配。

验证：90 秒实机零 PANIC，截图确认空状态文案、头部装饰线、侧栏渲染无回归。

## 6. LuaJIT 高性能编码实践

应用社区通行实践并用基准量化：

- `core/ansi.lua`（接收热路径）逐字节 `buf:sub(i,i)`+`:byte()` → 单一 `string.byte(buf,i)`（消除每字节一次的 1 字节串分配）；CSI terminator 改返回字节码（`term == 109`），删除 `is_csi_terminator`；`parse_params`/`match_csi`/`feed` 内 `string.find/sub/match/tonumber` 全部局部化为 upvalue。
- `jit.attach` trace-abort 探测确认当前代码 0 abort（NYI 已不是瓶颈），热路径实为解释执行——局部化在解释模式同样有效。
- 基准（200 KB 混合 SGR × 20）：旧 11-12 ms → 新 9-11 ms（约 8-15% 提升）；30 条 ansi 断言全绿。
- 结论：单线程 UI-bound 串口工具瓶颈在渲染与数据链路（前几轮已优化），继续微调收益边际递减，不再投入。

## 7. C4819 根治、集成测试与提交推送

- `xcom_imgui/CMakeLists.txt` 补 `/utf-8`（xcom_core 已有、imgui 漏配）：UTF-8 注释字符在 CP936 环境触发 C4819，且尾部字节可能被误解析为续行反斜杠。修复后全量重建零警告。
- `xcom_ffi.close()` 便捷封装；`find_dll` 优先探测运行时包 DLL 再回退 build 目录（无编译环境可用）。
- 新增 Windows 集成测试 4 个：`integration_test.lua`（11 断言）、`send_help_test.lua`、`serial_integration_test.lua`（注入接收路径）、`serial_external_receive_test.lua`（真实串口外部收包），README 补充用法。
- `.gitignore` 补根目录运行时垃圾（`xcom_diag.log`、`ui_current.png`）。
- 全部工作已提交并推送 Gitee：`51505f1`（DX11+崩溃修复+性能）、`ac6bc2a`（发送失败反馈）、`0ee4377`（DLL 查找顺序）、`c0dbf23`（C4819+集成测试）、`5fb4dc0`（清理误提交截图）。

## 8. 内存优化专项（90 MB → 23 MB）与按需帧率

目标：常驻内存 ≤55 MB（远期 30 MB）。实测从 ~90 MB 降到 **23.3 MB private / 43 MB Working Set**，空闲 CPU 从 73% 降到 10%。核心手段与验证详见 `MEMORY.md`"性能原则"一节，此处记决策过程：

- **测量驱动**：分层基线测量定位大头——纯 LuaJIT spin 7 MB；`require("luv")` 主动运行 +54 MB（但主程序从不进入，实为误报）；Intel HARDWARE DX11 UMD ~65 MB（真正大头）；固定池仅 2.3 MB。
- **核心池预算按波特率定容**（`xcom_config.hpp`）：`kRxBlockCount` 256→128、`kDisplayBatchCount` 64→32（各 1 MiB→512 KiB），921600 波特下余量仍为秒级；容量必须 2 的幂（SpscRing 掩码）。
- **去 luv 实验**：完整改 SetTimer/WM_TIMER 后实测仅省 ~1 MB（早前"54 MB"结论是纯 spin 探针误导），因架构回归风险（WM_TIMER 消息合并延迟、Sleep(1) 实际 15-16 ms 粒度）**全部恢复 luv**（`bbf9bf6`），仅保留 launcher 隐藏控制台（`STARTF_USESHOWWINDOW|SW_HIDE`，顺带解决黑色控制台窗口问题）。
- **DX11 → WARP + 单缓冲**（`xcom_imgui_bridge.cpp`）：`D3D_DRIVER_TYPE_HARDWARE→WARP`、`BufferCount 2→1`、`FLIP_DISCARD→DISCARD`、`PREVENT_INTERNAL_THREADING_OPTIMIZATIONS`。一个改动省 ~65 MB；代价是每帧 45-60 ms CPU，故配合下一条。
- **按需分级帧率**（`window.lua`）：交互 16 ms / 数据到达 100 ms / 空闲心跳 500 ms / 最小化跳帧 + 跳过 0x0 布局更新；`request_frame(interval)` 拉早下一帧；高频系统消息（NCHITTEST/PAINT/TIMER）不触发否则节流失效；`poll_display`/`poll_status` 仅在数据实际变化时请帧。
- **字体 atlas 裁剪实验回退**：OversampleH=1 + Latin/ASCII 字符集 + 缩字号实测只省 <1 MB，视觉损失明显，已回退原版并清理实验残留死代码。
- **测量陷阱**（记入 MEMORY.md）：初始化中途数据（8.6 MB 假象）不可信，稳定值需多次间隔测量；WARP 下 BitBlt 跨进程截屏全黑，用 `PrintWindow(hwnd, hdc, 2)`；空闲 CPU 用 GetProcessTimes 3 s 差分。
- 验证：集成测试 11 过 0 挂；单元测试 143 过 0 挂（config 32/ansi 30/view_model 44/xcom_ffi 37）；PrintWindow 截图像素验证 UI 完整（0% 黑屏）；鼠标交互模拟确认交互期自动回满帧率。
- 提交推送 Gitee：`585e912`（池+去luv+字体实验）、`bbf9bf6`（恢复luv）、`c90cc28`（WARP+帧率，核心成果）、`9106045`（字体资产/preview_rx/layout）。

## 当前边界与下一步

- 已知未做（P2 锦上添花）：Settings 齿轮菜单、深色主题、状态栏时钟、Protocol/Help 占位 tab、WM_QUERYENDSESSION 优雅关闭。
- 串口功能对齐度：核心能力 100%，错误反馈/关闭完整性已补齐，UI 完整度约 70%（缺设置菜单类）。
- 本机无 COM 口环境，串口测试经 COM3 实测（`serial_integration_test` 状态码全 0）；无硬件的收发回归依赖注入路径。
- WARP 渲染为软件光栅：满带宽持续接收 + 交互同时发生时帧预算可能吃紧（交互 16 ms 目标 vs 45-60 ms/帧），真机高负载场景需压测；如不达标可回退 HARDWARE（改一行 `D3D_DRIVER_TYPE_`）或降交互帧率档。
- 内存现状 23.3 MB private 已远低于 55 MB 目标；进一步压缩空间在 LuaJIT 基线（7 MB）与 xcom_core 固定池（~1 MB），边际收益小。
