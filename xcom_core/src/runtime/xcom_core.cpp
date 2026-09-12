// xcom_core.cpp - xcom_core.dll runtime construction, AOs, block lanes and the
// Native serial-backend owner sink. The C ABI surface lives in xcom_abi.cpp.
// Runtime startup propagates the Windows PAL's explicit bool success result.
//
// P0 wake bridge landing: a separate SpscRing<RxDesc> is NOT enough to wake the
// coact Dispatcher (it only observes the three staging partitions). So the
// receive producer (real backend callback or xcom_test_inject_rx) pushes
// into the ready SpscRing, then arms the RxKickGate (0->1) and submits a single
// static coact Event{SIG_RX_KICK, pool_id=0} to ReceiveAo through the
// DispatchCoordinator. The Dispatcher wakes, ReceiveAo drains the ring on the
// Dispatcher thread, and runs the disarm->recheck->re-arm protocol.
//
// P0 spinlock landing: the shared control EventPool is HostSmpProfile; its
// alloc/reclaim/splice writes each free block's `next` OUTSIDE the head CAS and
// therefore races a concurrent alloc. It is initialized with a real
// coact::SpinCriticalSection (make_spin_critical_section), NOT the no-op
// make_critical_section(pal) — see pool.hpp / pal.hpp comments.
//
// SPDX-License-Identifier: MIT
#include "pal_windows.hpp"
#include "periodic_timer.hpp"
#include "foundation/static_object_slot.hpp"
#include "log_writer.hpp"
#include "xcom_ao.hpp"
#include "xcom_core.hpp"
#include "diagnostic.hpp"

#include "coact/coordinator.hpp"
#include "coact/event.hpp"
#include "coact/pool.hpp"
#include "coact/runtime.hpp"

#include <array>
#include <algorithm>
#include <cstdint>
#include <cstring>
#include <thread>

#include <xcom/xcom.h>

#include "xcom_abi_internal.hpp"
#include "serial_backend_win.hpp"

namespace xcom {

// Concrete coact AO typedefs.
using ReceiveAo = coact::Ao<RxCtx, coact::Hsm<RxCtx>, RxTraits>;
using SendAo = coact::Ao<SendCtx, coact::Hsm<SendCtx>, SendTraits>;
using AutoSendAo = coact::Ao<SendCtx, coact::Hsm<SendCtx>, AutoSendTraits>;
using SerialAo = coact::Ao<SerialCtx, coact::Hsm<SerialCtx>, SerialTraits>;
using DiagnosticAo = coact::Ao<DiagCtx, coact::Hsm<DiagCtx>, DiagTraits>;

// ---------------------------------------------------------------------------
// AO HSM state / transition tables.
// ---------------------------------------------------------------------------
constexpr std::array<coact::StateDef<RxCtx>, 1U> kRxStates{{
    {-1, nullptr, nullptr, "root", -1},                        // 0
}};
constexpr std::array<coact::TransitionDef<RxCtx>, 1U> kRxTransitions{{
    {0, to_signal(Signal::RxKick), 0, coact::TransitionKind::Internal, nullptr,
     [](RxCtx& c, const coact::Event& e) noexcept { xcom::rx_kick_action(c, e); }},
}};

constexpr std::array<coact::StateDef<SendCtx>, 1U> kSendStates{{
    {-1, nullptr, nullptr, "root", -1},                        // 0
}};
constexpr std::array<coact::TransitionDef<SendCtx>, 1U> kSendTransitions{{
    {0, to_signal(Signal::Send), 0, coact::TransitionKind::Internal, nullptr,
     [](SendCtx& c, const coact::Event& e) noexcept { xcom::send_user_action(c, e); }},
}};
constexpr std::array<coact::TransitionDef<SendCtx>, 2U> kAutoSendTransitions{{
    {0, to_signal(Signal::Autosend), 0, coact::TransitionKind::Internal, nullptr,
     [](SendCtx& c, const coact::Event& e) noexcept { xcom::send_autosend_action(c, e); }},
    {0, to_signal(Signal::AutosendConfig), 0,
     coact::TransitionKind::Internal, nullptr,
     [](SendCtx& c, const coact::Event& e) noexcept {
         xcom::autosend_config_action(c, e);
     }},
}};

constexpr std::array<coact::StateDef<DiagCtx>, 1U> kDiagStates{{
    {-1, nullptr, nullptr, "root", -1},                        // 0
}};
constexpr std::array<coact::TransitionDef<DiagCtx>, 1U> kDiagTransitions{{
    {0, to_signal(Signal::Diag), 0, coact::TransitionKind::Internal, nullptr,
     [](DiagCtx& c, const coact::Event& e) noexcept { xcom::diag_tick_action(c, e); }},
}};

constexpr std::array<coact::StateDef<SerialCtx>, 4U> kSerialStates{{
    {-1, nullptr, nullptr, "root", -1},                        // 0 root
    {0, nullptr, nullptr, "Closed", -1},                       // 1
    {0, nullptr, nullptr, "Open", -1},                         // 2
    {0, nullptr, nullptr, "Fault", -1},                        // 3
}};
constexpr std::array<coact::TransitionDef<SerialCtx>, 7U> kSerialTransitions{{
    {S_CLOSED, to_signal(Signal::Open), S_OPEN, coact::TransitionKind::External, nullptr,
     serial_do_open},
    {S_OPEN, to_signal(Signal::Close), S_CLOSED, coact::TransitionKind::External, nullptr,
     serial_do_close},
    {S_FAULT, to_signal(Signal::Close), S_CLOSED, coact::TransitionKind::External, nullptr,
     serial_do_close},
    {S_CLOSED, to_signal(Signal::Fault), S_FAULT, coact::TransitionKind::External, nullptr,
     serial_do_fault},
    {S_OPEN, to_signal(Signal::Fault), S_FAULT, coact::TransitionKind::External, nullptr,
     serial_do_fault},
    // Reopen straight from Fault. The ABI publishes FAULT and the UI offers
    // Open there, so without this the user's request reached a state with no
    // matching transition and was dropped silently — coact's dispatch() just
    // returns false and the caller, having already queued the event, had no
    // way to tell "accepted" from "discarded". That is the "clicked Open and
    // nothing happened" report. serial_do_open already tears the failed
    // session down through owner_open before configuring the new one, so
    // entering it from Fault is the same work the Close-then-Open pair did.
    {S_FAULT, to_signal(Signal::Open), S_OPEN, coact::TransitionKind::External, nullptr,
     serial_do_open},
    // Open while already Open: idempotent no-op. It exists only so the event
    // has somewhere to land — an event with no matching transition is dropped
    // by coact's dispatch() with a false return the caller cannot see, so a
    // double-click or a retried request vanished without a trace. It must NOT
    // re-run serial_do_open: that closes and reopens the port, clears the RX
    // sequencing state and advances the generation, which drops any traffic
    // already queued in the session (smoke_test pins exactly that: two queued
    // sends keep their distinct descriptor lengths only if the session is not
    // restarted underneath them). Internal kind means the action runs without
    // leaving and re-entering the state.
    {S_OPEN, to_signal(Signal::Open), S_OPEN, coact::TransitionKind::Internal, nullptr,
     nullptr},
}};

// ---------------------------------------------------------------------------
// CoreState owns the Windows PAL, the control EventPool (spin-guarded), the
// coact Runtime, the four AOs and the CoreCtx. Lives for one xcom_create/
// handle.
// ---------------------------------------------------------------------------
struct CoreState;
struct CoreCtx;
struct RxIngressProgress {
    RxIngressResult result = RxIngressResult::kAllAccepted;
    uint32_t accepted_bytes = 0U;
};
[[nodiscard]] static RxIngressProgress rx_ingress_progress(
    CoreCtx* core, const uint8_t* data, uint32_t size) noexcept;
RxIngressResult rx_ingress(CoreCtx* core, const uint8_t* data,
                           uint32_t size) noexcept;

// ---------------------------------------------------------------------------
// Exceptional-only backpressure rendezvous for the WinSerialBackend read
// thread. The normal callback -> RxIngress path stays lock-free; this wait is
// entered only after every fixed RxBlock is already owned downstream.
// ---------------------------------------------------------------------------
class RxCapacityWaiter final {
public:
    RxCapacityWaiter() noexcept = default;
    RxCapacityWaiter(const RxCapacityWaiter&) = delete;
    RxCapacityWaiter& operator=(const RxCapacityWaiter&) = delete;

