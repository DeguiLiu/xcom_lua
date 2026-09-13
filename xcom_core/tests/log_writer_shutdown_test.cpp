// log_writer_shutdown_test.cpp - host regression for the bounded-shutdown
// cancellation and the accepted-batch loss ledger in LogWriter.
//
// Defect: the writer owns a dedicated std::thread that performs SYNCHRONOUS
// file I/O (WriteFile/FlushFileBuffers with lpOverlapped == nullptr). A worker
// parked inside one such call never observes the `stopping` flag (which is only
// re-checked BETWEEN calls), so LogWriter::shutdown's unconditional join could
// hold process teardown for as long as the disk/redirector/device takes. The
// fix cancels the worker's outstanding synchronous I/O
// (CancelSynchronousIo) immediately before the join; the call then returns
// ERROR_OPERATION_ABORTED, the worker reaches its loop head, sees `stopping`,
// drains and exits. Cancellation is best-effort by design - a driver that does
// not support it leaves the call parked and the join behaves exactly as before.
//
// A cancelled/aborted accepted log batch must not be a silent drop: finish()
// now charges the unwritten tail (size - offset) to metrics.save_rejected_bytes
// for Kind::Append, mirroring process_rx_ref's raw-RX tail account. This also
// closes the pre-existing hole where a stopped batch still in the queue
// (cancel_pending, offset == 0) was released with no ledger entry.
//
// This drives the real log_writer.cpp against a fake Win32 + coact-PAL layer
// (the same approach as serial_close_reap_test.cpp / line_apply_test.cpp), so
// both the control flow and the bookkeeping are the shipped code, not a copy.
//
// BUILD (Linux, from the repository root):
//   g++ -std=c++17 -Wall -Wextra -I tools/win32-stub -I xcom_core/include
//       -I xcom_core/src -I xcom_core/src/runtime -I xcom_core/src/io
//       -I xcom_core/src/foundation -I ../coact/include
//       xcom_core/tests/log_writer_shutdown_test.cpp
//       xcom_core/src/io/log_writer.cpp
//       xcom_core/src/foundation/unique_handle.cpp
//       -o /tmp/log_writer_shutdown_test -lpthread
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
#include <thread>
#include <vector>

#include "coact/pal_windows.hpp"

#include "log_writer.hpp"
#include "xcom_core.hpp"

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

// Auto-reset event table. CreateEventW hands out unique handles; the PAL's
// WakeEvent methods (defined below) are the only users.
std::mutex g_ev_mu;
std::condition_variable g_ev_cv;
HANDLE g_events[16]{};
bool g_event_signaled[16]{};
int g_event_count = 0;

int event_index(HANDLE handle)
{
    for (int i = 0; i < g_event_count; ++i) {
        if (g_events[i] == handle) {
            return i;
        }
    }
    return -1;
}

// Write orchestration.
enum { kWriteSucceed = 0, kWriteFail = 1, kWriteBlock = 2 };
std::atomic<int> g_write_mode{kWriteSucceed};
std::atomic<int> g_write_count{0};
std::atomic<int> g_cancel_calls{0};
std::mutex g_wr_mu;
std::condition_variable g_wr_cv;
bool g_write_entered = false;
bool g_cancelled = false;

constexpr auto kBlockSafety = std::chrono::seconds(3);

void reset_fake_state()
{
    g_last_error = 0U;
    g_write_mode.store(kWriteSucceed);
    g_write_count.store(0);
    g_cancel_calls.store(0);
    {
        std::lock_guard<std::mutex> lock(g_wr_mu);
        g_write_entered = false;
        g_cancelled = false;
    }
    {
        std::lock_guard<std::mutex> lock(g_ev_mu);
        for (int i = 0; i < g_event_count; ++i) {
            g_event_signaled[i] = false;
        }
    }
}

bool wait_write_entered()
{
    std::unique_lock<std::mutex> lock(g_wr_mu);
    return g_wr_cv.wait_for(lock, std::chrono::seconds(2),
                            [] { return g_write_entered; });
}

std::uint64_t ms_since(std::chrono::steady_clock::time_point start)
{
    return static_cast<std::uint64_t>(
        std::chrono::duration_cast<std::chrono::milliseconds>(
            std::chrono::steady_clock::now() - start)
            .count());
}

}  // namespace

// ---- fake Win32 primitives the writer / PAL call ---------------------------

HANDLE WINAPI CreateFileW(const wchar_t*, DWORD, DWORD, SECURITY_ATTRIBUTES*,
                          DWORD, DWORD, HANDLE)
{
    return reinterpret_cast<HANDLE>(static_cast<LONG_PTR>(0x1000));
}

BOOL WINAPI SetFilePointerEx(HANDLE, LARGE_INTEGER, LARGE_INTEGER*, DWORD)
{
    return TRUE;
}

BOOL WINAPI FlushFileBuffers(HANDLE) { return TRUE; }
BOOL WINAPI MoveFileExW(const wchar_t*, const wchar_t*, DWORD) { return TRUE; }
BOOL WINAPI DeleteFileW(const wchar_t*) { return TRUE; }

