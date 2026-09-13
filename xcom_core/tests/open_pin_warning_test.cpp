// open_pin_warning_test.cpp - hardware-free regression for the non-fatal
// open-time DTR/RTS pin-replay warning.
//
// The backend programs the DCB and then replays the requested DTR/RTS levels
// with an explicit EscapeCommFunction. The replay result is deliberately NOT
// allowed to fail the open (the DCB already holds the level), but it used to be
// discarded entirely: a target whose NRST/BOOT pulse never reached the pin was
// indistinguishable from one that received it.
//
// This test builds the real WinSerialBackend against a fake Win32 layer (the
// same approach as line_apply_test.cpp) and pins the replacement contract:
//   1. a FAILED pin write emits exactly one warning naming the line ("DTR" /
//      "RTS") and the Win32 code, and the open STILL SUCCEEDS (error == success);
//   2. a SUCCEEDING pin write emits NO warning;
//   3. LeaveAlone emits no warning because no IOCTL is issued at all.
// (1) is the crux: the fix must turn a silent failure into a visible warning,
// never into a failed open.
//
// The runtime side of the contract (xcom_core.cpp sink_owner_open pushes the
// text into the error ring and submits no event) is reviewed there; this suite
// covers the backend channel.
//
// BUILD (Linux, from the repository root):
//   g++ -std=c++17 -Wall -Wextra -I tools/win32-stub
//       -I xcom_core/include -I xcom_core/src -I xcom_core/src/io
//       -I xcom_core/src/foundation
//       xcom_core/tests/open_pin_warning_test.cpp
//       xcom_core/src/io/serial_backend_win.cpp
//       xcom_core/src/foundation/unique_handle.cpp
//       -ffunction-sections -Wl,--gc-sections
//       -o /tmp/open_pin_warning_test -lpthread
//
// SPDX-License-Identifier: MIT
#include <windows.h>

#include <cstdint>
#include <cstdio>
#include <cstring>
#include <string_view>

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

using xcom::LineDrive;
using xcom::SerialPortOptions;
using xcom::WinSerialBackend;

// Fixed-size capture for the warning text; mirrors the callback-path
// no-allocation discipline rather than relying on std::string in the sink.
struct WarningCapture {
    std::uint32_t count = 0U;
    char last[256] = {};

    WinSerialBackend::WarningCallback sink()
    {
        return [this](std::string_view message) noexcept {
            ++count;
            const std::size_t n =
                message.size() < sizeof(last) - 1U ? message.size()
                                                   : sizeof(last) - 1U;
            if (n > 0U) {
                std::memcpy(last, message.data(), n);
            }
            last[n] = '\0';
        };
    }
};

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

bool contains(const char* haystack, const char* needle)
{
    return std::strstr(haystack, needle) != nullptr;
}

// Crux: a failed DTR replay warns, and the open still succeeds.
void test_failed_dtr_replay_warns_but_opens()
{
    WinSerialBackend backend;
    WarningCapture capture;
    backend.set_warning(capture.sink());

    SerialPortOptions options = base_options();
    options.dtr_drive = LineDrive::Assert;      // replay issues SETDTR
    options.rts_drive = LineDrive::LeaveAlone;  // no RTS IOCTL, so one warning

    g_escape_result = FALSE;
    g_escape_calls = 0U;
    constexpr DWORD kPinError = 1167U;          // ERROR_DEVICE_REMOVED
    g_last_error = kPinError;

    std::int32_t error = 0;
    const bool opened = backend.open(options, {}, {}, {}, error);

    CHECK(opened, "a failed pin replay does NOT fail the open");
    CHECK(error == xcom::kSerialSuccess,
          "a failed pin replay leaves the open error at success");
    CHECK(g_escape_calls == 1U && g_last_escape == SETDTR,
          "the DTR replay did issue SETDTR before failing");
    CHECK(capture.count == 1U,
          "exactly one warning is emitted for the failed DTR replay");
    CHECK(contains(capture.last, "DTR"),
          "the warning names the DTR line");
    CHECK(contains(capture.last, "1167"),
          "the warning carries the Win32 error code (1167)");

    backend.close();
}

// A failed RTS replay is reported for the RTS line specifically.
void test_failed_rts_replay_warns_for_rts()
{
    WinSerialBackend backend;
    WarningCapture capture;
    backend.set_warning(capture.sink());

    SerialPortOptions options = base_options();
    options.dtr_drive = LineDrive::LeaveAlone;
    options.rts_drive = LineDrive::Assert;      // replay issues SETRTS

    g_escape_result = FALSE;
    g_escape_calls = 0U;
    g_last_error = 5U;                          // ERROR_ACCESS_DENIED

    std::int32_t error = 0;
    const bool opened = backend.open(options, {}, {}, {}, error);

    CHECK(opened, "a failed RTS replay does NOT fail the open");
    CHECK(error == xcom::kSerialSuccess,
          "a failed RTS replay leaves the open error at success");
    CHECK(capture.count == 1U, "exactly one warning for the failed RTS replay");
    CHECK(contains(capture.last, "RTS"), "the warning names the RTS line");
    CHECK(contains(capture.last, "5"),
          "the warning carries the Win32 error code (5)");

    backend.close();
}

// A succeeding replay must not warn - no false alarm on a healthy open.
void test_successful_replay_is_silent()
{
    WinSerialBackend backend;
    WarningCapture capture;
    backend.set_warning(capture.sink());

    SerialPortOptions options = base_options();
    options.dtr_drive = LineDrive::Assert;
    options.rts_drive = LineDrive::Deassert;

    g_escape_result = TRUE;
    g_escape_calls = 0U;

    std::int32_t error = 0;
    CHECK(backend.open(options, {}, {}, {}, error),
          "open with a succeeding replay succeeds");
    CHECK(g_escape_calls == 2U,
          "assert/deassert issues one IOCTL per line");
    CHECK(capture.count == 0U,
          "a succeeding pin replay emits NO warning");

    backend.close();
}

// LeaveAlone issues no IOCTL, so even a failing EscapeCommFunction cannot
// produce a warning - there is nothing to report.
void test_leave_alone_replay_is_silent()
{
    WinSerialBackend backend;
    WarningCapture capture;
    backend.set_warning(capture.sink());

    SerialPortOptions options = base_options();
    options.dtr_drive = LineDrive::LeaveAlone;
    options.rts_drive = LineDrive::LeaveAlone;

    g_escape_result = FALSE;
    g_escape_calls = 0U;

    std::int32_t error = 0;
    CHECK(backend.open(options, {}, {}, {}, error),
          "open with both lines left alone succeeds");
    CHECK(g_escape_calls == 0U, "LeaveAlone issues no EscapeCommFunction");
    CHECK(capture.count == 0U, "LeaveAlone emits NO warning");

    backend.close();
}

}  // namespace

int main()
{
    test_failed_dtr_replay_warns_but_opens();
    test_failed_rts_replay_warns_for_rts();
    test_successful_replay_is_silent();
    test_leave_alone_replay_is_silent();
    if (g_failures != 0) {
        std::fprintf(stderr, "open-pin-warning tests FAILED (%d)\n", g_failures);
        return 1;
    }
    std::printf("open-pin-warning tests PASS\n");
    return 0;
}