    [[nodiscard]] bool valid() const noexcept { return wake_event_.valid(); }

    void resume() noexcept
    {
        wake_event_.signal();
    }

    bool wait(CoreCtx& core) noexcept
    {
        while (core.callback_admission.load(std::memory_order_acquire) != 0U &&
               !core.rx.has_free_block()) {
            if (core.callback_admission.load(std::memory_order_acquire) == 0U ||
                core.rx.has_free_block()) {
                break;
            }
            if (!wake_event_.wait(0U)) {
                return false;
            }
        }
        return core.callback_admission.load(std::memory_order_acquire) != 0U;
    }

private:
    coact::pal::WakeEvent wake_event_;
};

// ---------------------------------------------------------------------------
// SessionWriter - P0-1 (W-P0-A2): offload the (possibly blocking)
// WinSerialBackend::write from the coact Dispatcher onto a dedicated per-session
// thread. A slow port / a peer that never drains can otherwise stall the whole
// Dispatcher (ReceiveAo/SendAo/Diag) for seconds to minutes (a 4096 B write at
// 1200 baud blocks ~34 s).
//
// Ownership invariants (coact S1/S3 discipline, plan W-P0-A2):
//   - SPSC: the coact Dispatcher is the ONLY producer of write jobs; the
//     worker is the ONLY consumer. One Dispatcher serializes SendAo and
//     AutoSendAo submissions before they reach this ring.
//   - The worker is the single caller of WinSerialBackend::write, so write
//     single-producer), so the write-thread ownership contract holds.
//   - The TxBlock referenced by a job stays owned until the worker releases it
//     AFTER writeData returns, so a still-queued/being-written block is never
//     handed back to xcom_send.
//   - close() lifecycle: request_stop -> abortPendingWrite (interrupts an
//     in-flight writeData) -> join -> drain leftover jobs. After join returns
//     there is no in-flight write, satisfying "close returns => no pending Tx".
// ---------------------------------------------------------------------------
class SessionWriter {
public:
    struct Job {
        uint16_t block = 0U;
        uint16_t len = 0U;
        uint32_t gen = 0U;
        bool auto_send = false;
    };
    static constexpr uint32_t kMaxJobs = 256U;   // power of two (ring mask)

    SessionWriter() = default;
    ~SessionWriter()
    {
        stop_and_join();
    }
    SessionWriter(const SessionWriter&) = delete;
    SessionWriter& operator=(const SessionWriter&) = delete;

    bool active() const noexcept { return thread_.joinable(); }

    bool start(CoreCtx* core_) noexcept
    {
        if (thread_.joinable()) {
            return false;
        }
        core = core_;
        stop_.store(false, std::memory_order_release);
        write_.store(0U, std::memory_order_release);
        read_.store(0U, std::memory_order_release);
        try {
            thread_ = std::thread(&SessionWriter::run, this);
        }
        catch (...) {
            return false;
        }
        return true;
    }

    // Producer (Dispatcher) submit; bounded, never blocks. Returns false when
    // the ring is full (caller then releases the TxBlock + counts rejection).
    bool try_enqueue(const Job& j) noexcept
    {
        const uint32_t w = write_.load(std::memory_order_relaxed);
        const uint32_t r = read_.load(std::memory_order_acquire);
        if (w - r >= kMaxJobs) {
            return false;
        }
        jobs_[w & (kMaxJobs - 1U)] = j;
        write_.store(w + 1U, std::memory_order_release);
        wake_.signal();
        return true;
    }

    // Consumer; only the worker thread calls this.
    bool try_pop(Job& out) noexcept
    {
        const uint32_t w = write_.load(std::memory_order_acquire);
        const uint32_t r = read_.load(std::memory_order_relaxed);
        if (r >= w) {
            return false;
        }
        out = jobs_[r & (kMaxJobs - 1U)];
        read_.store(r + 1U, std::memory_order_release);
        return true;
    }

    bool stop_requested() const noexcept
    {
        return stop_.load(std::memory_order_acquire) != 0;
    }

    void request_stop() noexcept
    {
        stop_.store(true, std::memory_order_release);
        wake_.signal();
    }

    // Drains and releases any jobs that were queued but never executed. Called
    // by the Dispatcher (owner_close) after join, and by the worker on stop.
    void release_leftover_jobs(CoreCtx* c) noexcept
    {
        Job j;
        while (try_pop(j)) {
            c->tx.release(j.block);
            if (j.auto_send) {
                c->autosend_armed.store(0U, std::memory_order_release);
            }
            c->metrics.tx_rejected.fetch_add(1U, std::memory_order_relaxed);
        }
    }

    // Request stop, then join. Bounded: an in-flight writeData is either done,
    // timed out (write timeout), or interrupted via abortPendingWrite() (which
    // the caller issues first), so this join never hangs on a dead port.
    void stop_and_join() noexcept
    {
        request_stop();
        if (thread_.joinable()) {
            thread_.join();
            // Make the native thread state release explicit between serial
            // sessions. MSVC normally closes it in join(), but retaining the
            // joined std::thread object across repeated VIRTUAL open/close
            // cycles has leaked thread-associated kernel objects in practice.
            thread_ = std::thread{};
        }
        core = nullptr;
    }

private:
    static void run(SessionWriter* self) noexcept
    {
        // User writes may block on a slow peer, so they stay below the serial
        // read callback and coact Dispatcher while still draining promptly.
        static_cast<void>(SetThreadPriority(GetCurrentThread(),
                                            THREAD_PRIORITY_NORMAL));
        CoreCtx* core = self->core;
        if (core == nullptr) {
            return;
        }
        for (;;) {
            self->wake_.wait(1000);
            if (self->stop_requested()) {
                self->release_leftover_jobs(core);
                return;
            }
            Job j;
            while (self->try_pop(j)) {
                const uint32_t cur = core->generation.load(std::memory_order_acquire);
                int32_t result = XCOM_ERR_NOT_OPEN;
                if (j.gen == cur &&
                    core->port_state.load(std::memory_order_acquire) ==
                        XCOM_PORT_OPEN) {
                    if (core->sink.owner_write != nullptr) {
                        core->sink.owner_write(core, j.block, j.len, &result);
                    }
                    else {
                        core->metrics.tx_bytes.fetch_add(j.len,
                                                         std::memory_order_relaxed);
                        result = XCOM_OK;
                    }
                }
                // Release the TxBlock only after the real writeData consumed it
                // (writeData reads core->tx.block(j.block) inside owner_write).
                core->tx.release(j.block);
                if (j.auto_send) {
                    core->autosend_armed.store(0U, std::memory_order_release);
                }
                if (result != XCOM_OK && j.gen == cur) {
                    core->errors.push(result, 0, "serial write failed");
                    core->diag_emit(0U,
                                    static_cast<uint16_t>(DiagEvent::kWriteFail),
                                    static_cast<uint32_t>(result),
                                    core->generation.load(
                                        std::memory_order_relaxed), 0U, 0U);
                }
                if (self->stop_requested()) {
                    self->release_leftover_jobs(core);
                    return;
                }
            }
        }
    }