BOOL WINAPI WriteFile(HANDLE, const void*, DWORD count, DWORD* written,
                      OVERLAPPED*)
{
    const int mode = g_write_mode.load();
    if (mode == kWriteSucceed) {
        if (written != nullptr) {
            *written = count;
        }
        g_write_count.fetch_add(1);
        return TRUE;
    }
    if (written != nullptr) {
        *written = 0U;
    }
    if (mode == kWriteFail) {
        SetLastError(ERROR_WRITE_FAULT);
        return FALSE;
    }
    // kWriteBlock: park like a wedged device until the shutdown cancellation
    // (or a safety timeout so a mutation that drops the cancel fails the timing
    // assertion instead of hanging the whole suite).
    {
        std::unique_lock<std::mutex> lock(g_wr_mu);
        g_write_entered = true;
        g_wr_cv.notify_all();
        g_wr_cv.wait_for(lock, kBlockSafety, [] { return g_cancelled; });
    }
    SetLastError(ERROR_OPERATION_ABORTED);
    return FALSE;
}

BOOL WINAPI CancelSynchronousIo(HANDLE)
{
    {
        std::lock_guard<std::mutex> lock(g_wr_mu);
        g_cancelled = true;
        g_cancel_calls.fetch_add(1);
        g_wr_cv.notify_all();
    }
    return TRUE;
}

HANDLE WINAPI CreateEventW(SECURITY_ATTRIBUTES*, BOOL, BOOL, const wchar_t*)
{
    std::lock_guard<std::mutex> lock(g_ev_mu);
    if (g_event_count >= 16) {
        return nullptr;
    }
    HANDLE handle =
        reinterpret_cast<HANDLE>(static_cast<LONG_PTR>(0x2000 + (g_event_count << 4)));
    g_events[g_event_count] = handle;
    g_event_signaled[g_event_count] = false;
    ++g_event_count;
    return handle;
}

BOOL WINAPI CloseHandle(HANDLE) { return TRUE; }

BOOL WINAPI SetEvent(HANDLE handle)
{
    std::lock_guard<std::mutex> lock(g_ev_mu);
    const int index = event_index(handle);
    if (index >= 0) {
        g_event_signaled[index] = true;
        g_ev_cv.notify_all();
    }
    return TRUE;
}

BOOL WINAPI ResetEvent(HANDLE handle)
{
    std::lock_guard<std::mutex> lock(g_ev_mu);
    const int index = event_index(handle);
    if (index >= 0) {
        g_event_signaled[index] = false;
    }
    return TRUE;
}

DWORD WINAPI WaitForSingleObject(HANDLE handle, DWORD timeout_ms)
{
    const bool forever = (timeout_ms == INFINITE) || (timeout_ms == 0U);
    std::unique_lock<std::mutex> lock(g_ev_mu);
    const int index = event_index(handle);
    if (index < 0) {
        return WAIT_OBJECT_0;
    }
    const auto ready = [index] { return g_event_signaled[index]; };
    if (forever) {
        g_ev_cv.wait(lock, ready);
    }
    else if (!g_ev_cv.wait_for(lock, std::chrono::milliseconds(timeout_ms),
                               ready)) {
        return WAIT_TIMEOUT;
    }
    g_event_signaled[index] = false;  // auto-reset
    return WAIT_OBJECT_0;
}

DWORD WINAPI GetLastError(void) { return g_last_error; }
void WINAPI SetLastError(DWORD error) { g_last_error = error; }
HANDLE WINAPI GetCurrentThread(void) { return nullptr; }
BOOL WINAPI SetThreadPriority(HANDLE, int) { return TRUE; }

int WINAPI MultiByteToWideChar(UINT, DWORD, const char* in, int in_size,
                               wchar_t* out, int out_size)
{
    if (in == nullptr) {
        return 0;
    }
    const int length = in_size < 0 ? static_cast<int>(std::strlen(in)) + 1
                                   : in_size;
    if (out_size == 0) {
        return length;
    }
    int copied = 0;
    while (copied < length && copied < out_size) {
        out[copied] = static_cast<wchar_t>(
            static_cast<unsigned char>(in[copied]));
        ++copied;
    }
    if (in_size < 0 && copied > 0 && copied >= length) {
        out[length - 1] = L'\0';
    }
    return copied;
}

// ---- fake coact PAL (only what log_writer.cpp references) ------------------

