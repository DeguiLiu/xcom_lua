# XCOM 串口工具

[English](README.md)

XCOM 是 Windows 串口调试工具：核心为原生 C++17 DLL，界面为 PySide6。支持
异步文本/十六进制收发、时间戳、自动循环发送、十条可编辑快捷发送、串口参数控制
和有界接收日志保存。

## 架构

- `xcom_core/`：版本化 C ABI DLL 与 Win32 OVERLAPPED 串口后端。
- `xcom_core/framework/coact/`：项目自有 AO、HSM、有界队列和固定内存池框架；
  它是唯一的业务事件运行时。
- `xcom_client/`：PySide6 客户端；仅 `CoreWorker` 线程可通过 ctypes 调 DLL。
- `docs/`：现行设计、ABI、实施方案和状态文档。

`WinSerialBackend` 是唯一的生产串口通道。它采用单读线程、固定容量数据通道、
静态 coact `RxKick` 唤醒和 HSM 维护端口状态。文件写入异步且有界，不会阻塞接收。

## 环境

- Windows x64 与 MSVC x64 Developer PowerShell。
- CMake 3.21+、Ninja。
- Python 3.10+ 与 `xcom_client/requirements.txt` 的依赖。

## 构建与测试

```powershell
cmake --preset native-release
cmake --build --preset build-native-release
ctest --preset test-native-release
python -m pytest xcom_client/tests -q
```

原生 DLL 和测试程序位于 `build/native-release/bin/`。若该目录曾由其他 CMake
工具链配置，请先删除该目录，再在 MSVC Developer PowerShell 中重新配置。

## 启动

```powershell
python xcom_client/main.py
python xcom_client/main.py --fake
```

默认加载 `build/native-release/bin/xcom_core.dll`；可通过 `XCOM_CORE_DLL`
指定其他 DLL。`--fake` 可在无串口和无原生 DLL 时启动界面。

## 文档

请先阅读 `docs/implementation-plan.md` 与 `docs/high-performance-design.md`。
请运行上方命令以建立当前验证基线。