    CoreCtx* core = nullptr;
    std::atomic<bool> stop_{false};
    std::atomic<uint32_t> write_{0U};
    std::atomic<uint32_t> read_{0U};
    std::array<Job, kMaxJobs> jobs_{};
    coact::pal::WakeEvent wake_;
    std::thread thread_;
};

struct CoreState {
    coact::pal::Windows pal;
    coact::SpinCriticalSection ctl_spin;   // P0 spinlock for the control pool
    alignas(64) std::array<std::byte,
                           kCtlPoolCapacity * kCtlBlockSize> ctl_storage{};
    coact::EventPool<kCtlBlockSize, kCtlPoolCapacity, coact::HostSmpProfile>
        ctl_pool;

    coact::Runtime<XcomCoactConfig, coact::pal::Windows, coact::HostSmpProfile>
        runtime;

    ReceiveAo recv_ao;
    SendAo send_ao;
    AutoSendAo autosend_ao;
    SerialAo serial_ao;
    DiagnosticAo diag_ao;

    CoreCtx core;

    // The single static SIG_RX_KICK event (pool_id=0, never recycled).
    coact::Event static_rx_kick_evt{to_signal(Signal::RxKick), 0U, 1U};

    // Exceptional-only rendezvous used when the fixed Rx pool is full. It is
    // not a task queue: the backend read thread pauses until ReceiveAo returns
    // a block or shutdown wakes it.
    RxCapacityWaiter rx_capacity_waiter;

    // Per-session write worker that runs the potentially blocking Win32 write
    // off the Dispatcher. lifecycle: started in
    // sink_owner_open, stopped+joined in sink_owner_close.
    SessionWriter writer;

    // All file writes are isolated from Dispatcher/AO execution.
    LogWriter log_writer;

    // coact::diag diagnostic log writer (task #5). Optional: disabled unless the
    // logger starts. Producers push 24-byte records; the writer thread does FILE
    // I/O so a slow disk never blocks a receive callback.
    DiagnosticWriter diag_writer;

    // Coact-bound physical I/O adapter. It owns its Win32 handles and its one
    // read thread; SerialAo owns open/close state and SessionWriter owns writes.
    WinSerialBackend serial_backend;

    // Low-priority auto-send timer. It only posts coact control work.
    xcom::runtime::PeriodicTimer autosend_timer_;

    bool started = false;

    explicit CoreState() noexcept
        : runtime(pal),
          recv_ao(kRxStates.data(), static_cast<uint16_t>(kRxStates.size()),
                  kRxTransitions.data(),
                  static_cast<uint16_t>(kRxTransitions.size()),
                  0, 4),
          send_ao(kSendStates.data(), static_cast<uint16_t>(kSendStates.size()),
                  kSendTransitions.data(),
                  static_cast<uint16_t>(kSendTransitions.size()),
                  0, 4),
          autosend_ao(kSendStates.data(),
                      static_cast<uint16_t>(kSendStates.size()),
                      kAutoSendTransitions.data(),
                      static_cast<uint16_t>(kAutoSendTransitions.size()),
                      0, 4),
          serial_ao(kSerialStates.data(),
                    static_cast<uint16_t>(kSerialStates.size()),
                    kSerialTransitions.data(),
                    static_cast<uint16_t>(kSerialTransitions.size()),
                    S_CLOSED, 4),
          diag_ao(kDiagStates.data(), static_cast<uint16_t>(kDiagStates.size()),
                  kDiagTransitions.data(),
                  static_cast<uint16_t>(kDiagTransitions.size()),
                  0, 4)
    {
    }

    // Bind AOs with explicit target ids, wire contexts + sinks, init the spin
    // critical section on the control pool, and start the Dispatcher.
    bool boot() noexcept
    {
        if (!runtime.bind_at(coact::TargetId(kTargetSerial), serial_ao)) {
            return false;
        }
        if (!runtime.bind_at(coact::TargetId(kTargetReceive), recv_ao)) {
            return false;
        }
        if (!runtime.bind_at(coact::TargetId(kTargetSend), send_ao)) {
            return false;
        }
        if (!runtime.bind_at(coact::TargetId(kTargetAutoSend), autosend_ao)) {
            return false;
        }
        if (!runtime.bind_at(coact::TargetId(kTargetDiag), diag_ao)) {
            return false;
        }

        // Wire AO contexts to the shared core.
        core.sink.impl = this;
        core.sink.submit_rx_kick = &sink_submit_rx_kick;
        core.sink.submit_control = &sink_submit_control;
        core.sink.submit_write = &sink_submit_write;
        core.sink.submit_autosend_config = &sink_submit_autosend_config;
        core.sink.enqueue_write = &sink_enqueue_write;
        core.sink.owner_open = &sink_owner_open;
        core.sink.owner_close = &sink_owner_close;
        core.sink.owner_write = &sink_owner_write;
        core.sink.owner_resume_rx = &sink_owner_resume_rx;
        core.sink.owner_set_lines = &sink_owner_set_lines;
        core.sink.autosend_set = &sink_autosend_set;
        core.sink.log_open = &sink_log_open;
        core.sink.log_append = &sink_log_append;
        core.sink.log_flush = &sink_log_flush;
        core.sink.log_close = &sink_log_close;
        core.sink.file_submit_atomic = &sink_file_submit_atomic;
        core.sink.file_submit_atomic_borrowed = &sink_file_submit_atomic_borrowed;
        core.sink.file_stream_begin = &sink_file_stream_begin;
        core.sink.file_stream_append_borrowed = &sink_file_stream_append_borrowed;
        core.sink.file_stream_commit = &sink_file_stream_commit;
        core.sink.file_stream_abort = &sink_file_stream_abort;
        core.sink.file_take_completion = &sink_file_take_completion;
        core.sink.diag_emit = &sink_diag_emit;

        recv_ao.context().core = &core;
        send_ao.context().core = &core;
        autosend_ao.context().core = &core;
        serial_ao.context().core = &core;
        diag_ao.context().core = &core;

        if (!core.init() || !rx_capacity_waiter.valid()) {
            return false;
        }
        // Best-effort diag log (optional; failure is not fatal to the core).
        diag_writer.start(&core);

        // P0 spinlock: the HostSmpProfile control pool must be initialized with
        // a real serializing critical section.
        if (!ctl_pool.init(ctl_storage.data(), ctl_storage.size(),
                           coact::make_spin_critical_section(ctl_spin))) {
            return false;
        }

        // Enter each AO's initial HSM state.
        const coact::Event null_evt{0U, 0U, 1U};
        recv_ao.init(null_evt);
        send_ao.init(null_evt);
        autosend_ao.init(null_evt);
        serial_ao.init(null_evt);
        diag_ao.init(null_evt);

        if (!runtime.initialize()) {
            return false;
        }
        if (!runtime.start()) {
            return false;
        }
        started = true;
        return true;
    }

