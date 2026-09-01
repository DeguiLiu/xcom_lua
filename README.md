# XCOM Serial Tool

[简体中文](README_zh.md)

XCOM is a Windows serial debugging tool with a native C++17 core and a PySide6
desktop client. It provides asynchronous text/HEX receive and send, timestamps,
auto-send, ten editable quick-send entries, serial parameter control, and
bounded receive-log saving.

## Architecture

- `xcom_core/` — versioned C ABI DLL and the Win32 OVERLAPPED serial backend.
- `xcom_core/framework/coact/` — project-owned AO, HSM, bounded-queue and
  fixed-pool framework; it is the sole business event runtime.
- `xcom_client/` — PySide6 UI. Its `CoreWorker` is the only ctypes caller.
- `docs/` — active design, ABI, implementation and status documents.

`WinSerialBackend` is the only production COM path. It uses one read thread,
fixed-capacity data lanes, a static coact RxKick wakeup, and HSM-owned port
state. File writing is asynchronous and bounded, so it cannot block reception.

## Prerequisites

- Windows x64 and an MSVC x64 Developer PowerShell.
- CMake 3.21+ with Ninja.
- Python 3.10+ and the dependencies in `xcom_client/requirements.txt`.

## Build and Test

```powershell
cmake --preset native-release
cmake --build --preset build-native-release
ctest --preset test-native-release
python -m pytest xcom_client/tests -q
```

Native binaries are written to `build/native-release/bin/`. If that directory
was configured with a different CMake toolchain, remove it before reconfiguring
from the MSVC Developer PowerShell.

## Run

```powershell
python xcom_client/main.py
python xcom_client/main.py --fake
```

The first command loads `build/native-release/bin/xcom_core.dll`; set
`XCOM_CORE_DLL` to use another DLL. The `--fake` mode starts the UI without a
serial device or native core.

## Documentation

Start with `docs/implementation-plan.md` and `docs/high-performance-design.md`.
Run the commands above to establish the current verification baseline.
