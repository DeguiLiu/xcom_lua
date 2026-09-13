// serial_short_write_test.cpp - hardware-free regression for the transmit-path
// short-write data-integrity defect.
//
// Defect: WinSerialBackend::write() treated any WriteFile completion shorter
// than the request as a hard failure and returned, so the unwritten tail was
// dropped. The caller then released the TxBlock, losing the remainder while
// reporting only a bare write failure - a truncated frame was invisible.
//
// This test drives the real WinSerialBackend against a scripted fake Win32
// layer (the same approach as serial_close_reap_test.cpp), so short completions
// are deterministic. It asserts:
//   1. a short sync completion is continued until the whole buffer is out and
//      `written` reports the full size;
//   2. a short overlapped completion is likewise continued, resuming at the
//      first unsent byte;
//   3. a partial transfer followed by a genuine error reports the real Win32
//      error AND the exact byte count that reached the driver;
//   4. a driver that stops making progress (0 bytes on a non-empty request) is
//      bounded - no spin - and reported as a failure with the correct partial
//      count.
//
// BUILD (Linux, from the repository root):
//   g++ -std=c++17 -Wall -Wextra -I tools/win32-stub
//       -I xcom_core/include -I xcom_core/src -I xcom_core/src/io
//       -I xcom_core/src/foundation
//       xcom_core/tests/serial_short_write_test.cpp
//       xcom_core/src/io/serial_backend_win.cpp
//       xcom_core/src/foundation/unique_handle.cpp
//       -o /tmp/serial_short_write_test -lpthread
//
// SPDX-License-Identifier: MIT
#include <windows.h>

#include <atomic>
#include <condition_variable>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <mutex>

#include "setupapi.h"

#include "serial_backend_win.hpp"

#ifndef ERROR_SHARING_VIOLATION
#define ERROR_SHARING_VIOLATION 32U
#endif

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
            std::printf("ok: %s\n", msg);                              \
        }                                                              \
        std::fflush(stdout);                                           \
    } while (0)

// ---- scripted fake Win32 layer --------------------------------------------

// One scripted WriteFile outcome. kSync* return synchronously; kPending* return
// FALSE + ERROR_IO_PENDING and are reaped by a later GetOverlappedResult with
// the stored count/error.
enum class WStep : std::uint8_t {
    kSyncOk,
    kSyncError,
    kPendingOk,
    kPendingError,
};

struct WriteStep final {
    WStep kind;
    DWORD count;   // bytes written for kSyncOk / kPendingOk
    DWORD error;   // Win32 error for kSyncError / kPendingError
};

constexpr int kMaxScript = 16;
WriteStep g_script[kMaxScript]{};
int g_script_len = 0;
int g_write_calls = 0;
const void* g_call_ptr[kMaxScript]{};
DWORD g_call_size[kMaxScript]{};
DWORD g_pending_count = 0U;
DWORD g_pending_error = 0U;
bool g_pending_active = false;

DWORD g_last_error = 0U;
DCB g_dcb{};

HANDLE g_ev_read = nullptr;
HANDLE g_ev_write = nullptr;
HANDLE g_ev_stop = nullptr;
int g_event_seq = 0;

bool g_stop_signaled = false;
bool g_in_wait = false;
std::mutex g_mu;
std::condition_variable g_cv;

std::atomic<int> g_fault_calls{0};

void set_script(const WriteStep* steps, int count)
{
    g_script_len = count < kMaxScript ? count : kMaxScript;
    for (int i = 0; i < g_script_len; ++i) {
        g_script[i] = steps[i];
    }
}

void reset_fake_state()
{
    std::lock_guard<std::mutex> lock(g_mu);
    g_script_len = 0;
    g_write_calls = 0;
    g_pending_count = 0U;
    g_pending_error = 0U;
    g_pending_active = false;
    g_last_error = 0U;
    g_event_seq = 0;
    g_ev_read = nullptr;
    g_ev_write = nullptr;
    g_ev_stop = nullptr;
    g_stop_signaled = false;
    g_in_wait = false;
    g_fault_calls.store(0);
    for (int i = 0; i < kMaxScript; ++i) {
        g_call_ptr[i] = nullptr;
        g_call_size[i] = 0U;
    }
}

}  // namespace

// ---- fake Win32 primitives the backend calls ------------------------------

HANDLE WINAPI CreateFileW(const wchar_t*, DWORD, DWORD, SECURITY_ATTRIBUTES*,
                          DWORD, DWORD, HANDLE)
{
    return reinterpret_cast<HANDLE>(static_cast<LONG_PTR>(0x1000));
}

