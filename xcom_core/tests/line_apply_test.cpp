// line_apply_test.cpp - hardware-free regression for manual DTR/RTS pin writes.
//
// The physical pin behaviour needs a real USB-UART adapter, but the decision
// logic does not: this test builds the real WinSerialBackend against a fake
// Win32 layer (tools/win32-stub/windows.h plus the definitions below) so a
// failing EscapeCommFunction and a driver-owned RTS pin are both reproducible
// on a Linux host with a bare g++.
//
// It pins the contract of defect A (rts=0 under RTS/CTS is not a false success)
// and defect B (a discarded EscapeCommFunction return is not reported as
// applied):
//   1. EscapeCommFunction == TRUE  -> Applied, and the right IOCTL was issued;
//   2. EscapeCommFunction == FALSE -> Failed (NOT success);
//   3. RTS under RTS/CTS handshake -> DriverOwned, and NO IOCTL is issued;
//      DTR stays drivable in the same session (flow control does not own it);
//   4. a never-opened backend      -> Closed.
//   5. open with drive = Assert/Deassert keeps the legacy pin behaviour
//      (SETDTR/CLRRTS, DCB ENABLE/DISABLE);
//   6. open with drive = LeaveAlone issues NO EscapeCommFunction and programs
//      the least-driving DCB value (DISABLE - not high impedance);
//   7. an out-of-range drive value is rejected before the device is touched.
//
// BUILD (Linux, from the repository root):
//   g++ -std=c++17 -Wall -Wextra -I tools/win32-stub
//       -I xcom_core/include -I xcom_core/src -I xcom_core/src/io
//       -I xcom_core/src/foundation
//       xcom_core/tests/line_apply_test.cpp
//       xcom_core/src/io/serial_backend_win.cpp
//       xcom_core/src/foundation/unique_handle.cpp
//       -o /tmp/line_apply_test -lpthread
//
// SPDX-License-Identifier: MIT
#include <windows.h>

#include <cstdint>
#include <cstdio>

#include "serial_backend_win.hpp"

namespace {

int g_failures = 0;

#define CHECK(cond, msg)                                               \
    do {                                                               \
        if (!(cond)) {                                                 \
            std::fprintf(stderr, "FAIL: %s (%s:%d)\n", msg, __FILE__, \
                         __LINE__);                                    \
            ++g_failures;                                              \
        }                                                              \
        else {                                                         \
            std::printf("ok: %s\n", msg);                               \
        }                                                              \
        std::fflush(stdout);                                           \
    } while (0)

// ---- fake Win32 layer ------------------------------------------------------
// Only the primitives WinSerialBackend touches. CreateFileW/CreateEventW hand
// out distinct non-null sentinels so UniqueHandle::valid() is true; the DCB is
// stored by SetCommState and replayed by GetCommState so configure()'s
// read-back verification sees exactly what it programmed.
DWORD g_last_error = 0U;
DCB g_dcb{};
BOOL g_escape_result = TRUE;
DWORD g_last_escape = 0U;
DWORD g_escape_calls = 0U;
DWORD g_last_waited_for = 0U;

}  // namespace

BOOL WINAPI EscapeCommFunction(HANDLE, DWORD function)
{
    ++g_escape_calls;
    g_last_escape = function;
    return g_escape_result;
}

HANDLE WINAPI CreateFileW(const wchar_t*, DWORD, DWORD, SECURITY_ATTRIBUTES*,
                          DWORD, DWORD, HANDLE)
{
    return reinterpret_cast<HANDLE>(static_cast<LONG_PTR>(0x1000));
}

HANDLE WINAPI CreateEventW(SECURITY_ATTRIBUTES*, BOOL, BOOL, const wchar_t*)
{
    static LONG_PTR next = 0x2000;
    next += 0x10;
    return reinterpret_cast<HANDLE>(next);
}

BOOL WINAPI CloseHandle(HANDLE) { return TRUE; }
BOOL WINAPI SetEvent(HANDLE) { return TRUE; }
BOOL WINAPI ResetEvent(HANDLE) { return TRUE; }
DWORD WINAPI WaitForSingleObject(HANDLE, DWORD) { return WAIT_OBJECT_0; }
DWORD WINAPI WaitForMultipleObjects(DWORD, const HANDLE*, BOOL, DWORD)
{
    return WAIT_OBJECT_0;
}
BOOL WINAPI GetOverlappedResult(HANDLE, OVERLAPPED*, DWORD*, BOOL)
{
    return TRUE;
}
BOOL WINAPI CancelIoEx(HANDLE, OVERLAPPED*) { return TRUE; }

// Synchronous zero-byte completion: the read loop ticks, sees no bytes, and
// re-arms. stop_requested_ ends it on close().
BOOL WINAPI ReadFile(HANDLE, void*, DWORD, DWORD* received, OVERLAPPED*)
{
    if (received != nullptr) {
        *received = 0U;
    }
    return TRUE;
}

BOOL WINAPI WriteFile(HANDLE, const void*, DWORD, DWORD* written, OVERLAPPED*)
{
    if (written != nullptr) {
        *written = 0U;
    }
    return TRUE;
}