    void shutdown() noexcept
    {
        // 1. Stop the auto-send periodic timer so it can no longer submit while
        //    we tear down.
        autosend_set_impl(&core, 0u);
        autosend_timer_.stop();
        // 2. Stop the Dispatcher first so no AO action can touch the physical
        //    adapter while we close it below.
        if (started) {
            runtime.stop();
            started = false;
        }
        SendCtx& autosend_ctx = autosend_ao.context();
        if (autosend_ctx.autosend_block != 0xFFFFU) {
            core.tx.release(autosend_ctx.autosend_block);
            autosend_ctx.autosend_block = 0xFFFFU;
            autosend_ctx.autosend_length = 0U;
            autosend_ctx.autosend_interval_ms = 0U;
        }
        // Runtime::stop drains staged control events. Unregister the pool now,
        // before CoreState storage can be reused by a later xcom_create.
        ctl_pool.shutdown();
        // 2b. Abort the physical write before joining the sole write worker.
        serial_backend.abort_pending_write();
        writer.stop_and_join();
        writer.release_leftover_jobs(&core);
        log_writer.shutdown(2000U);
        // 3. Force-close the adapter. close() cancels and joins its read thread,
        // so no callback runs after it returns.
        core.callback_admission.store(0u, std::memory_order_release);
        rx_capacity_waiter.resume();
        serial_backend.close();
        // 3b. Stop the diag log writer (join its thread) before releasing the
        //     CoreCtx so no producer can push a record during teardown.
        diag_writer.shutdown();
        // 4. Finalize CoreCtx after the Dispatcher and all native workers stop.
        core.shutdown();
    }

    // ---- sinks (static members) ----------------------------------------

    static void sink_submit_rx_kick(CoreCtx* core) noexcept
    {
        CoreState* st = static_cast<CoreState*>(core->sink.impl);
        if (st == nullptr) {
            return;
        }
        // Non-blocking path for the producer thread; drains into the staging
        // High/critical partition where ReceiveAo picks it up. The High
        // critical reserve prevents ordinary writes from rejecting the single
        // static receive wake under load.
        st->runtime.coordinator().submit_from_task(
            coact::TargetId(kTargetReceive), &st->static_rx_kick_evt,
            coact::EventQos{true, false});
    }

    static bool sink_submit_control(CoreCtx* core, uint16_t signal,
                                    uint32_t word, bool critical) noexcept
    {
        CoreState* st = static_cast<CoreState*>(core->sink.impl);
        if (st == nullptr) {
            return false;
        }
        coact::Event* e = st->ctl_pool.alloc_with_margin(signal, 0U);
        if (e == nullptr) {
            return false;   // control pool exhausted
        }
        // NOTE: v1.2 §6 removes the shared pending_write_word slot. Control
        // events here carry only a signal; writes use sink_submit_write with an
        // owned typed TxDescriptor payload.

        coact::TargetId tgt;
        coact::EventQos qos;
        qos.critical = critical;
        qos.mergeable = false;
        switch (signal) {
        case to_signal(Signal::Open):
        case to_signal(Signal::Close):
        case to_signal(Signal::Fault):
            tgt = coact::TargetId(kTargetSerial);
            break;
        case to_signal(Signal::Autosend):
            tgt = coact::TargetId(kTargetAutoSend);
            break;
        case to_signal(Signal::Diag):
            tgt = coact::TargetId(kTargetDiag);
            break;
        default:
            coact::event_gc(e);
            return false;
        }
        const coact::SubmitResult res =
            st->runtime.coordinator().submit_from_task(tgt, e, qos);
        return res.disposition == coact::SubmitDisposition::Queued ||
               res.disposition == coact::SubmitDisposition::Direct;
    }

    // v1.2 §6: submit a SIG_SEND carrying its OWN typed TxDescriptor in the
    // pooled event payload. Every accepted Tx has a distinct descriptor, so a
    // queue-and-return second send cannot overwrite a still-queued first send.
    static bool sink_submit_write(CoreCtx* core,
                                  const TxDescriptor& desc) noexcept
    {
        CoreState* st = static_cast<CoreState*>(core->sink.impl);
        if (st == nullptr) {
            return false;
        }
        TxWriteLayout* lay = st->ctl_pool.alloc_typed<
            TxWriteLayout, TxDescriptor, alignof(TxDescriptor)>(
                to_signal(Signal::Send));
        if (lay == nullptr) {
            return false;   // control pool exhausted
        }
        // The event's OWN payload region holds a copy of the descriptor. No
        // cross-event shared slot is used.
        TxDescriptor* slot = reinterpret_cast<TxDescriptor*>(lay->payload);
        *slot = desc;   // trivially copyable

        const coact::EventQos qos{false, false};
        const coact::SubmitResult res =
            st->runtime.coordinator().submit_from_task(
                coact::TargetId(kTargetSend), &lay->event, qos);
        return res.disposition == coact::SubmitDisposition::Queued ||
               res.disposition == coact::SubmitDisposition::Direct;
    }

    static bool sink_submit_autosend_config(
        CoreCtx* core, const AutoTemplateDescriptor& desc) noexcept
    {
        CoreState* st = static_cast<CoreState*>(core->sink.impl);
        if (st == nullptr) {
            return false;
        }
        AutoTemplateLayout* const layout = st->ctl_pool.alloc_typed<
            AutoTemplateLayout, AutoTemplateDescriptor,
            alignof(AutoTemplateDescriptor)>(
                to_signal(Signal::AutosendConfig));
        if (layout == nullptr) {
            return false;
        }
        AutoTemplateDescriptor* const slot =
            reinterpret_cast<AutoTemplateDescriptor*>(layout->payload);
        *slot = desc;
        const coact::SubmitResult result =
            st->runtime.coordinator().submit_from_task(
                coact::TargetId(kTargetAutoSend), &layout->event,
                coact::EventQos{false, false});
        return result.disposition == coact::SubmitDisposition::Queued ||
               result.disposition == coact::SubmitDisposition::Direct;
    }

    // P0-1 (W-P0-A2): hand an accepted Tx to the session write worker. Called
    // on the Dispatcher. Returns true if the worker now owns the
    // block (it will release it after writeData); false if not handed over.
    static bool sink_enqueue_write(CoreCtx* core, uint16_t block, uint16_t len,
                                   uint32_t gen, bool auto_send) noexcept
    {
        if (core == nullptr) {
            return false;
        }
        CoreState* st = static_cast<CoreState*>(core->sink.impl);
        if (st == nullptr) {
            return false;
        }
        if (!st->writer.active()) {
            return false;
        }
        const SessionWriter::Job job{block, len, gen, auto_send};
        return st->writer.try_enqueue(job);
    }