HANDLE WINAPI CreateEventW(SECURITY_ATTRIBUTES*, BOOL, BOOL, const wchar_t*)
{
    static LONG_PTR next = 0x2000;
    next += 0x10;
    HANDLE handle = reinterpret_cast<HANDLE>(next);
    if (g_event_seq == 0) {
        g_ev_read = handle;
    }
    else if (g_event_seq == 1) {
        g_ev_write = handle;
    }
    else {
        g_ev_stop = handle;
    }
    ++g_event_seq;
    return handle;
}

BOOL WINAPI CloseHandle(HANDLE) { return TRUE; }

BOOL WINAPI SetEvent(HANDLE handle)
{
    if (handle == g_ev_stop) {
        std::lock_guard<std::mutex> lock(g_mu);
        g_stop_signaled = true;
        g_cv.notify_all();
    }
    return TRUE;
}

BOOL WINAPI ResetEvent(HANDLE) { return TRUE; }

DWORD WINAPI WaitForSingleObject(HANDLE handle, DWORD)
{
    if (handle == g_ev_write) {
        // A scripted overlapped write completes immediately once pending.
        return WAIT_OBJECT_0;
    }
    if (handle == g_ev_read) {
        return WAIT_TIMEOUT;
    }
    return WAIT_OBJECT_0;
}

// The read thread parks here until close() signals stop_event_, so it never
// reaps the write OVERLAPPED and every GetOverlappedResult below belongs to the
// write path under test.
DWORD WINAPI WaitForMultipleObjects(DWORD, const HANDLE*, BOOL, DWORD)
{
    std::unique_lock<std::mutex> lock(g_mu);
    g_in_wait = true;
    g_cv.notify_all();
    g_cv.wait(lock, [] { return g_stop_signaled; });
    return WAIT_OBJECT_0;
}

BOOL WINAPI ReadFile(HANDLE, void*, DWORD, DWORD* received, OVERLAPPED*)
{
    if (received != nullptr) {
        *received = 0U;
    }
    SetLastError(ERROR_IO_PENDING);
    return FALSE;
}

BOOL WINAPI GetOverlappedResult(HANDLE, OVERLAPPED*, DWORD* transferred, BOOL)
{
    if (!g_pending_active) {
        if (transferred != nullptr) {
            *transferred = 0U;
        }
        return TRUE;
    }
    g_pending_active = false;
    if (g_pending_error != 0U) {
        SetLastError(g_pending_error);
        return FALSE;
    }
    if (transferred != nullptr) {
        *transferred = g_pending_count;
    }
    return TRUE;
}

BOOL WINAPI CancelIoEx(HANDLE, OVERLAPPED*) { return TRUE; }

BOOL WINAPI WriteFile(HANDLE, const void* buffer, DWORD to_write, DWORD* written,
                      OVERLAPPED*)
{
    const int index = g_write_calls++;
    if (index < kMaxScript) {
        g_call_ptr[index] = buffer;
        g_call_size[index] = to_write;
    }
    if (written != nullptr) {
        *written = 0U;
    }
    if (index >= g_script_len) {
        // No script left: complete the whole request synchronously.
        if (written != nullptr) {
            *written = to_write;
        }
        return TRUE;
    }
    const WriteStep& step = g_script[index];
    switch (step.kind) {
    case WStep::kSyncOk:
        if (written != nullptr) {
            *written = step.count < to_write ? step.count : to_write;
        }
        return TRUE;
    case WStep::kSyncError:
        SetLastError(step.error);
        return FALSE;
    case WStep::kPendingOk:
    case WStep::kPendingError:
    default:
        g_pending_count = step.kind == WStep::kPendingOk ? step.count : 0U;
        g_pending_error = step.error;
        g_pending_active = true;
        SetLastError(ERROR_IO_PENDING);
        return FALSE;
    }
}

BOOL WINAPI EscapeCommFunction(HANDLE, DWORD) { return TRUE; }
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

