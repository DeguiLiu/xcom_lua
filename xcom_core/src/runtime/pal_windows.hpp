// coact_windows_pal.hpp - Windows PAL for the coact runtime (xcom_core).
//
// Implements the full PalT contract declared in coact/pal.hpp on top of Win32
// primitives:
//   - auto-reset CreateEventW for the Dispatcher sleep/wake (wait_dispatcher /
//     signal_dispatcher_from_task/isr)
//   - QueryPerformanceCounter monotonic clock (monotonic_ns / clock_resolution_ns)
//   - _beginthreadex for the Dispatcher thread (start/join_dispatcher)
//   - thread_local dispatcher identity (in_dispatcher_thread),
//     interrupt masking is a documented no-op on a Windows host,
//     direct-dispatch depth tracking
//
// Iterrupt masking (irq_save / irq_restore) is a no-op: on an SMP host the
// shared EventPool must be bound to a real coact::SpinCriticalSection
// (make_spin_critical_section), NOT to make_critical_section(pal). See the P0
// spinlock note in xcom_core.cpp.
//
// SPDX-License-Identifier: MIT
#pragma once
#ifndef XCOM_COACT_WINDOWS_PAL_HPP_
#define XCOM_COACT_WINDOWS_PAL_HPP_

#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>
#include <processthreadsapi.h>

#include <cstdint>
#include <thread>

#include "coact/config.hpp"
#include "coact/pal.hpp"
#include "coact/queue.hpp"
#include "foundation/unique_handle.hpp"

namespace coact {
namespace pal {

// ---------------------------------------------------------------------------
// WakeEvent - a move-only, null-safe auto-reset Win32 event wrapper.
//
// Replaces the bare HANDLEs xcom_core held for its SessionWriter and
// RxCapacityWaiter rendezvous. CreateEventW runs in the constructor (failure
// leaves handle_ empty so valid() is false); SetEvent / WaitForSingleObject are
// both null-safe. Value-member friendly: copy is deleted, move is defaulted on
// top of the shared move-only UniqueHandle.
// ---------------------------------------------------------------------------
class WakeEvent {
public:
    WakeEvent();                       // CreateEventW auto-reset, null on failure
    ~WakeEvent();                      // CloseHandle
    WakeEvent(const WakeEvent&) = delete;
    WakeEvent& operator=(const WakeEvent&) = delete;
    WakeEvent(WakeEvent&&) noexcept = default;
    WakeEvent& operator=(WakeEvent&&) noexcept = default;

    bool valid() const noexcept;       // true iff the handle was created
    void signal() noexcept;            // SetEvent (null-safe)
    bool wait(uint32_t ms) noexcept;   // WaitForSingleObject; true == signaled

private:
    xcom::foundation::UniqueHandle handle_;
};

// The xcom_core implementation never calls register_current_task() with an
// invalid priority; keep the priority field in the TLS context.
struct WindowsContext {
    ContextKind kind = ContextKind::Task;
    uint8_t logical_prio = 0U;
    uint8_t direct_depth = 0U;
    bool prio_valid = false;
};

class Windows {
public:
    Windows() noexcept;
    ~Windows();   // releases wake_event_ (fixed pre-existing 1-handle/cycle leak)

    // Interrupt masking: no-op on a Windows SMP host. Tokens are opaque.
    CriticalToken irq_save() noexcept;
    void irq_restore(CriticalToken token) noexcept;

    // Register the calling thread's logical priority for the C2 admission
    // gate. Returns false for invalid priorities.
    bool register_current_task(LogicalPrio prio) noexcept;

    ExecutionContext current_context() const noexcept;

    // True only on the coact Dispatcher thread. Static so the Dispatcher can
    // bind it as a gate callback without an instance.
    static bool in_dispatcher_thread() noexcept;

    uint64_t monotonic_ns() const noexcept;
    uint64_t clock_resolution_ns() const noexcept;

    // No-op: Windows uses the default thread stack unless overridden by the
    // Dispatcher; kept so the Runtime can push Config::kDispatcherStackBytes
    // uniformly.
    void set_dispatcher_stack_bytes(uint32_t bytes) noexcept;

    // Block up to timeout_ms for a Dispatcher signal (0 = wait forever).
    void wait_dispatcher(uint32_t timeout_ms) noexcept;
    void signal_dispatcher_from_task() noexcept;
    // Non-blocking SetEvent (callers may be real callback/ISR threads).
    void signal_dispatcher_from_isr() noexcept;

    [[nodiscard]] bool start_dispatcher(ThreadEntry entry,
                                        void* context) noexcept;
    void join_dispatcher() noexcept;
    void watchdog_progress(uint32_t marker) noexcept;

    void enter_direct() noexcept;
    void leave_direct() noexcept;

    // Windows backend: bounded MPSC (same as every SMP host).
    template <typename T, uint16_t Cap>
    using QueueBackend = coact::BoundedMpscQueue<T, Cap>;

private:
    static unsigned int __stdcall dispatcher_entry(void* arg) noexcept;

    HANDLE wake_event_;
    HANDLE started_event_;
    bool thread_valid_;
    std::thread dispatcher_thread_;
    ThreadEntry user_entry_;
    void* user_ctx_;
    LARGE_INTEGER freq_;
    thread_local static WindowsContext tls_ctx_;
};

// ---------------------------------------------------------------------------
// Neutral wall-clock / sleep helpers (free functions). Keep Win32's GetTickCount
// / Sleep / ULONGLONG / DWORD out of the business layer: callers use a monotonic
// millisecond counter and a bounded sleep, both expressed in fixed-width C++
// types. Implemented in pal_windows.cpp on QueryPerformanceCounter.
// ---------------------------------------------------------------------------
// Monotonic millisecond counter (QPC-derived). Never decreases; suitable for
// deadline arithmetic. Returns 0 if the performance counter is unavailable.
uint64_t monotonic_ms() noexcept;

// Block the calling thread for at least `ms` milliseconds.
void sleep_ms(uint32_t ms) noexcept;

}  // namespace pal
}  // namespace coact

#endif /* XCOM_COACT_WINDOWS_PAL_HPP_ */