    static void serial_read_callback(CoreCtx* core, const uint8_t* data,
                                     uint32_t size) noexcept
    {
        if (core == nullptr || data == nullptr || size == 0U) {
            return;
        }
        core->in_callback.fetch_add(1U, std::memory_order_acq_rel);
        struct CallbackExit final {
            CoreCtx& core;
            ~CallbackExit()
            {
                core.in_callback.fetch_sub(1U, std::memory_order_release);
            }
        } callback_exit{*core};

        if (core->callback_admission.load(std::memory_order_acquire) == 0U) {
            return;
        }
        CoreState* const state = static_cast<CoreState*>(core->sink.impl);
        if (state == nullptr) {
            return;
        }
        core->metrics.callback_count.fetch_add(1U, std::memory_order_relaxed);
        const uint8_t* cursor = data;
        uint32_t remaining = size;
        while (remaining != 0U) {
            const RxIngressProgress progress =
                rx_ingress_progress(core, cursor, remaining);
            cursor += progress.accepted_bytes;
            remaining -= progress.accepted_bytes;
            if (remaining == 0U) {
                return;
            }
            if (core->callback_admission.load(std::memory_order_acquire) == 0U ||
                core->port_state.load(std::memory_order_acquire) !=
                    XCOM_PORT_OPEN) {
                return;
            }

            // All fully committed blocks were published before this wait, so
            // ReceiveAo can return capacity while the serial backend keeps
            // the unaccepted tail in its read callback. Backpressure is now
            // expressed purely by withholding reads; RTS is not toggled here
            // because RTS/CTS flow control is driver-owned (HANDSHAKE) and
            // manual EscapeCommFunction calls would fight it.
            //
            // Edge-count the episode (0 -> 1): a rising count is the only
            // host-side early warning that the RX pool is under pressure, and
            // it is what precedes a driver-buffer CE_RXOVER when the stall
            // outlasts the driver's FIFO. Counted here, cleared in
            // rx_kick_action via the existing exchange(0).
            if (core->rx_backpressured.exchange(
                    1U, std::memory_order_acq_rel) == 0U) {
                core->metrics.rx_backpressure_events.fetch_add(
                    1U, std::memory_order_relaxed);
            }
            if (!state->rx_capacity_waiter.wait(*core)) {
                return;
            }
        }
    }

    static void serial_fault_callback(CoreCtx* core, int32_t error) noexcept
    {
        if (core == nullptr ||
            core->callback_admission.load(std::memory_order_acquire) == 0U) {
            return;
        }
        core->errors.push(error, 2U, "Win32 serial read fault");
        // Publish FAULT directly as well as via the coact event: if the control
        // pool is exhausted (submit_control rejected below) the signal never
        // reaches serial_do_fault and the published state would stay OPEN with
        // a dead handle, so every later send/status would lie. The store is
        // idempotent with the Dispatcher's own FAULT transition.
        if (!core->submit_control(to_signal(Signal::Fault), 0U, true)) {
            core->errors.push(XCOM_ERR_IO, 0U,
                              "coact fault signal rejected");
            core->port_state.store(XCOM_PORT_FAULT, std::memory_order_release);
        }
    }

    // ---- serial owner sinks (run on the SerialAo owner thread) ----------

    static void sink_owner_open(CoreCtx* core) noexcept
    {
        CoreState* const state = core != nullptr
            ? static_cast<CoreState*>(core->sink.impl) : nullptr;
        if (core == nullptr || state == nullptr) {
            return;
        }
        // Virtual port: there is no backend to open, so the session is up as
        // soon as this action runs. Publish that as success here because
        // serial_do_open judges the outcome by last_open_result, and
        // xcom_open_async pre-sets it to XCOM_ERR_IO — leaving it alone would
        // make every virtual-port open look like a failure.
        if (core->virtual_port) {
            core->last_open_result.store(XCOM_OK, std::memory_order_release);
            return;
        }
        if (!core->virtual_port) {
            const SerialPortOptions options{
                core->port_name.data(), core->cfg_baud, core->cfg_data_bits,
                core->cfg_stop_bits, core->cfg_parity, core->cfg_flow_control,
                core->cfg_dtr_enable != 0U, core->cfg_rts_enable != 0U};
            int32_t error = kSerialSuccess;
            if (!state->serial_backend.open(
                    options,
                    [core](const uint8_t* data, uint32_t size) noexcept {
                        serial_read_callback(core, data, size);
                    },
                    [core](int32_t fault) noexcept {
                        serial_fault_callback(core, fault);
                    },
                    [core](const SerialLineStatus& status) noexcept {
                        line_status_ingress(core, status.framing_errors,
                                            status.parity_errors,
                                            status.overrun_errors,
                                            status.break_events,
                                            status.hold_events);
                    }, error)) {
                core->errors.push(error != kSerialSuccess ? error : XCOM_ERR_IO,
                                  2U, "Win32 serial open failed");
                core->last_open_result.store(
                    error != kSerialSuccess ? error : XCOM_ERR_IO,
                    std::memory_order_release);
                core->port_state.store(XCOM_PORT_FAULT,
                                       std::memory_order_release);
                return;
            }
        }
        if (!state->writer.active() && !state->writer.start(core)) {
            state->serial_backend.close();
            core->errors.push(XCOM_ERR_IO, 0U, "serial writer start failed");
            core->last_open_result.store(XCOM_ERR_IO, std::memory_order_release);
            core->port_state.store(XCOM_PORT_FAULT, std::memory_order_release);
            return;
        }
        core->callback_admission.store(1U, std::memory_order_release);
        core->last_open_result.store(XCOM_OK, std::memory_order_release);
    }

    // Consecutive native-write failures that escalate the session to FAULT
    // (see sink_owner_write). Three strikes tolerates one transient timeout
    // without masking a genuinely dead port for more than a moment.
    static constexpr uint32_t kTxFailStreakLimit = 3U;

    // W-P0-A1: derive a bounded write wait (ms) from the configured baud rate so
    // a legitimately slow but working link is allowed to complete a full 4096 B
    // block, while a dead link / non-reading peer cannot hold the worker forever.
    // Formula: time to move kRxBlockBytes on an 8N1 link (~11 bits/byte rounded
    // up for start+stop) * 8x margin, clamped to [2000, 60000] ms.
    static uint32_t compute_write_timeout_ms(uint32_t baud) noexcept
    {
        const double bits_per_byte = 10.0;   // 8 data + start + stop (8N1)
        double ms = 0.0;
        if (baud > 0) {
            ms = (static_cast<double>(kRxBlockBytes) * bits_per_byte * 1000.0 /
                  static_cast<double>(baud)) *
                 8.0;
        }
        if (ms < 2000.0) {
            ms = 2000.0;
        }
        if (ms > 60000.0) {
            ms = 60000.0;
        }
        return static_cast<uint32_t>(ms);
    }