BOOL WINAPI SetupComm(HANDLE, DWORD, DWORD) { return TRUE; }
BOOL WINAPI GetCommState(HANDLE, DCB* out)
{
    if (out == nullptr) {
        return FALSE;
    }
    const DWORD length = out->DCBlength;
    *out = g_dcb;
    out->DCBlength = length;
    return TRUE;
}
BOOL WINAPI SetCommState(HANDLE, DCB* in)
{
    if (in == nullptr) {
        return FALSE;
    }
    g_dcb = *in;
    return TRUE;
}
BOOL WINAPI SetCommTimeouts(HANDLE, COMMTIMEOUTS*) { return TRUE; }
BOOL WINAPI ClearCommError(HANDLE, DWORD* errors, COMSTAT* stat)
{
    if (errors != nullptr) {
        *errors = 0U;
    }
    if (stat != nullptr) {
        *stat = COMSTAT{};
    }
    return TRUE;
}

DWORD WINAPI GetLastError(void) { return g_last_error; }
void WINAPI SetLastError(DWORD error) { g_last_error = error; }

HANDLE WINAPI GetCurrentThread(void) { return nullptr; }
BOOL WINAPI SetThreadPriority(HANDLE, int) { return TRUE; }

int WINAPI MultiByteToWideChar(UINT, DWORD, const char* in, int in_size,
                               wchar_t* out, int out_size)
{
    const int count = in_size;
    if (out_size == 0) {
        return count;
    }
    for (int index = 0; index < count && index < out_size; ++index) {
        out[index] = static_cast<wchar_t>(static_cast<unsigned char>(in[index]));
    }
    return count;
}

LSTATUS WINAPI RegOpenKeyExA(HKEY, const char*, DWORD, DWORD, HKEY*)
{
    return ERROR_FILE_NOT_FOUND;
}
LSTATUS WINAPI RegEnumValueA(HKEY, DWORD, char*, DWORD*, DWORD*, DWORD*, BYTE*,
                             DWORD*)
{
    return ERROR_NO_MORE_ITEMS;
}
LSTATUS WINAPI RegCloseKey(HKEY) { return ERROR_SUCCESS; }