namespace coact {
namespace pal {

WakeEvent::WakeEvent() noexcept
    : handle_(CreateEventW(nullptr, FALSE, FALSE, nullptr))
{
}

WakeEvent::~WakeEvent() noexcept
{
    if (handle_ != nullptr) {
        CloseHandle(handle_);
    }
}

WakeEvent::WakeEvent(WakeEvent&& other) noexcept : handle_(other.handle_)
{
    other.handle_ = nullptr;
}

WakeEvent& WakeEvent::operator=(WakeEvent&& other) noexcept
{
    if (this != &other) {
        if (handle_ != nullptr) {
            CloseHandle(handle_);
        }
        handle_ = other.handle_;
        other.handle_ = nullptr;
    }
    return *this;
}

bool WakeEvent::valid() const noexcept { return handle_ != nullptr; }

void WakeEvent::signal() noexcept
{
    if (handle_ != nullptr) {
        SetEvent(handle_);
    }
}

bool WakeEvent::wait(uint32_t ms) noexcept
{
    return handle_ != nullptr &&
           WaitForSingleObject(handle_, ms) == WAIT_OBJECT_0;
}

std::uint64_t monotonic_ms() noexcept
{
    return static_cast<std::uint64_t>(
        std::chrono::duration_cast<std::chrono::milliseconds>(
            std::chrono::steady_clock::now().time_since_epoch())
            .count());
}

void sleep_ms(std::uint32_t ms) noexcept
{
    std::this_thread::sleep_for(std::chrono::milliseconds(ms));
}

}  // namespace pal
}  // namespace coact

// ---- tests -----------------------------------------------------------------

namespace {

using xcom::CoreCtx;
using xcom::LogWriter;

std::vector<std::uint8_t> payload(std::uint32_t size)
{
    std::vector<std::uint8_t> data(size);
    for (std::uint32_t i = 0; i < size; ++i) {
        data[i] = static_cast<std::uint8_t>(i & 0xFFU);
    }
    return data;
}

// The core defect: a worker parked in one synchronous WriteFile must not be
// able to hold shutdown. Cancellation frees it, and the aborted accepted batch
// is charged to the loss ledger.
void test_cancel_aborts_wedged_write_and_counts_loss()
{
    reset_fake_state();
    g_write_mode.store(kWriteBlock);

    CoreCtx* core = new CoreCtx{};
    const std::uint32_t size = 4096U;
    {
        LogWriter writer;
        CHECK(writer.start(core), "writer starts");
        CHECK(writer.open("C:\\tmp\\xcom.log", false) == XCOM_OK,
              "open succeeds against the fake layer");

        const std::vector<std::uint8_t> data = payload(size);
        CHECK(writer.append(data.data(), size) == XCOM_OK, "append accepted");
        CHECK(wait_write_entered(), "worker is parked inside WriteFile");

        const auto start = std::chrono::steady_clock::now();
        writer.shutdown(20U);
        const std::uint64_t elapsed = ms_since(start);

        CHECK(elapsed < 1500U,
              "shutdown returns promptly once the wedged write is cancelled");
        CHECK(g_cancel_calls.load() > 0,
              "shutdown cancelled the writer thread's synchronous I/O");
        CHECK(core->metrics.save_rejected_bytes.load() == size,
              "the aborted accepted batch is charged to save_rejected_bytes");
    }
    delete core;
}

// A queued accepted batch (never started, offset 0) that stop drops must also be
// charged, not silently released - this is the cancel_pending path.
void test_queued_batch_is_charged_when_stop_drops_it()
{
    reset_fake_state();
    g_write_mode.store(kWriteBlock);

    CoreCtx* core = new CoreCtx{};
    const std::uint32_t size = 2048U;
    {
        LogWriter writer;
        CHECK(writer.start(core), "writer starts");
        CHECK(writer.open("C:\\tmp\\xcom.log", false) == XCOM_OK,
              "open succeeds against the fake layer");

        const std::vector<std::uint8_t> data = payload(size);
        CHECK(writer.append(data.data(), size) == XCOM_OK,
              "first append parks the worker");
        CHECK(wait_write_entered(), "worker is parked inside WriteFile");
        CHECK(writer.append(data.data(), size) == XCOM_OK,
              "second append is accepted and queued behind the parked write");

        writer.shutdown(20U);

        CHECK(core->metrics.save_rejected_bytes.load() == 2U * size,
              "both the in-flight and the queued batch are charged");
    }
    delete core;
}

// A fully written batch must NOT be charged: the ledger only names real loss.
void test_successful_write_is_not_charged()
{
    reset_fake_state();

    CoreCtx* core = new CoreCtx{};
    const std::uint32_t size = 1024U;
    {
        LogWriter writer;
        CHECK(writer.start(core), "writer starts");
        CHECK(writer.open("C:\\tmp\\xcom.log", false) == XCOM_OK,
              "open succeeds against the fake layer");

        const std::vector<std::uint8_t> data = payload(size);
        CHECK(writer.append(data.data(), size) == XCOM_OK, "append accepted");
        for (int spin = 0; spin < 200 && g_write_count.load() == 0; ++spin) {
            std::this_thread::sleep_for(std::chrono::milliseconds(1));
        }
        CHECK(g_write_count.load() == 1, "the batch reached the file");

        writer.shutdown(20U);

        CHECK(core->metrics.save_rejected_bytes.load() == 0U,
              "a fully written batch is not charged as loss");
    }
    delete core;
}

}  // namespace

int main()
{
    test_cancel_aborts_wedged_write_and_counts_loss();
    test_queued_batch_is_charged_when_stop_drops_it();
    test_successful_write_is_not_charged();

    if (g_failures != 0) {
        std::fprintf(stderr, "%d check(s) failed\n", g_failures);
        return 1;
    }
    std::printf("log writer shutdown tests PASS\n");
    return 0;
}