    static void sink_owner_close(CoreCtx* core) noexcept
    {
        CoreState* st = static_cast<CoreState*>(core->sink.impl);
        if (st != nullptr) {
            // Cancel synchronously before either virtual or physical close.
            // Otherwise a virtual session kept its timer queue alive after
            // close, and teardown could race an in-flight timer callback.
            st->autosend_set_impl(core, 0u);
        }
        // Close admission before cancelling I/O. The read bridge checks it
        // before taking an Rx block and the waiter observes it before retrying.
        core->callback_admission.store(0u, std::memory_order_release);
        if (st != nullptr) {
            st->rx_capacity_waiter.resume();
            st->serial_backend.abort_pending_write();
            if (st->writer.active()) {
                st->writer.stop_and_join();
                st->writer.release_leftover_jobs(core);
            }
            if (!core->virtual_port) {
                st->serial_backend.close();
            }
            if (core->in_callback.load(std::memory_order_acquire) != 0U) {
                core->errors.push(XCOM_ERR_IO, 2U,
                                  "Win32 backend close left read callback active");
            }
        }
        core->callback_admission.store(1U, std::memory_order_release);
    }

    static void sink_owner_write(CoreCtx* core, uint16_t block, uint16_t len,
                                 int32_t* result) noexcept
    {
        if (result == nullptr) {
            return;
        }
        *result = XCOM_ERR_IO;
        if (core == nullptr) {
            return;
        }
        if (core->virtual_port) {
            core->metrics.tx_bytes.fetch_add(len, std::memory_order_relaxed);
            *result = XCOM_OK;
            return;
        }
        CoreState* const state = static_cast<CoreState*>(core->sink.impl);
        if (state == nullptr || !state->serial_backend.is_open()) {
            *result = XCOM_ERR_NOT_OPEN;
            return;
        }
        uint32_t written = 0U;
        int32_t error = kSerialSuccess;
        // Gap B: on a timeout the backend samples COMSTAT flow-control holds
        // (CTS/DSR/XOFF) before cancelling, so a stalled send reports its cause
        // instead of a bare "timeout".
        uint32_t line_status = 0U;
        if (!state->serial_backend.write(core->tx.block(block), len,
                                         compute_write_timeout_ms(core->cfg_baud),
                                         written, error, &line_status)) {
            core->errors.push(error != kSerialSuccess ? error : XCOM_ERR_IO,
                              2U, describe_write_failure(error, line_status));
            *result = XCOM_ERR_IO;
            // Escalate a dead port instead of leaving port_state OPEN while
            // every later send also fails against a stale handle:
            //   * a fatal device-removed / access-denied / invalid-handle error
            //     means the session is gone right now -> FAULT immediately;
            //   * anything else (timeout, transient write fault) only faults
            //     after a short run of consecutive failures, so one hiccup does
            //     not kill a working session.
            const uint32_t streak =
                core->tx_fail_streak.fetch_add(1U, std::memory_order_relaxed) + 1U;
            const bool fatal = error == ERROR_DEVICE_REMOVED ||
                               error == ERROR_ACCESS_DENIED ||
                               error == ERROR_INVALID_HANDLE ||
                               error == ERROR_OPERATION_ABORTED;
            if (fatal || streak >= kTxFailStreakLimit) {
                // Publish FAULT first so the status poller sees a dead session
                // even if the coact event is delayed or rejected; the event
                // still runs the owner_close/physical teardown path.
                core->port_state.store(XCOM_PORT_FAULT, std::memory_order_release);
                if (!core->submit_control(to_signal(Signal::Fault), 0U, true)) {
                    core->errors.push(XCOM_ERR_IO, 0U,
                                      "writer fault signal rejected");
                }
            }
            return;
        }
        core->tx_fail_streak.store(0U, std::memory_order_relaxed);
        core->metrics.tx_bytes.fetch_add(written, std::memory_order_relaxed);
        *result = XCOM_OK;
    }

    static void sink_owner_resume_rx(CoreCtx* core) noexcept
    {
        if (core == nullptr || core->virtual_port) {
            return;
        }
        CoreState* const state = static_cast<CoreState*>(core->sink.impl);
        if (state != nullptr) {
            // Reads resume; RTS is left to the driver's RTS/CTS handshake.
            state->rx_capacity_waiter.resume();
        }
    }

    // Live DTR/RTS hot switch. Called from the ABI thread (not the Dispatcher):
    // the backend only issues EscapeCommFunction, which is thread-safe on an
    // open handle, and set_rts() self-declines while RTS is flow-controlled.
    static bool sink_owner_set_lines(CoreCtx* core, bool dtr_asserted,
                                     bool rts_asserted) noexcept
    {
        if (core == nullptr || core->virtual_port) {
            return false;
        }
        CoreState* const state = static_cast<CoreState*>(core->sink.impl);
        if (state == nullptr || !state->serial_backend.is_open()) {
            return false;
        }
        state->serial_backend.set_dtr(dtr_asserted);
        state->serial_backend.set_rts(rts_asserted);
        return true;
    }

    // ---- auto-send periodic timer ---------------------------------------

    // The per-tick body, run on the dedicated low-priority timer thread via
    // PeriodicTimer's FixedFunction callback. Owns the auto-send CAS (the
    // platform layer never touches business atomics; it only forwards).
    static void autosend_tick(CoreCtx* core) noexcept
    {
        if (core == nullptr) {
            return;
        }
        // No auto-send unless a session is open. AutoSendAo is the sole
        // template reader and serializes replacement on the Dispatcher.
        if (core->port_state.load(std::memory_order_acquire) != XCOM_PORT_OPEN) {
            return;
        }
        // AutoTickGate (last-value-wins): arm the pending-tick flag 0->1. If a
        // tick is already pending (a previous SIG_AUTOSEND is queued/being
        // processed), coalesce this repeat tick and do not enqueue another.
        uint32_t expected = 0U;
        if (!core->autosend_armed.compare_exchange_strong(
                expected, 1U, std::memory_order_acq_rel,
                std::memory_order_relaxed)) {
            core->metrics.auto_tick_coalesced.fetch_add(
                1U, std::memory_order_relaxed);
            return;
        }
        if (!core->submit_control(to_signal(Signal::Autosend), 0U, false)) {
            // coact v1 has no merge cell. A rejected event must release the
            // local last-value-wins gate or later ticks would be suppressed.
            core->autosend_armed.store(0U, std::memory_order_release);
            core->metrics.tx_rejected.fetch_add(1U, std::memory_order_relaxed);
        }
    }

    static void sink_autosend_set(CoreCtx* core, uint32_t interval_ms) noexcept
    {
        CoreState* st = static_cast<CoreState*>(core->sink.impl);
        if (st != nullptr) {
            st->autosend_set_impl(core, interval_ms);
        }
    }

    static XcomStatus sink_log_open(CoreCtx* core, const char* path,
                                    bool append) noexcept
    {
        CoreState* st = static_cast<CoreState*>(core->sink.impl);
        return st != nullptr && st->log_writer.start(core)
                   ? st->log_writer.open(path, append)
                   : XCOM_ERR_IO;
    }

