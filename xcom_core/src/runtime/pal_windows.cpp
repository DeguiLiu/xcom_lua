// coact_windows_pal.cpp - Windows PAL implementation for xcom_core.dll.
// SPDX-License-Identifier: MIT
#include "pal_windows.hpp"

#include <cstring>
#include <utility>   // std::move

namespace coact {
namespace pal {

thread_local WindowsContext Windows::tls_ctx_{};

Windows::Windows() noexcept
    : wake_event_(nullptr),
      started_event_(nullptr),
      thread_valid_(false),
      user_entry_(nullptr),
      user_ctx_(nullptr),
      freq_{}
{
    wake_event_ = CreateEventW(nullptr, FALSE /*auto-reset*/,
                               FALSE /*initially non-signaled*/, nullptr);
    started_event_ = CreateEventW(nullptr, FALSE /*auto-reset*/,
                                  FALSE /*initially non-signaled*/, nullptr);
    QueryPerformanceFrequency(&freq_);
}

// Release the Dispatcher wake event. Safe here: CoreState::shutdown() always
// runs pal.join_dispatcher() (via Runtime::stop()) before the CoreState member
// `pal` is destroyed, so no thread is blocked on or signaling wake_event_ now.
Windows::~Windows()
{
    join_dispatcher();
    if (wake_event_ != nullptr) {
        CloseHandle(wake_event_);
        wake_event_ = nullptr;
    }
    if (started_event_ != nullptr) {
        CloseHandle(started_event_);
        started_event_ = nullptr;
    }
}

CriticalToken Windows::irq_save() noexcept
{
    CriticalToken tok;
    tok.value = 0U;
    return tok;
}

void Windows::irq_restore(CriticalToken /*token*/) noexcept
{
    // no-op on Windows host
}

bool Windows::register_current_task(LogicalPrio prio) noexcept
{
    if (kInvalidPrio == prio || prio > kMaxPrio) {
        return false;
    }
    tls_ctx_.kind = ContextKind::Task;
    tls_ctx_.logical_prio = prio;
    tls_ctx_.prio_valid = true;
    tls_ctx_.direct_depth = 0U;
    return true;
}

ExecutionContext Windows::current_context() const noexcept
{
    ExecutionContext ec;
    ec.kind = tls_ctx_.kind;
    ec.logical_prio = tls_ctx_.logical_prio;
    ec.direct_depth = tls_ctx_.direct_depth;
    ec.prio_valid = tls_ctx_.prio_valid;
    return ec;
}

bool Windows::in_dispatcher_thread() noexcept
{
    return ContextKind::Dispatcher == tls_ctx_.kind;
}

uint64_t Windows::monotonic_ns() const noexcept
{
    LARGE_INTEGER c;
    QueryPerformanceCounter(&c);
    if (freq_.QuadPart <= 0) {
        return 0U;
    }
    return static_cast<uint64_t>(
        (static_cast<__int64>(c.QuadPart) * 1000000000LL) / freq_.QuadPart);
}

uint64_t Windows::clock_resolution_ns() const noexcept
{
    return 1000000ULL;   // 1 ms QPC practical resolution floor
}

void Windows::set_dispatcher_stack_bytes(uint32_t /*bytes*/) noexcept
{
    // Default thread stack is used.
}

void Windows::wait_dispatcher(uint32_t timeout_ms) noexcept
{
    DWORD ms = (timeout_ms == 0U) ? INFINITE : static_cast<DWORD>(timeout_ms);
    WaitForSingleObject(wake_event_, ms);
}

void Windows::signal_dispatcher_from_task() noexcept
{
    if (wake_event_ != nullptr) {
        SetEvent(wake_event_);
    }
}

// Non-blocking: safe for real callback/ISR producers. Uses SetEvent only.
void Windows::signal_dispatcher_from_isr() noexcept
{
    if (wake_event_ != nullptr) {
        SetEvent(wake_event_);
    }
}

unsigned int __stdcall Windows::dispatcher_entry(void* arg) noexcept
{
    Windows* self = static_cast<Windows*>(arg);
    tls_ctx_.kind = ContextKind::Dispatcher;
    tls_ctx_.logical_prio = 0U;
    tls_ctx_.prio_valid = false;
    tls_ctx_.direct_depth = 0U;
    // Dispatcher executes close/fault handling and the Rx wake consumer. Use
    // an above-normal host priority, deliberately not realtime.
    SetThreadPriority(GetCurrentThread(), THREAD_PRIORITY_ABOVE_NORMAL);
    if (self->started_event_ != nullptr) {
        SetEvent(self->started_event_);
    }
    self->user_entry_(self->user_ctx_);
    return 0U;
}

bool Windows::start_dispatcher(ThreadEntry entry, void* context) noexcept
{
    if (entry == nullptr || started_event_ == nullptr || thread_valid_) {
        return false;
    }
    user_entry_ = entry;
    user_ctx_ = context;
    try {
        dispatcher_thread_ = std::thread([](Windows* self) noexcept {
            static_cast<void>(Windows::dispatcher_entry(self));
        }, this);
        thread_valid_ = true;
        if (WaitForSingleObject(started_event_, 1000U) == WAIT_OBJECT_0) {
            return true;
        }
        join_dispatcher();
    }
    catch (...) {
        thread_valid_ = false;
    }
    return false;
}

void Windows::join_dispatcher() noexcept
{
    if (dispatcher_thread_.joinable()) {
        dispatcher_thread_.join();
    }
    thread_valid_ = false;
}

void Windows::watchdog_progress(uint32_t /*marker*/) noexcept
{
    // no-op
}

void Windows::enter_direct() noexcept
{
    ++tls_ctx_.direct_depth;
}

void Windows::leave_direct() noexcept
{
    if (tls_ctx_.direct_depth > 0U) {
        --tls_ctx_.direct_depth;
    }
}

// ---------------------------------------------------------------------------
// WakeEvent
// ---------------------------------------------------------------------------
WakeEvent::WakeEvent()
    : handle_(CreateEventW(nullptr, FALSE /*auto-reset*/,
                           FALSE /*initially non-signaled*/, nullptr))
{
}

WakeEvent::~WakeEvent() = default;

bool WakeEvent::valid() const noexcept
{
    return handle_.valid();
}

void WakeEvent::signal() noexcept
{
    if (handle_.valid()) {
        SetEvent(handle_.get());
    }
}

bool WakeEvent::wait(uint32_t ms) noexcept
{
    if (!handle_.valid()) {
        return false;
    }
    const DWORD native_ms = (ms == 0U) ? INFINITE : static_cast<DWORD>(ms);
    return WaitForSingleObject(handle_.get(), native_ms) == WAIT_OBJECT_0;
}

// ---------------------------------------------------------------------------
// Neutral wall-clock / sleep helpers (free functions).
// ---------------------------------------------------------------------------
uint64_t monotonic_ms() noexcept
{
    // QueryPerformanceFrequency is stable for the process lifetime; read it
    // once and cache in a function-local so callers need no instance state.
    static const LARGE_INTEGER freq = []() noexcept {
        LARGE_INTEGER f{};
        QueryPerformanceFrequency(&f);
        return f;
    }();
    LARGE_INTEGER c{};
    QueryPerformanceCounter(&c);
    if (freq.QuadPart <= 0) {
        return 0U;
    }
    // (count * 1000) / freq == milliseconds since the counter epoch.
    return static_cast<uint64_t>(
        (static_cast<__int64>(c.QuadPart) * 1000LL) / freq.QuadPart);
}

void sleep_ms(uint32_t ms) noexcept
{
    Sleep(static_cast<DWORD>(ms));
}

}  // namespace pal
}  // namespace coact
