# xcom_core - XCOM 串口核心（C++17 DLL）

`xcom_core.dll` 实现了 `include/xcom/xcom.h` 中的版本化 C ABI。它基于项目自研的
`framework/coact` 事件运行时框架,以及原生的 `WinSerialBackend`(Win32
OVERLAPPED 适配层)。构建中不存在 CSerialPort、libserial、pyserial 或第二条 COM
数据通路。

## 构建

```powershell
cmake --preset native-release
cmake --build --preset build-native-release
ctest --preset test-native-release
```

受支持的生产工具链为 MSVC x64 配合 C++17。免硬件的 `xcom_smoke_test.exe` 通过
`xcom_test_inject_rx` 走通真实的 receive、typed-send、display 与 file writer
路径。

## 原生串口后端

`src/io/serial_backend_win.{hpp,cpp}` 是项目自研的 Win32 适配层,配有小型固定
的 callback bridge。它以 `OVERLAPPED` I/O 打开 `\\.\COMn` 句柄,将 C ABI 的
波特率/数据位/校验位/停止位/流控/DTR/RTS 映射到 `DCB`,并为每个已打开会话拥有一条
读线程。

- 读完成时,每个块触发一次固定的、零分配的回调。回调把数据复制进自有的
  `RxDatalane` 块池,向 coact 的 SPSC ring 发布描述符,然后 arm 静态 `RxKick`
  事件。
- `close()` 撤销回调 admission,发送信号并取消挂起的读,join 读线程,再确认没有
  回调仍在 in-flight,然后才释放。
- `SessionWriter` 是唯一的写调用者。其固定 job ring 可防止对端过慢或 Win32
  写超时导致 coact 接收处理饥饿。
- 后端错误经 `SerialAo` sink 上报;HSM(而非 I/O 线程)始终是端口状态迁移的唯一
  authority。

## coact 集成

接收 SPSC ring 本身并不是 Dispatcher 的唤醒源。其生产者在空→非空时 arm
`RxKickGate`,并通过 Coordinator 提交唯一的静态 `Signal::RxKick`;staging 的
wake latch 因此在没有回调分配、OS 消息队列或热路径锁的前提下唤醒 Dispatcher。
低频控制 EventPool 使用真实的 spin critical section。Rx 与显示数据采用固定
槽位的所有权转移,不涉及 EventPool 引用计数。

信号与优先级是限定作用域的定宽枚举;资源预算是类型化的 `constexpr` 量;HSM
定义是 `constexpr std::array` 值;数据面使用显式 64 字节对齐的块和固定容量的
队列。

## 验证

```powershell
.\build\native-release\bin\xcom_smoke_test.exe
.\build\native-release\bin\xcom_session_churn_test.exe
```

物理回环仍需要 TX/RX 桥接线或 null-modem 电缆。请在目标硬件上分别测试非法端口
名、重复开关、长接收突发、写超时与设备拔出。