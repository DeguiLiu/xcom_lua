# Hardware tests

Scripts that drive the real serial hardware (MCU on COM37, 115200 8N1). They
were written during the Windows bring-up and lived in a scratch tree outside the
repo; they are collected here so they are not lost.

Run them from `xcom_lua/` so `package.path = "./core/?.lua"` resolves:

```
runtime\luajit.exe ..\tools\hw-tests\link_115200.lua [port] [bytes] [logpath] [chunk] [pace_ms]
```

## Link and throughput

| Script | What it does |
| --- | --- |
| `link_115200.lua` | Sends a deterministic stream, compares the RX log lane byte for byte. End-to-end RX check. |
| `rx_stimulated_115200.lua` | Drives the port from a second process so RX arrives without a hand-soldered loopback. |
| `rx_sustain_115200.lua` | Long-running RX soak; the script behind the 921600 / sustained-rate question. |
| `slow_target.lua`, `slow_pipe_server.ps1`, `run_slow_test.ps1`, `run_slow_test10.ps1` | Deliberately slow peers, for timeout and backpressure behaviour. |

## Port state

| Script | What it does |
| --- | --- |
| `open_diag.lua` | Reports why an open succeeded or failed, including the Win32 code. |
| `list_probe.lua` | Enumerates ports and shows which ones are held by another process. |
| `hold_port.ps1` | Keeps a port open so the contended branch can be exercised. |
| `serial_probe.ps1` | Interactive probe for a single port. |

## Stress and ABI

| Script | What it does |
| --- | --- |
| `run_pal_stress.ps1` | Repeated open/close/IO cycles against the platform layer. |
| `run_repeat.ps1` | Runs a given script N times to catch run-to-run flakiness. |
| `abi_pins.lua` | Asserts the host DLL's ABI version and export set. |
| `dump_exports.cmd` | Dumps the export table for manual comparison. |

## Flashing

`burn.ps1` is the MCU flash step used to put matching firmware on the target
before a run.
