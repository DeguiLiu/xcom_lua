// serial_close_reap_test.cpp - hardware-free regression for the close/read
// race in WinSerialBackend::read_loop().
//
// Defect (review P1-1): when a read IRP completes at the same moment teardown
// signals stop_event_, the read loop returned without calling
// GetOverlappedResult, so the bytes of a completed transfer were discarded.
// Two independent losses existed:
//   1. WaitForMultipleObjects(FALSE) reports the LOWEST signaled index, so a
//      stop that races a completion returns WAIT_OBJECT_0 (stop) even though
//      read_event_ is also set;
//   2. the loop also returned whenever stop_requested_ was merely observed set,
//      even when the READ event was the one that fired.
//
// This test drives the real WinSerialBackend against a fake Win32 layer (the
// same approach as line_apply_test.cpp) so both orderings are reproducible
// deterministically: the read thread parks in WaitForMultipleObjects, then the
// fake reports the race, and the test asserts the completed bytes reached
// on_read_ before the thread returned. It also covers the Defect-3
// classification: a probe CreateFileW that fails with ERROR_SHARING_VIOLATION
// (32) - not just ERROR_ACCESS_DENIED - must mark the port busy.
//
// BUILD (Linux, from the repository root):
//   g++ -std=c++17 -Wall -Wextra -I tools/win32-stub
//       -I xcom_core/include -I xcom_core/src -I xcom_core/src/io
//       -I xcom_core/src/foundation
//       xcom_core/tests/serial_close_reap_test.cpp
//       xcom_core/src/io/serial_backend_win.cpp
//       xcom_core/src/foundation/unique_handle.cpp
//       -o /tmp/serial_close_reap_test -lpthread
// (Add -ffunction-sections -Wl,--gc-sections, or supply the SetupAPI fakes
// below, so the unused enumeration path links. The fakes are supplied here, so
// a plain command links too.)
//
// SPDX-License-Identifier: MIT
#include <windows.h>

#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <mutex>

#include "setupapi.h"

#include "serial_backend_win.hpp"

// winerror.h names this canonical "device held by another process" status as
// 32; the Linux stub does not model it, so mirror the backend's fallback.
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

// ---- fake Win32 layer ------------------------------------------------------

DWORD g_last_error = 0U;
DCB g_dcb{};

// Event handles in CreateEventW creation order: the backend creates read_event_
// first, then write_event_, then stop_event_ (see open()).
HANDLE g_ev_read = nullptr;
HANDLE g_ev_write = nullptr;
HANDLE g_ev_stop = nullptr;
int g_event_seq = 0;

// Read-loop orchestration. g_mode selects the race the fake wait reports:
//   0 = stop and read signaled together  -> lowest index (stop) wins
//   1 = read completed first, stop_event_ not yet signaled -> read index wins
int g_mode = 0;
bool g_read_signaled = false;
bool g_stop_signaled = false;
bool g_in_wait = false;
std::mutex g_mu;
std::condition_variable g_cv;

constexpr DWORD kCompletionBytes = 2U;

// Callback capture.
std::atomic<int> g_read_calls{0};
std::atomic<DWORD> g_read_size{0U};
std::atomic<int> g_first_byte{0};
std::atomic<int> g_second_byte{0};
std::atomic<int> g_fault_calls{0};

// Enumeration control.
bool g_createfile_fails = false;
DWORD g_createfile_error = 0U;

void reset_fake_state()
{
    std::lock_guard<std::mutex> lock(g_mu);
    g_mode = 0;
    g_read_signaled = false;
    g_stop_signaled = false;
    g_in_wait = false;
    g_read_calls.store(0);
    g_read_size.store(0U);
    g_first_byte.store(0);
    g_second_byte.store(0);
    g_fault_calls.store(0);
    g_createfile_fails = false;
    g_createfile_error = 0U;
}

bool wait_for_read_park()
{
    std::unique_lock<std::mutex> lock(g_mu);
    return g_cv.wait_for(lock, std::chrono::seconds(2),
                         [] { return g_in_wait; });
}

}  // namespace

// ---- fake Win32 primitives the backend calls ------------------------------