// Registry + SetupAPI fakes: required to link the backend TU. Enumeration is not
// exercised here.
LSTATUS WINAPI RegOpenKeyExA(HKEY, const char*, DWORD, DWORD, HKEY* out)
{
    if (out != nullptr) {
        *out = reinterpret_cast<HKEY>(static_cast<LONG_PTR>(0x4000));
    }
    return ERROR_SUCCESS;
}
LSTATUS WINAPI RegEnumValueA(HKEY, DWORD, char*, DWORD*, DWORD*, DWORD*, BYTE*,
                             DWORD*)
{
    return ERROR_NO_MORE_ITEMS;
}
LSTATUS WINAPI RegCloseKey(HKEY) { return ERROR_SUCCESS; }
LSTATUS WINAPI RegQueryValueExA(HKEY, const char*, DWORD*, DWORD*, BYTE*,
                                DWORD*)
{
    return ERROR_FILE_NOT_FOUND;
}
HDEVINFO WINAPI SetupDiGetClassDevsA(const GUID*, const char*, HWND, DWORD)
{
    return INVALID_HANDLE_VALUE;
}
BOOL WINAPI SetupDiEnumDeviceInfo(HDEVINFO, DWORD, SP_DEVINFO_DATA*)
{
    return FALSE;
}
HKEY WINAPI SetupDiOpenDevRegKey(HDEVINFO, SP_DEVINFO_DATA*, DWORD, DWORD,
                                 DWORD, DWORD)
{
    return INVALID_HANDLE_VALUE;
}
BOOL WINAPI SetupDiGetDeviceRegistryPropertyA(HDEVINFO, SP_DEVINFO_DATA*, DWORD,
                                              DWORD*, BYTE*, DWORD, DWORD*)
{
    return FALSE;
}
BOOL WINAPI SetupDiDestroyDeviceInfoList(HDEVINFO) { return TRUE; }

// ---- tests -----------------------------------------------------------------
namespace {

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
    options.dtr_drive = LineDrive::LeaveAlone;
    options.rts_drive = LineDrive::LeaveAlone;
    return options;
}

bool open_backend(WinSerialBackend& backend, std::int32_t& error)
{
    return backend.open(
        base_options(), {}, [](std::int32_t) noexcept {
            g_fault_calls.fetch_add(1);
        },
        {}, error);
}

// (1) A short SYNCHRONOUS completion must be continued: 3 + 4 + 3 = 10.
void test_sync_short_write_is_completed()
{
    reset_fake_state();
    const WriteStep script[] = {
        {WStep::kSyncOk, 3U, 0U},
        {WStep::kSyncOk, 4U, 0U},
        {WStep::kSyncOk, 3U, 0U},
    };
    set_script(script, 3);

    WinSerialBackend backend;
    std::int32_t error = 0;
    CHECK(open_backend(backend, error), "open a port against the fake Win32 layer");

    std::uint8_t buffer[10]{};
    for (int i = 0; i < 10; ++i) {
        buffer[i] = static_cast<std::uint8_t>(i + 1);
    }
    std::uint32_t written = 0U;
    std::int32_t write_error = 0;
    std::uint32_t line_status = 0U;

    CHECK(backend.write(buffer, 10U, 1000U, written, write_error, &line_status),
          "sync short writes are continued to completion");
    CHECK(written == 10U, "reported written count is the full size");
    CHECK(write_error == 0, "a completed transfer reports no error");
    CHECK(g_write_calls == 3, "three WriteFile calls (10, 7, 3)");
    CHECK(g_call_size[0] == 10U && g_call_size[1] == 7U && g_call_size[2] == 3U,
          "each retry requests exactly the unsent remainder");
    CHECK(g_call_ptr[1] == static_cast<const void*>(buffer + 3) &&
              g_call_ptr[2] == static_cast<const void*>(buffer + 7),
          "each retry resumes at the first unsent byte");

    backend.close();
}

// (2) A short OVERLAPPED completion must be continued: 3 + 7 = 10.
void test_overlapped_short_write_is_completed()
{
    reset_fake_state();
    const WriteStep script[] = {
        {WStep::kPendingOk, 3U, 0U},
        {WStep::kSyncOk, 7U, 0U},
    };
    set_script(script, 2);

    WinSerialBackend backend;
    std::int32_t error = 0;
    CHECK(open_backend(backend, error), "open a port against the fake Win32 layer");

    std::uint8_t buffer[10]{};
    std::uint32_t written = 0U;
    std::int32_t write_error = 0;
    std::uint32_t line_status = 0U;

    CHECK(backend.write(buffer, 10U, 1000U, written, write_error, &line_status),
          "an overlapped short write is continued to completion");
    CHECK(written == 10U, "reported written count is the full size");
    CHECK(write_error == 0, "a completed transfer reports no error");
    CHECK(g_write_calls == 2, "two WriteFile calls (10 pending-with-3, then 7)");
    CHECK(g_call_size[1] == 7U, "the retry requests the 7-byte remainder");
    CHECK(g_call_ptr[1] == static_cast<const void*>(buffer + 3),
          "the retry resumes at the first unsent byte");

    backend.close();
}