// ---- tests -----------------------------------------------------------------
namespace {

using xcom::LineApplyResult;
using xcom::LineDrive;
using xcom::SerialPortOptions;
using xcom::WinSerialBackend;

SerialPortOptions base_options()
{
    SerialPortOptions options{};
    options.port_name = "COM1";
    options.baud = 115200U;
    options.data_bits = 8U;
    options.stop_bits = 0U;
    options.parity = 0U;
    options.flow_control = 0U;
    options.dtr_drive = LineDrive::Deassert;
    options.rts_drive = LineDrive::Deassert;
    return options;
}

void test_escape_result_is_reported()
{
    WinSerialBackend backend;
    std::int32_t error = 0;
    CHECK(backend.open(base_options(), {}, {}, {}, error),
          "open a plain port against the fake Win32 layer");

    g_escape_result = TRUE;
    g_escape_calls = 0U;
    CHECK(backend.set_dtr(true) == LineApplyResult::Applied,
          "set_dtr(true) reports Applied when the IOCTL succeeds");
    CHECK(g_escape_calls == 1U && g_last_escape == SETDTR,
          "set_dtr(true) issues exactly SETDTR");
    CHECK(backend.set_rts(false) == LineApplyResult::Applied,
          "set_rts(false) reports Applied when the IOCTL succeeds");
    CHECK(g_last_escape == CLRRTS, "set_rts(false) issues CLRRTS");

    // Defect B: a failed IOCTL must NOT be reported as applied.
    g_escape_result = FALSE;
    CHECK(backend.set_dtr(true) == LineApplyResult::Failed,
          "set_dtr(true) reports Failed when the IOCTL fails");
    CHECK(backend.set_rts(true) == LineApplyResult::Failed,
          "set_rts(true) reports Failed when the IOCTL fails");

    g_escape_result = TRUE;
    backend.close();
}

void test_rts_under_flow_control_is_driver_owned()
{
    WinSerialBackend backend;
    std::int32_t error = 0;
    SerialPortOptions options = base_options();
    options.flow_control = 1U;   // RTS/CTS handshake owns RTS
    options.rts_drive = LineDrive::Assert;
    CHECK(backend.open(options, {}, {}, {}, error),
          "open a port with RTS/CTS handshake");

    g_escape_result = TRUE;
    g_escape_calls = 0U;
    // Defect A: the driver owns RTS, so the request is deliberately not
    // applied. That is a distinct outcome from an API failure (Failed).
    CHECK(backend.set_rts(true) == LineApplyResult::DriverOwned,
          "set_rts under RTS/CTS reports DriverOwned");
    CHECK(backend.set_rts(false) == LineApplyResult::DriverOwned,
          "set_rts(false) under RTS/CTS reports DriverOwned");
    CHECK(g_escape_calls == 0U,
          "set_rts under RTS/CTS issues no IOCTL against a driver-owned pin");

    // DTR is never flow-controlled: the same session must still drive it.
    CHECK(backend.set_dtr(true) == LineApplyResult::Applied,
          "set_dtr stays applicable while RTS is driver-owned");
    CHECK(g_escape_calls == 1U && g_last_escape == SETDTR,
          "set_dtr under RTS/CTS still issues SETDTR");

    backend.close();
}

void test_closed_backend_reports_closed()
{
    WinSerialBackend backend;
    CHECK(backend.set_dtr(true) == LineApplyResult::Closed,
          "set_dtr on a never-opened backend reports Closed");
    CHECK(backend.set_rts(true) == LineApplyResult::Closed,
          "set_rts on a never-opened backend reports Closed");
}

// The legacy 0/1 drive behaviour must be untouched by the tri-state extension:
// 1 asserts the pin (SETxxx / DCB ENABLE), 0 deasserts it (CLRxxx / DCB DISABLE).
void test_configure_drives_asserted_and_deasserted()
{
    WinSerialBackend backend;
    std::int32_t error = 0;
    SerialPortOptions options = base_options();
    options.dtr_drive = LineDrive::Assert;
    options.rts_drive = LineDrive::Deassert;
    g_escape_result = TRUE;
    g_escape_calls = 0U;
    CHECK(backend.open(options, {}, {}, {}, error),
          "open with DTR asserted / RTS deasserted");
    // configure() replays DTR first (SETDTR), then RTS (CLRRTS):
    // one IOCTL per line, ending on CLRRTS.
    CHECK(g_escape_calls == 2U,
          "assert/deassert at open issues one IOCTL per line");
    CHECK(g_last_escape == CLRRTS,
          "the replay ends with CLRRTS for a deasserted RTS");
    CHECK(g_dcb.fDtrControl == DTR_CONTROL_ENABLE,
          "asserted DTR programs fDtrControl = ENABLE");
    CHECK(g_dcb.fRtsControl == RTS_CONTROL_DISABLE,
          "deasserted RTS programs fRtsControl = DISABLE");
    backend.close();
}

// The point of the new state: LeaveAlone must suppress the EscapeCommFunction
// replay entirely, so the core issues no DTR/RTS transition of its own.
void test_leave_alone_skips_escape_comm_function()
{
    WinSerialBackend backend;
    std::int32_t error = 0;
    SerialPortOptions options = base_options();
    options.dtr_drive = LineDrive::LeaveAlone;
    options.rts_drive = LineDrive::LeaveAlone;
    g_escape_result = TRUE;
    g_escape_calls = 0U;
    CHECK(backend.open(options, {}, {}, {}, error),
          "open with both lines left alone");
    CHECK(g_escape_calls == 0U,
          "LeaveAlone issues NO EscapeCommFunction for either line");
    // The DCB still takes the least-driving value available (DISABLE). This is
    // NOT high impedance; it is the documented residual limitation.
    CHECK(g_dcb.fDtrControl == DTR_CONTROL_DISABLE,
          "LeaveAlone programs fDtrControl = DISABLE (not high-Z)");
    CHECK(g_dcb.fRtsControl == RTS_CONTROL_DISABLE,
          "LeaveAlone programs fRtsControl = DISABLE (not high-Z)");
    backend.close();
}

// Out-of-range values must be rejected before any device is touched, not
// silently coerced to a level that could pulse a target's reset pin.
void test_out_of_range_drive_rejected_before_open()
{
    WinSerialBackend backend;
    std::int32_t error = 0;
    g_escape_calls = 0U;
    SerialPortOptions options = base_options();
    options.dtr_drive = static_cast<LineDrive>(3U);
    CHECK(!backend.open(options, {}, {}, {}, error),
          "open rejects an out-of-range DTR drive value");
    CHECK(error == ERROR_INVALID_PARAMETER,
          "rejection reports ERROR_INVALID_PARAMETER");
    CHECK(g_escape_calls == 0U,
          "an invalid drive value never reaches EscapeCommFunction");

    options = base_options();
    options.rts_drive = static_cast<LineDrive>(255U);
    CHECK(!backend.open(options, {}, {}, {}, error),
          "open rejects an out-of-range RTS drive value");

    // The predicate both the ABI range check and this validation rely on.
    CHECK(xcom::valid_line_drive(LineDrive::Deassert) &&
          xcom::valid_line_drive(LineDrive::Assert) &&
          xcom::valid_line_drive(LineDrive::LeaveAlone) &&
          !xcom::valid_line_drive(static_cast<LineDrive>(3U)),
          "valid_line_drive accepts exactly 0..2");
}

}  // namespace

int main()
{
    test_escape_result_is_reported();
    test_rts_under_flow_control_is_driver_owned();
    test_closed_backend_reports_closed();
    test_configure_drives_asserted_and_deasserted();
    test_leave_alone_skips_escape_comm_function();
    test_out_of_range_drive_rejected_before_open();
    if (g_failures != 0) {
        std::fprintf(stderr, "line-apply tests FAILED (%d)\n", g_failures);
        return 1;
    }
    std::printf("line-apply tests PASS\n");
    return 0;
}