HANDLE WINAPI CreateFileW(const wchar_t*, DWORD, DWORD, SECURITY_ATTRIBUTES*,
                          DWORD, DWORD, HANDLE)
{
    if (g_createfile_fails) {
        SetLastError(g_createfile_error);
        return INVALID_HANDLE_VALUE;
    }
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
    if (handle == g_ev_read) {
        std::lock_guard<std::mutex> lock(g_mu);
        g_read_signaled = true;
        g_cv.notify_all();
        return TRUE;
    }
    if (handle == g_ev_stop) {
        std::lock_guard<std::mutex> lock(g_mu);
        if (g_mode == 0) {
            // The completion and the stop are visible at the same instant.
            g_read_signaled = true;
            g_stop_signaled = true;
        }
        else {
            // Model the window in close(): stop_requested_ is already published
            // but SetEvent(stop_event_) has not made stop_event_ signaled yet.
            // Only the read event is set, so the wait must report the read.
            g_read_signaled = true;
        }
        g_cv.notify_all();
        return TRUE;
    }
    return TRUE;
}

BOOL WINAPI ResetEvent(HANDLE) { return TRUE; }

DWORD WINAPI WaitForSingleObject(HANDLE handle, DWORD)
{
    std::lock_guard<std::mutex> lock(g_mu);
    if (handle == g_ev_read) {
        return g_read_signaled ? WAIT_OBJECT_0 : WAIT_TIMEOUT;
    }
    return WAIT_OBJECT_0;
}

// The read thread's wait. It parks until the fake reports a completion or a
// stop, then reports the lowest signaled index - WAIT_OBJECT_0 (stop_event_) if
// stop is signaled, otherwise WAIT_OBJECT_0 + 1 (read_event_).
DWORD WINAPI WaitForMultipleObjects(DWORD, const HANDLE*, BOOL, DWORD)
{
    std::unique_lock<std::mutex> lock(g_mu);
    g_in_wait = true;
    g_cv.notify_all();
    g_cv.wait(lock, [] { return g_read_signaled || g_stop_signaled; });
    if (g_stop_signaled) {
        return WAIT_OBJECT_0;
    }
    return WAIT_OBJECT_0 + 1U;
}

// The pending read "writes" two known bytes into the caller's buffer; the
// completion below reports exactly that count, so the test can tell that the
// bytes delivered after teardown are this read's payload.
BOOL WINAPI ReadFile(HANDLE, void* buffer, DWORD, DWORD* received,
                     OVERLAPPED*)
{
    if (received != nullptr) {
        *received = 0U;
    }
    if (buffer != nullptr) {
        const std::uint8_t payload[kCompletionBytes] = {'A', 'B'};
        std::memcpy(buffer, payload, kCompletionBytes);
    }
    SetLastError(ERROR_IO_PENDING);
    return FALSE;
}

BOOL WINAPI GetOverlappedResult(HANDLE, OVERLAPPED*, DWORD* transferred, BOOL)
{
    if (transferred != nullptr) {
        *transferred = kCompletionBytes;
    }
    return TRUE;
}