    static XcomStatus sink_log_append(CoreCtx* core, const uint8_t* data,
                                      uint32_t size) noexcept
    {
        CoreState* st = static_cast<CoreState*>(core->sink.impl);
        return st != nullptr ? st->log_writer.append(data, size) : XCOM_ERR_IO;
    }

    static XcomStatus sink_log_flush(CoreCtx* core, uint32_t timeout_ms) noexcept
    {
        CoreState* st = static_cast<CoreState*>(core->sink.impl);
        return st != nullptr ? st->log_writer.flush(timeout_ms) : XCOM_ERR_IO;
    }

    static XcomStatus sink_log_close(CoreCtx* core, uint32_t timeout_ms) noexcept
    {
        CoreState* st = static_cast<CoreState*>(core->sink.impl);
        return st != nullptr ? st->log_writer.close(timeout_ms) : XCOM_ERR_IO;
    }

    static XcomStatus sink_file_submit_atomic(CoreCtx* core, const char* path,
                                              const uint8_t* data, uint32_t size,
                                              uint64_t request_id) noexcept
    {
        CoreState* st = static_cast<CoreState*>(core->sink.impl);
        return st != nullptr
                   && st->log_writer.start(core)
                   ? st->log_writer.submit_atomic(path, data, size, request_id)
                   : XCOM_ERR_IO;
    }

    static XcomStatus sink_file_submit_atomic_borrowed(
        CoreCtx* core, const char* path, const uint8_t* data, uint32_t size,
        uint64_t request_id) noexcept
    {
        CoreState* st = static_cast<CoreState*>(core->sink.impl);
        return st != nullptr
                   && st->log_writer.start(core)
                   ? st->log_writer.submit_atomic_borrowed(path, data, size,
                                                           request_id)
                   : XCOM_ERR_IO;
    }

    static XcomStatus sink_file_stream_begin(CoreCtx* core, const char* path,
                                             uint64_t stream_id,
                                             uint64_t request_id) noexcept
    {
        CoreState* st = static_cast<CoreState*>(core->sink.impl);
        return st != nullptr
                   && st->log_writer.start(core)
                   ? st->log_writer.stream_begin(path, stream_id, request_id)
                   : XCOM_ERR_IO;
    }

    static XcomStatus sink_file_stream_append_borrowed(
        CoreCtx* core, uint64_t stream_id, const uint8_t* data, uint32_t size,
        uint64_t request_id) noexcept
    {
        CoreState* st = static_cast<CoreState*>(core->sink.impl);
        return st != nullptr ? st->log_writer.stream_append_borrowed(
                                 stream_id, data, size, request_id)
                           : XCOM_ERR_IO;
    }

    static XcomStatus sink_file_stream_commit(CoreCtx* core, uint64_t stream_id,
                                              uint64_t request_id) noexcept
    {
        CoreState* st = static_cast<CoreState*>(core->sink.impl);
        return st != nullptr ? st->log_writer.stream_commit(stream_id, request_id)
                           : XCOM_ERR_IO;
    }

    static XcomStatus sink_file_stream_abort(CoreCtx* core, uint64_t stream_id,
                                             uint64_t request_id) noexcept
    {
        CoreState* st = static_cast<CoreState*>(core->sink.impl);
        return st != nullptr ? st->log_writer.stream_abort(stream_id, request_id)
                           : XCOM_ERR_IO;
    }

    static XcomStatus sink_file_take_completion(CoreCtx* core,
                                                uint64_t* request_id,
                                                XcomStatus* status) noexcept
    {
        if (request_id == nullptr || status == nullptr) {
            return XCOM_ERR_PARAM;
        }
        CoreState* st = static_cast<CoreState*>(core->sink.impl);
        return st != nullptr ? st->log_writer.take_completion(*request_id, *status)
                             : XCOM_ERR_IO;
    }

    static void sink_diag_emit(CoreCtx* core, uint16_t source,
                               uint16_t event_id, uint32_t a0, uint32_t a1,
                               uint32_t a2, uint32_t a3) noexcept
    {
        CoreState* st = static_cast<CoreState*>(core->sink.impl);
        if (st != nullptr) {
            st->diag_writer.emit(static_cast<DiagEvent>(event_id), source, a0,
                                 a1, a2, a3);
        }
    }

