# XCOM 串口工具

[English](README.md)

XCOM 是 Windows 串口调试工具：核心为原生 C++17 DLL（`xcom_core`），界面为
LuaJIT + ImGui 客户端（`xcom_lua`）。支持异步文本/十六进制收发、时间戳、自动
循环发送、十条可编辑快捷发送、串口参数控制、有界接收日志保存、脚本/插件系统，
以及硬件优先（WARP 软件兜底）的 D3D11 渲染。

## 架构

- `xcom_core/`：版本化 C ABI DLL 与 Win32 OVERLAPPED 串口后端。
- `xcom_core/framework/coact/`：项目自有 AO、HSM、有界队列和固定内存池框架；
  它是唯一的业务事件运行时。
- `xcom_lua/`：生产客户端。LuaJIT 前端通过 `xcom_imgui` 桥接 DLL
  （`native/xcom_imgui`）驱动 ImGui 仪表盘，经 `xcom_ffi` FFI 绑定调用
  `xcom_core`，应用层由 `ui/` + `core/` 的纯 Lua 模块组成。
- `xcom_lua/native/launcher/`：小型 Win32 `xcom.exe`，以隐藏控制台启动
  `luvjit.exe`，客户端退出后自行结束。
- `xcom_client/`：旧的 PySide6 客户端（已被 `xcom_lua` 取代），仅作参考。
- `docs/`：现行设计、ABI、实施方案和状态文档。

`WinSerialBackend` 是唯一的生产串口通道。它采用单读线程、固定容量数据通道、
静态 coact `RxKick` 唤醒和 HSM 维护端口状态。文件写入异步且有界，不会阻塞接收。

## 环境

### LuaJIT 客户端（`xcom_lua`）

- Windows x64。
- `xcom_lua/runtime/` 里的 LuaJIT 运行时：`luvjit.exe`（含 libuv）以及配套的
  `lua51.dll`/`luv.dll`。来源见 `xcom_lua/runtime/README.md`。
- 重建 ImGui 桥：MSVC x64 Developer PowerShell、CMake 3.21+、Ninja。

### 原生核心（`xcom_core`）

- MSVC x64 Developer PowerShell、CMake 3.21+、Ninja。

## 构建

**ImGui 桥 DLL**（在 MSVC Developer PowerShell 中）：

```powershell
cd xcom_lua\native\xcom_imgui
build_imgui.cmd
```

编译 `xcom_imgui.dll` 并拷贝到 `xcom_lua/runtime/`。

**原生核心 DLL**（`xcom_core.dll`）由自身 CMake preset 配置；LuaJIT 客户端的
运行时包已在 `xcom_lua/runtime/` 带了一份。

## 字节码

应用模块以 LuaJIT 字节码（`.ljbc`）发布，避免发布包暴露可编辑源码。
`require` 优先加载 `.ljbc` 再回退 `.lua`。

修改 `main.lua` 或 `core/*.lua`、`ui/*.lua` 后重编字节码：

```powershell
powershell -ExecutionPolicy Bypass -File build_bytecode.ps1
# 增量：只重编源码有改动的模块
powershell -ExecutionPolicy Bypass -File build_bytecode.ps1 -Incremental
```

`scripts/` 与 `libs/` 刻意不字节化：`scripts/` 是用户可编辑插件，`libs/` 是
vendored 第三方 Lua 代码。

## 运行

```powershell
cd xcom_lua
runtime\luvjit.exe main.lua          # 源码检出运行
runtime\xcom.exe                      # 打包启动器（main.ljbc，无控制台）
```

`xcom.exe` 优先加载 `main.ljbc`，回退到 `main.lua`。设 `XCOM_CORE_DLL` 可指定
`xcom_core.dll` 路径。

## 发布包

```powershell
cd xcom_lua
powershell -ExecutionPolicy Bypass -File build_release.ps1 -Version 1.4.0
```

生成 `dist/xcom-release-v1.4.0.zip`。包内应用模块只发 `.ljbc`（不含 `.lua`），
`libs/` 与 `scripts/` 原样保留，`runtime/`（exe、DLL 与 `assets/`，含
`layout.toml` + 字体）一并打包。

## 测试

从 `xcom_lua` 目录：

```powershell
runtime\luvjit.exe tests\test_script_engine.lua
runtime\luvjit.exe tests\test_send_file_caps.lua
runtime\luvjit.exe tests\stress_warp_ui.lua 30 90   # 30 秒 @ ~90 KiB/s
```

完整测试见 `xcom_lua/tests/`，设计文档见 `docs/`。