// (3) Partial transfer then a genuine driver error: the real error and the exact
//     byte count must both survive.
void test_partial_then_error_reports_count_and_cause()
{
    reset_fake_state();
    const WriteStep script[] = {
        {WStep::kPendingOk, 4U, 0U},
        {WStep::kSyncError, 0U, ERROR_DEVICE_REMOVED},
    };
    set_script(script, 2);

    WinSerialBackend backend;
    std::int32_t error = 0;
    CHECK(open_backend(backend, error), "open a port against the fake Win32 layer");

    std::uint8_t buffer[10]{};
    std::uint32_t written = 0U;
    std::int32_t write_error = 0;
    std::uint32_t line_status = 0U;

    CHECK(!backend.write(buffer, 10U, 1000U, written, write_error, &line_status),
          "a genuine error fails the write");
    CHECK(written == 4U, "the 4 bytes that reached the driver are reported");
    CHECK(write_error == ERROR_DEVICE_REMOVED,
          "the real Win32 cause is reported, not a forced WRITE_FAULT");
    CHECK(g_write_calls == 2, "the remainder was attempted once, then the error stopped it");

    backend.close();
}

// (4) A driver that makes no progress after a partial transfer must be bounded
//     and reported with the correct partial count - no spin.
void test_no_progress_is_bounded_with_partial_count()
{
    reset_fake_state();
    const WriteStep script[] = {
        {WStep::kPendingOk, 3U, 0U},
        {WStep::kPendingOk, 0U, 0U},
    };
    set_script(script, 2);

    WinSerialBackend backend;
    std::int32_t error = 0;
    CHECK(open_backend(backend, error), "open a port against the fake Win32 layer");

    std::uint8_t buffer[10]{};
    std::uint32_t written = 0U;
    std::int32_t write_error = 0;
    std::uint32_t line_status = 0U;

    CHECK(!backend.write(buffer, 10U, 1000U, written, write_error, &line_status),
          "a no-progress driver fails the write");
    CHECK(written == 3U, "the 3 bytes that reached the driver are reported");
    CHECK(write_error == ERROR_WRITE_FAULT, "no progress is a write fault");
    CHECK(g_write_calls == 2,
          "the loop stops after the zero-progress completion (no spin)");

    backend.close();
}

// (5) A zero-progress completion on the very first attempt is bounded too.
void test_zero_progress_from_start_is_bounded()
{
    reset_fake_state();
    const WriteStep script[] = {{WStep::kPendingOk, 0U, 0U}};
    set_script(script, 1);

    WinSerialBackend backend;
    std::int32_t error = 0;
    CHECK(open_backend(backend, error), "open a port against the fake Win32 layer");

    std::uint8_t buffer[10]{};
    std::uint32_t written = 0xFFFFFFFFU;
    std::int32_t write_error = 0;
    std::uint32_t line_status = 0U;

    CHECK(!backend.write(buffer, 10U, 1000U, written, write_error, &line_status),
          "a driver that accepts nothing fails the write");
    CHECK(written == 0U, "zero bytes written is reported as exactly zero");
    CHECK(write_error == ERROR_WRITE_FAULT, "no progress is a write fault");
    CHECK(g_write_calls == 1, "exactly one attempt, no retry spin");

    backend.close();
}

// (6) An overlapped completion that returns a transport error after a partial
//     transfer reports the partial count and the error.
void test_overlapped_error_after_partial_reports_count()
{
    reset_fake_state();
    const WriteStep script[] = {
        {WStep::kPendingOk, 5U, 0U},
        {WStep::kPendingError, 0U, ERROR_IO_DEVICE},
    };
    set_script(script, 2);

    WinSerialBackend backend;
    std::int32_t error = 0;
    CHECK(open_backend(backend, error), "open a port against the fake Win32 layer");

    std::uint8_t buffer[10]{};
    std::uint32_t written = 0U;
    std::int32_t write_error = 0;
    std::uint32_t line_status = 0U;

    CHECK(!backend.write(buffer, 10U, 1000U, written, write_error, &line_status),
          "an overlapped transport error fails the write");
    CHECK(written == 5U, "the 5 bytes that reached the driver are reported");
    CHECK(write_error == ERROR_IO_DEVICE, "the overlapped error cause is reported");
    CHECK(g_write_calls == 2, "the remainder was attempted once, then the error stopped it");

    backend.close();
}

}  // namespace

int main()
{
    test_sync_short_write_is_completed();
    test_overlapped_short_write_is_completed();
    test_partial_then_error_reports_count_and_cause();
    test_no_progress_is_bounded_with_partial_count();
    test_zero_progress_from_start_is_bounded();
    test_overlapped_error_after_partial_reports_count();

    if (g_failures != 0) {
        std::fprintf(stderr, "%d check(s) failed\n", g_failures);
        return 1;
    }
    std::printf("serial short-write tests PASS\n");
    return 0;
}