    void autosend_set_impl(CoreCtx* core, uint32_t interval_ms) noexcept
    {
        // Passing 0 cancels the timer; otherwise (re)arm the periodic tick
        // with the auto-send CAS moved into the callback.
        if (interval_ms == 0u) {
            autosend_timer_.stop();
            return;
        }
        if (!autosend_timer_.start(interval_ms, [core]() noexcept {
                CoreState::autosend_tick(core);
            })) {
            core->errors.push(XCOM_ERR_IO, 0, "autosend timer create failed");
        }
    }
};

// ---------------------------------------------------------------------------
// RX ingress - shared by the real serial-backend callback and the injected
// test seam. Copies the borrowed buffer into owned RxBlockPool slots (one copy
// per <=4096 B segment), publishes RxDescriptors, then arms the kick gate and
// submits the static SIG_RX_KICK (P0 wake bridge).
// ---------------------------------------------------------------------------
RxIngressProgress rx_ingress_progress(CoreCtx* core, const uint8_t* data,
                                      uint32_t size) noexcept
{
    if (core == nullptr || data == nullptr || size == 0U) {
        return {RxIngressResult::kAllAccepted, size};
    }
    if (core->port_state.load(std::memory_order_acquire) != XCOM_PORT_OPEN) {
        return {RxIngressResult::kPartialAccepted, 0U};
    }

    // Accept the payload block-by-block. There is no up-front free-block
    // pre-check: a second producer can drain the free ring between a check and
    // the first acquire (TOCTOU). Each block is acquired individually; any
    // tail that cannot be committed is counted exactly (never the whole size).
    uint32_t remaining = size;
    const uint8_t* p = data;
    while (remaining > 0U) {
        uint16_t bid = 0U;
        uint8_t* dst = core->rx.try_acquire_block(bid);
        if (dst == nullptr) {
            break;
        }
        const uint32_t n =
            (remaining > kRxBlockBytes) ? kRxBlockBytes : remaining;
        std::memcpy(dst, p, n);
        RxDesc d;
        d.block = bid;
        d.len = static_cast<uint16_t>(n);
        d.seq = core->metrics.rx_seq.fetch_add(1U, std::memory_order_relaxed);
        d.gen = static_cast<uint16_t>(
            core->generation.load(std::memory_order_relaxed));
        if (!core->rx.push_ready(d)) {
            core->rx.release_block(bid);
            break;
        }
        core->metrics.rx_bytes.fetch_add(n, std::memory_order_relaxed);
        remaining -= n;
        p += n;
    }

    // Publish the static kick after every non-empty committed prefix, not only
    // after an all-or-nothing callback. The serial callback may be waiting for
    // capacity to accept its remaining bytes, and this is what frees it.
    const uint32_t accepted = size - remaining;
    if (accepted != 0U && core->kick_gate.try_arm()) {
        core->submit_rx_kick();
    }
    return {remaining == 0U ? RxIngressResult::kAllAccepted
                            : RxIngressResult::kPartialAccepted,
            accepted};
}

RxIngressResult rx_ingress(CoreCtx* core, const uint8_t* data,
                           uint32_t size) noexcept
{
    if (core == nullptr || data == nullptr || size == 0U) {
        return RxIngressResult::kAllAccepted;
    }
    core->metrics.callback_count.fetch_add(1U, std::memory_order_relaxed);
    const RxIngressProgress progress = rx_ingress_progress(core, data, size);
    if (progress.result == RxIngressResult::kPartialAccepted) {
        const uint32_t unaccepted = size - progress.accepted_bytes;
        core->metrics.rx_pool_exhausted_bytes.fetch_add(
            unaccepted, std::memory_order_relaxed);
        // Locate the gap: rx_bytes already includes this call's accepted
        // prefix, so this is the absolute accepted-byte offset at which the
        // dropped tail begins. Pool drops only occur on the injected path
        // (rx_ingress); the live serial callback waits for capacity instead.
        core->metrics.rx_loss_offset.store(
            core->metrics.rx_bytes.load(std::memory_order_relaxed),
            std::memory_order_relaxed);
        core->diag_emit(0U, static_cast<uint16_t>(DiagEvent::kRxDrop),
                        unaccepted,
                        core->metrics.rx_pool_exhausted_bytes.load(
                            std::memory_order_relaxed), 0U, 0U);
    }
    return progress.result;
}

void line_status_ingress(CoreCtx* core, uint32_t framing_errors,
                         uint32_t parity_errors, uint32_t overrun_errors,
                         uint32_t break_events, uint32_t hold_events) noexcept
{
    if (core == nullptr) {
        return;
    }
    // fetch_add returns the PREVIOUS value, so +delta is the new cumulative
    // total. A zero delta leaves the loaded value untouched.
    uint32_t f = core->metrics.framing_errors.load(std::memory_order_relaxed);
    uint32_t p = core->metrics.parity_errors.load(std::memory_order_relaxed);
    uint32_t o = core->metrics.overrun_errors.load(std::memory_order_relaxed);
    uint32_t b = core->metrics.break_events.load(std::memory_order_relaxed);
    if (framing_errors != 0U) {
        f = core->metrics.framing_errors.fetch_add(framing_errors,
                                                   std::memory_order_relaxed) +
            framing_errors;
    }
    if (parity_errors != 0U) {
        p = core->metrics.parity_errors.fetch_add(parity_errors,
                                                  std::memory_order_relaxed) +
            parity_errors;
    }
    if (overrun_errors != 0U) {
        o = core->metrics.overrun_errors.fetch_add(overrun_errors,
                                                   std::memory_order_relaxed) +
            overrun_errors;
        // Driver FIFO overflow: bytes were dropped inside the driver before we
        // could read them, so the exact count is unknowable and the event is
        // uncorrectable. Record the accepted-byte offset at observation time so
        // the UI can at least locate the episode in the received stream.
        core->metrics.rx_loss_offset.store(
            core->metrics.rx_bytes.load(std::memory_order_relaxed),
            std::memory_order_relaxed);
    }
    if (break_events != 0U) {
        b = core->metrics.break_events.fetch_add(break_events,
                                                 std::memory_order_relaxed) +
            break_events;
    }
    if (hold_events != 0U) {
        // Diagnostic-only metric: a flow-control hold is a throughput stall,
        // not data corruption, so it never triggers a diagnostic record.
        static_cast<void>(core->metrics.flow_hold_events.fetch_add(
            hold_events, std::memory_order_relaxed));
    }

    // Diagnose on the first hit of any error category and then only at
    // power-of-two milestones, so a sustained overrun/parity storm emits
    // O(log n) records instead of one per event. A dedicated kLineError record
    // (distinct from kRxDrop, which means WE dropped bytes on pool overflow)
    // keeps "the driver already lost these" separable in the diagnostic log
    // from "we lost these". a0 carries the combined cumulative count; the
    // per-category breakdown lives in XcomSnapshot.
    const auto milestone = [](uint32_t count) noexcept {
        return count != 0U && (count & (count - 1U)) == 0U;
    };
    if (milestone(f) || milestone(p) || milestone(o) || milestone(b)) {
        core->diag_emit(1U, static_cast<uint16_t>(DiagEvent::kLineError),
                        f + p + o + b, p, o, b);
    }
}

// ---------------------------------------------------------------------------
// Handle management (opaque).
//
// The process-owned static slots own both heavyweight CoreState and its opaque
// ABI token. Handle stores a reference, never an owning pointer; lifecycle is
// placement construction and deterministic return to the matching slot.
// ---------------------------------------------------------------------------
struct Handle {
    CoreState& state;
    uint32_t generation;
    uint32_t magic;
};

static constexpr uint32_t kHandleMagic = 0x58434F4DU;   // "XCOM"

foundation::StaticObjectSlot<CoreState>& core_state_slot() noexcept
{
    static foundation::StaticObjectSlot<CoreState> slot;
    return slot;
}

foundation::StaticObjectSlot<Handle>& handle_slot() noexcept
{
    static foundation::StaticObjectSlot<Handle> slot;
    return slot;
}

Handle* xcom_handle_create() noexcept
{
    CoreState* const state = core_state_slot().try_emplace();
    if (state == nullptr) {
        return nullptr;
    }
    Handle* const handle = handle_slot().try_emplace(Handle{*state, 0U,
                                                             kHandleMagic});
    if (handle == nullptr) {
        core_state_slot().destroy(*state);
        return nullptr;
    }
    return handle;
}

XcomStatus xcom_handle_boot(Handle* h) noexcept
{
    if (h == nullptr || h->magic != kHandleMagic) {
        return XCOM_ERR_PARAM;
    }
    return h->state.boot() ? XCOM_OK : XCOM_ERR_IO;
}

void xcom_handle_shutdown(Handle* h) noexcept
{
    if (h != nullptr && h->magic == kHandleMagic) {
        h->state.shutdown();
    }
}

void xcom_handle_destroy(Handle* h) noexcept
{
    if (h == nullptr || h->magic != kHandleMagic) {
        return;
    }
    CoreState& state = h->state;
    state.shutdown();
    h->magic = 0U;
    handle_slot().destroy(*h);
    core_state_slot().destroy(state);
}

CoreCtx* xcom_handle_core(Handle* h) noexcept
{
    if (h == nullptr || h->magic != kHandleMagic) {
        return nullptr;
    }
    return &h->state.core;
}

bool xcom_handle_valid(const void* p) noexcept
{
    // Do not read `p`: exported C callers can supply a stale or arbitrary
    // opaque handle. Equality against our sole occupied slot is sufficient to
    // establish that dereferencing it in the caller is safe.
    return p != nullptr &&
           handle_slot().contains(static_cast<const Handle*>(p));
}

// Native registry enumeration used by xcom_list_ports, implemented in the
// serial backend layer (Win32 registry types never reach this TU).
XcomStatus list_ports_impl(XcomPortInfo* out, std::uint32_t capacity,
                           std::uint32_t* count) noexcept
{
    if (count == nullptr || (capacity != 0U && out == nullptr)) {
        return XCOM_ERR_PARAM;
    }
    const std::uint32_t found = enumerate_serial_ports(out, capacity);
    *count = found;
    return found > capacity ? XCOM_ERR_FULL : XCOM_OK;
}

}  // namespace xcom