BOOL WINAPI CancelIoEx(HANDLE, OVERLAPPED*) { return TRUE; }
BOOL WINAPI WriteFile(HANDLE, const void*, DWORD, DWORD* written, OVERLAPPED*)
{
    if (written != nullptr) {
        *written = 0U;
    }
    return TRUE;
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

// Registry fake: exactly one COM port, "COM7".
LSTATUS WINAPI RegOpenKeyExA(HKEY, const char*, DWORD, DWORD, HKEY* out)
{
    if (out != nullptr) {
        *out = reinterpret_cast<HKEY>(static_cast<LONG_PTR>(0x4000));
    }
    return ERROR_SUCCESS;
}

LSTATUS WINAPI RegEnumValueA(HKEY, DWORD index, char* name, DWORD* name_size,
                             DWORD*, DWORD* type, BYTE* data, DWORD* data_size)
{
    if (index != 0U) {
        return ERROR_NO_MORE_ITEMS;
    }
    const char* const description = "Fake USB Serial Device";
    const char* const port_name = "COM7";
    const DWORD name_length = static_cast<DWORD>(std::strlen(description));
    const DWORD port_length = static_cast<DWORD>(std::strlen(port_name));
    if (name != nullptr && name_size != nullptr && *name_size >= name_length) {
        std::memcpy(name, description, name_length);
        *name_size = name_length;
    }
    if (data != nullptr && data_size != nullptr && *data_size >= port_length) {
        std::memcpy(data, port_name, port_length);
        *data_size = port_length;
    }
    if (type != nullptr) {
        *type = REG_SZ;
    }
    return ERROR_SUCCESS;
}
LSTATUS WINAPI RegCloseKey(HKEY) { return ERROR_SUCCESS; }
LSTATUS WINAPI RegQueryValueExA(HKEY, const char*, DWORD*, DWORD*, BYTE*,
                                DWORD*)
{
    return ERROR_FILE_NOT_FOUND;
}

// SetupAPI fakes: no PnP device list, so the enumeration falls back to the
// registry-only path (which is enough to exercise the busy classification).
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

// Open once, with the capture callbacks, and leave the read thread parked.
bool open_with_capture(WinSerialBackend& backend, std::int32_t& error)
{
    return backend.open(
        base_options(),
        [](const std::uint8_t* data, std::uint32_t size) noexcept {
            g_read_calls.fetch_add(1);
            g_read_size.store(size);
            if (data != nullptr && size >= kCompletionBytes) {
                g_first_byte.store(data[0]);
                g_second_byte.store(data[1]);
            }
        },
        [](std::int32_t) noexcept { g_fault_calls.fetch_add(1); },
        {}, error);
}

// Both events signaled at once: WaitForMultipleObjects returns WAIT_OBJECT_0
// (stop) because it reports the lowest index. The completed read must still be
// reaped and delivered.
void test_completion_racing_stop_is_reaped()
{
    reset_fake_state();
    g_mode = 0;

    WinSerialBackend backend;
    std::int32_t error = 0;
    CHECK(open_with_capture(backend, error),
          "open a port against the fake Win32 layer");

    CHECK(wait_for_read_park(), "read thread parked in the wait");

    // close() publishes stop_requested_, then SetEvent(stop_event_); the fake
    // reports read_event_ and stop_event_ as simultaneously signaled.
    backend.close();

    CHECK(g_read_calls.load() == 1,
          "a completion racing stop is delivered exactly once (not dropped)");
    CHECK(g_read_size.load() == kCompletionBytes,
          "the delivered size is the completed transfer size");
    CHECK(g_first_byte.load() == 'A' && g_second_byte.load() == 'B',
          "the delivered bytes are the completed read's payload");
    CHECK(g_fault_calls.load() == 0,
          "a deliberate teardown is not reported as a device fault");
}

// Read event alone fires with stop_requested_ already published (the window in
// close() before SetEvent(stop_event_)). The read must be reaped, not skipped
// because stop_requested_ happened to be set.
void test_read_first_then_stop_is_reaped()
{
    reset_fake_state();
    g_mode = 1;

    WinSerialBackend backend;
    std::int32_t error = 0;
    CHECK(open_with_capture(backend, error),
          "open a port against the fake Win32 layer");

    CHECK(wait_for_read_park(), "read thread parked in the wait");

    backend.close();

    CHECK(g_read_calls.load() == 1,
          "a read that wins the wakeup is delivered exactly once (not dropped)");
    CHECK(g_read_size.load() == kCompletionBytes,
          "the delivered size is the completed transfer size");
    CHECK(g_first_byte.load() == 'A' && g_second_byte.load() == 'B',
          "the delivered bytes are the completed read's payload");
    CHECK(g_fault_calls.load() == 0,
          "a deliberate teardown is not reported as a device fault");
}

// Defect 3: a probe that fails with ERROR_SHARING_VIOLATION (32) must mark the
// port busy, exactly like ERROR_ACCESS_DENIED; an unrelated error must not.
void test_sharing_violation_marks_port_busy()
{
    reset_fake_state();
    g_createfile_fails = true;

    XcomPortInfo info[4]{};
    std::int32_t error = 0;

    g_createfile_error = ERROR_SHARING_VIOLATION;
    std::uint32_t count = xcom::enumerate_serial_ports_ex(info, 4U, true, error);
    CHECK(count == 1U, "the fake registry yields one port");
    CHECK(error == 0, "enumeration itself reports no error");
    CHECK(info[0].busy == 1U,
          "ERROR_SHARING_VIOLATION (32) marks the port busy");

    g_createfile_error = ERROR_ACCESS_DENIED;
    info[0] = XcomPortInfo{};
    count = xcom::enumerate_serial_ports_ex(info, 4U, true, error);
    CHECK(count == 1U && info[0].busy == 1U,
          "ERROR_ACCESS_DENIED still marks the port busy");

    g_createfile_error = ERROR_IO_DEVICE;
    info[0] = XcomPortInfo{};
    count = xcom::enumerate_serial_ports_ex(info, 4U, true, error);
    CHECK(count == 1U && info[0].busy == 0U,
          "an unrelated CreateFile failure does not mark the port busy");
}

}  // namespace

int main()
{
    test_completion_racing_stop_is_reaped();
    test_read_first_then_stop_is_reaped();
    test_sharing_violation_marks_port_busy();

    if (g_failures != 0) {
        std::fprintf(stderr, "%d check(s) failed\n", g_failures);
        return 1;
    }
    std::printf("serial close/reap tests PASS\n");
    return 0;
}
