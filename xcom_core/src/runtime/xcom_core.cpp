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
#include "coact/pal_windows.hpp"
#include "periodic_timer.hpp"
#include "foundation/static_object_slot.hpp"
#include "log_writer.hpp"
#include "xcom_ao.hpp"
#include "xcom_core.hpp"
#include "tx_submit_status.hpp"
#include "diagnostic.hpp"

#include "coact/coordinator.hpp"
#include "coact/event.hpp"
#include "coact/pool.hpp"
#include "coact/runtime.hpp"

#include <array>
#include <algorithm>
#include <chrono>
#include <cstdint>
#include <cstdio>
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

// SerialAo's lifecycle authority is SerialCtx::state (a full 5-state machine in
// xcom_ao.cpp driven by serial_transition()). The coact HSM here is reduced to
// a single root state whose Internal transitions only route the three lifecycle
// signals to the action wrappers; it deliberately owns NO port state, so there
// is exactly one authority. Keeping the signal routing (rather than calling the
// actions directly) preserves the control-pool backpressure/critical-reserve
// behaviour.
constexpr std::array<coact::StateDef<SerialCtx>, 1U> kSerialStates{{
    {-1, nullptr, nullptr, "root", -1},                        // 0
}};
constexpr std::array<coact::TransitionDef<SerialCtx>, 3U> kSerialTransitions{{
    {0, to_signal(Signal::Open), 0, coact::TransitionKind::Internal, nullptr,
     [](SerialCtx& c, const coact::Event& e) noexcept {
         xcom::serial_do_open(c, e);
     }},
    {0, to_signal(Signal::Close), 0, coact::TransitionKind::Internal, nullptr,
     [](SerialCtx& c, const coact::Event& e) noexcept {
         xcom::serial_do_close(c, e);
     }},
    {0, to_signal(Signal::Fault), 0, coact::TransitionKind::Internal, nullptr,
     [](SerialCtx& c, const coact::Event& e) noexcept {
         xcom::serial_do_fault(c, e);
     }},
}};

// ---------------------------------------------------------------------------
// CoreState owns the Windows PAL, the control EventPool (spin-guarded), the
// coact Runtime, the four AOs and the CoreCtx. Lives for one xcom_create/
// handle.
// ---------------------------------------------------------------------------
struct CoreState;
struct CoreCtx;
RxIngressResult rx_ingress(CoreCtx* core, const uint8_t* data,
                           uint32_t size) noexcept;

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

// ---------------------------------------------------------------------------
// Dispatcher liveness PAL adapter (design §4.2 item 3). coact's Dispatcher is
// templated on the PAL type and calls pal_.wait_dispatcher() on every blocking
// wait, so a thin derived PAL can timestamp the Dispatcher thread without
// modifying coact. wait_dispatcher is shadowed (not virtual): PalT is this
// concrete type, so the Dispatcher's non-virtual call binds here.
//
// Beat placement (design decision 2): mark parked for the duration of the wait
// so an INFINITE idle sleep is not read as a wedge, then beat on return - the
// thread has provably come back to its loop. The park start is also stamped so
// the observer can report a LONG park as a distinct informational signal; that
// signal cannot distinguish healthy idleness from a lost-wakeup hang, which is
// why the wait stays INFINITE and is deliberately not given a timeout sentinel
// (that would reintroduce the idle wakeups removed for CPU reasons). A
// sustained event stream may never park between batches, so xcom_ao.cpp also
// beats per dispatched action; the observer suspends evaluation while the port
// is OPENING/CLOSING/FAULT where a synchronous owner_open/close may
// legitimately block for seconds.
// ---------------------------------------------------------------------------
class ThreadBeatPal final : public coact::pal::Windows {
public:
    void set_dispatcher_beat(std::atomic<std::uint32_t>* beat_ms,
                             std::atomic<std::uint32_t>* parked,
                             std::atomic<std::uint32_t>* parked_since_ms) noexcept
    {
        dispatcher_beat_ms_ = beat_ms;
        dispatcher_parked_ = parked;
        dispatcher_parked_since_ = parked_since_ms;
    }

    void wait_dispatcher(std::uint32_t timeout_ms) noexcept
    {
        if (dispatcher_parked_since_ != nullptr) {
            dispatcher_parked_since_->store(
                static_cast<std::uint32_t>(coact::pal::monotonic_ms()),
                std::memory_order_relaxed);
        }
        if (dispatcher_parked_ != nullptr) {
            dispatcher_parked_->store(1U, std::memory_order_release);
        }
        coact::pal::Windows::wait_dispatcher(timeout_ms);
        // Order matters (design section 4.4 item 1): publish the fresh beat
        // BEFORE clearing `parked`, and clear it with release. The observer
        // acquire-loads `parked`; if it sees 0 it is then guaranteed to also
        // see the new beat, so it can never pair a cleared park with a stale
        // stamp and emit one spurious fault before the next real beat.
        if (dispatcher_beat_ms_ != nullptr) {
            dispatcher_beat_ms_->store(
                static_cast<std::uint32_t>(coact::pal::monotonic_ms()),
                std::memory_order_relaxed);
        }
        if (dispatcher_parked_ != nullptr) {
            dispatcher_parked_->store(0U, std::memory_order_release);
        }
        if (dispatcher_parked_since_ != nullptr) {
            dispatcher_parked_since_->store(0U, std::memory_order_relaxed);
        }
    }

private:
    std::atomic<std::uint32_t>* dispatcher_beat_ms_ = nullptr;
    std::atomic<std::uint32_t>* dispatcher_parked_ = nullptr;
    std::atomic<std::uint32_t>* dispatcher_parked_since_ = nullptr;
};

struct CoreState {
    ThreadBeatPal pal;
    coact::SpinCriticalSection ctl_spin;   // P0 spinlock for the control pool
    alignas(64) std::array<std::byte,
                           kCtlPoolCapacity * kCtlBlockSize> ctl_storage{};
    coact::EventPool<kCtlBlockSize, kCtlPoolCapacity, coact::HostSmpProfile>
        ctl_pool;

    coact::Runtime<XcomCoactConfig, ThreadBeatPal, coact::HostSmpProfile>
        runtime;

    ReceiveAo recv_ao;
    SendAo send_ao;
    AutoSendAo autosend_ao;
    SerialAo serial_ao;
    DiagnosticAo diag_ao;

    // Spinlock guarding the ref-counted RX block pool's free list. Declared
    // before `core` so it outlives the pool that binds it as its
    // CriticalSection ctx (see EventPool::init).
    coact::SpinCriticalSection rx_spin;

    CoreCtx core;

    // The single static SIG_RX_KICK event (pool_id=0, never recycled).
    coact::Event static_rx_kick_evt{to_signal(Signal::RxKick), 0U, 1U};

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
                    0, 4),
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

        // Liveness: point the PAL adapter at the Dispatcher's heartbeat slots
        // before the Dispatcher thread starts (design §4.2 item 3).
        pal.set_dispatcher_beat(&core.heartbeats.dispatcher_ms,
                                &core.heartbeats.dispatcher_parked,
                                &core.heartbeats.dispatcher_parked_since_ms);

        if (!core.init() ||
            !core.init_rx(coact::make_spin_critical_section(rx_spin))) {
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
        // Liveness gate: only now is the Dispatcher expected to beat. Before
        // this the observer must not read a missing beat as a wedge.
        core.heartbeats.dispatcher_running.store(1U,
                                                 std::memory_order_release);
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
        //    adapter while we close it below. Clear the liveness gate BEFORE
        //    the join: a stopped thread's stale stamp would otherwise read as a
        //    stall with no recovery once parked is cleared on its final return.
        if (started) {
            core.heartbeats.dispatcher_running.store(0U,
                                                     std::memory_order_release);
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
        // 2a. The Dispatcher is stopped, so ReceiveAo's deferred slot is no
        //     longer touched by anyone. Release the RX reference it retained
        //     across kicks, or that block would never return to the pool. An
        //     unlogged block (its source segment had no file lane) was popped
        //     off the display ring, so the close reset can no longer see it;
        //     release_deferred_rx charges its bytes to the loss ledger before
        //     the pool slot is returned. A file-backed block is left to the
        //     raw ring, so it is never charged here.
        {
            RxCtx& rx_ctx = recv_ao.context();
            core.release_deferred_rx(rx_ctx.deferred, rx_ctx.has_deferred);
        }
        // 2b. Abort the physical write before joining the sole write worker.
        serial_backend.abort_pending_write();
        writer.stop_and_join();
        writer.release_leftover_jobs(&core);
        // 3. Force-close the adapter. close() cancels and joins its read thread,
        // so no callback runs after it returns.
        core.callback_admission.store(0u, std::memory_order_release);
        core.rx.wake_blocked();
        serial_backend.close();
        // 3a. Only now, with the read thread joined and both ready rings
        //     quiescent, stop the log writer. Keeping it alive until here means
        //     every raw RX reference already accepted is still written by the
        //     Close drain (flush_rx_before_close) instead of being stranded.
        //     A stalled disk surfaces through rx_file_block_events / the error
        //     ring; anything the close could not persist is counted in
        //     save_rejected_bytes by process_rx_ref / drain_raw below.
        log_writer.shutdown(2000U);
        const uint32_t stranded_raw = core.rx.drain_raw();
        if (stranded_raw != 0U) {
            core.metrics.save_rejected_bytes.fetch_add(
                stranded_raw, std::memory_order_relaxed);
            core.errors.push(XCOM_ERR_IO, 0U,
                             "raw RX blocks stranded at shutdown (counted as loss)");
        }
        static_cast<void>(core.rx.drain_display());
        // 3b. Stop the diag log writer (join its thread) before releasing the
        //     CoreCtx so no producer can push a record during teardown.
        diag_writer.shutdown();
        // 4. Finalize CoreCtx after the Dispatcher and all native workers stop.
        core.shutdown();
    }

    // ---- sinks (static members) ----------------------------------------

    static bool sink_submit_rx_kick(CoreCtx* core) noexcept
    {
        CoreState* st = static_cast<CoreState*>(core->sink.impl);
        if (st == nullptr) {
            return false;
        }
        // Non-blocking path for the producer thread; drains into the staging
        // High/critical partition where ReceiveAo picks it up. The High critical
        // reserve only bounds ORDINARY High claims (kHighCapacity -
        // kHighCriticalReserve); critical High traffic is not bounded by it, so
        // a High ring filled with critical work still refuses this wake
        // (RejectedFull). A closed or saturated submission admission refuses it
        // too (RejectedState). Return the outcome so CoreCtx::submit_rx_kick()
        // can release the latch rather than leave it armed with no wake in
        // flight.
        const coact::SubmitResult res =
            st->runtime.coordinator().submit_from_task(
                coact::TargetId(kTargetReceive), &st->static_rx_kick_evt,
                coact::EventQos{true, false});
        return res.disposition == coact::SubmitDisposition::Queued ||
               res.disposition == coact::SubmitDisposition::Direct;
    }

    // `word` is part of the DispatchSink::submit_control function-pointer
    // contract (xcom_core.hpp) and is unfilled in v1.2 §6, so the parameter
    // stays but is explicitly unused here rather than changing the signature.
    static bool sink_submit_control(CoreCtx* core, uint16_t signal,
                                    [[maybe_unused]] uint32_t word,
                                    bool critical) noexcept
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
    // Returns XCOM_OK / XCOM_ERR_BUSY / XCOM_ERR_FULL so the ABI can report the
    // real reason instead of collapsing every refusal into "buffer full".
    static XcomStatus sink_submit_write(CoreCtx* core,
                                        const TxDescriptor& desc) noexcept
    {
        CoreState* st = static_cast<CoreState*>(core->sink.impl);
        if (st == nullptr) {
            return XCOM_ERR_NOT_OPEN;
        }
        TxWriteLayout* lay = st->ctl_pool.alloc_typed<
            TxWriteLayout, TxDescriptor, alignof(TxDescriptor)>(
                to_signal(Signal::Send));
        if (lay == nullptr) {
            return XCOM_ERR_FULL;   // control pool exhausted (capacity, not state)
        }
        // The event's OWN payload region holds a copy of the descriptor. No
        // cross-event shared slot is used.
        TxDescriptor* slot = reinterpret_cast<TxDescriptor*>(lay->payload);
        *slot = desc;   // trivially copyable

        const coact::EventQos qos{false, false};
        const coact::SubmitResult res =
            st->runtime.coordinator().submit_from_task(
                coact::TargetId(kTargetSend), &lay->event, qos);
        return tx_submit_status(res.disposition);
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

        if (core->callback_admission.load(std::memory_order_acquire) == 0U ||
            core->sink.impl == nullptr) {
            // Closing: sink_owner_close (line 932) and CoreState::shutdown (line
            // 592) zero admission BEFORE serial_backend.close() joins the read
            // thread, so a read that completed concurrently with the stop and is
            // now reaped and delivered by the backend (serial_backend_win.cpp
            // :655-663) arrives here with no owner. It cannot be ingested -
            // keeping admission open instead would let a reader blocked in
            // rx_ingress's file-lane wait hold close() open - so count it in the
            // loss ledger the UI shows rather than discard it silently. This is
            // the close-window half of the no-silent-loss rule.
            core->count_rejected_rx(size);
            core->diag_emit(0U, static_cast<uint16_t>(DiagEvent::kRxDrop), size,
                            core->metrics.save_rejected_bytes.load(
                                std::memory_order_relaxed),
                            0U, 0U);
            return;
        }
        // Single non-blocking ingress shared with the injected test seam:
        // accept what the RX pool can take, count any tail drop per lane, and
        // keep draining the driver FIFO. No capacity wait exists any more.
        static_cast<void>(rx_ingress(core, data, size));
    }

    static void serial_fault_callback(CoreCtx* core, int32_t error) noexcept
    {
        if (core == nullptr ||
            core->callback_admission.load(std::memory_order_acquire) == 0U) {
            return;
        }
        core->errors.push(error, 2U, "Win32 serial read fault");
        // The Fault signal is the normal route: serial_do_fault() runs
        // owner_close and publishes FAULT through serial_publish(). This
        // callback runs on the backend read thread, so it cannot call
        // serial_publish() (that mutates Dispatcher-owned SerialCtx::state).
        // If the control pool is exhausted and the signal is rejected, the AO
        // never runs. Publish FAULT directly as the only writer left (I1
        // exception, design §2.3; idempotent because it only ever writes FAULT)
        // so the view stops reporting a dead handle as OPEN, AND latch the fault
        // so SerialAo reconciles the state and releases the handle on its next
        // transition (CoreCtx::fault_pending). Calling owner_close here is NOT
        // an option: this runs on the backend read thread and owner_close joins
        // that same thread. Without the latch the local SerialCtx::state would
        // stay OPEN while port_state reads FAULT, so the next Open would find no
        // edge and silently time out.
        if (!core->submit_control(to_signal(Signal::Fault), 0U, true)) {
            core->errors.push(XCOM_ERR_IO, 0U,
                              "coact fault signal rejected");
            core->port_state.store(XCOM_PORT_FAULT, std::memory_order_release);
            core->fault_pending.store(1U, std::memory_order_release);
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
        // Liveness: the physical read thread stamps this slot once per loop
        // iteration. Seed it now so a reopen is never judged against a stale
        // stamp from the previous session; a null/virtual session never beats
        // and is excluded by the observer's port-state gate.
        core->heartbeats.serial_read_ms.store(
            static_cast<std::uint32_t>(coact::pal::monotonic_ms()),
            std::memory_order_relaxed);
        state->serial_backend.set_read_beat([core]() noexcept {
            core->heartbeats.serial_read_ms.store(
                static_cast<std::uint32_t>(coact::pal::monotonic_ms()),
                std::memory_order_relaxed);
        });
        // Virtual port: there is no backend to open, so the session is up as
        // soon as this action runs. Publish that as success here because
        // serial_do_open judges the outcome by last_open_result, and the open
        // path pre-sets it to XCOM_ERR_IO — leaving it alone would make every
        // virtual-port open look like a failure.
        //
        // This must NOT return early: the writer start and the callback
        // admission below are what make the session usable at all. Skipping
        // them left a virtual port "open" with no writer thread and callbacks
        // refused, so sends never reached tx_bytes and close(timeout=0) had
        // nothing in flight to time out on.
        if (core->virtual_port) {
            core->last_open_result.store(XCOM_OK, std::memory_order_release);
        }
        else {
            const SerialPortOptions options{
                core->port_name.data(), core->cfg_baud, core->cfg_data_bits,
                core->cfg_stop_bits, core->cfg_parity, core->cfg_flow_control,
                static_cast<LineDrive>(core->cfg_dtr_enable),
                static_cast<LineDrive>(core->cfg_rts_enable)};
            int32_t error = kSerialSuccess;
            // Advisory warning sink, wired BEFORE open() because configure() -
            // and therefore the DTR/RTS replay - runs inside it. A failed
            // pin replay leaves the DCB-programmed level in place, so it must
            // not fail the open; the user still has to learn that a target may
            // not have received its NRST/BOOT pulse. This lambda is non-fatal by
            // construction: it pushes the text into the error ring (source 1 =
            // serial backend) and does NOTHING else - no Signal::Fault, no
            // coact event, no fault_pending, and no last_open_result/port_state
            // write - so nothing downstream can read it as a fatal condition and
            // the OPENING -> OPEN edge below still happens.
            state->serial_backend.set_warning(
                [core](std::string_view message) noexcept {
                    core->errors.push(XCOM_ERR_IO, 1U, message);
                });
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
                // No direct port_state write: this runs inside the SerialAo's
                // kOwnerOpen action, and serial_do_open() observes the failed
                // last_open_result and drives the OPENING --OpenDone--> CLOSED
                // edge through serial_publish(). Storing a state here would
                // publish the same transition twice and from two points.
                return;
            }
        }
        if (!state->writer.active() && !state->writer.start(core)) {
            state->serial_backend.close();
            core->errors.push(XCOM_ERR_IO, 0U, "serial writer start failed");
            core->last_open_result.store(XCOM_ERR_IO, std::memory_order_release);
            // As above: serial_do_open() sees this failed result and publishes
            // CLOSED through serial_publish(); no store here.
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
            // Wake a reader blocked on the file-lane reserve so it re-checks
            // admission and exits. The deferred RX reference is safe to release
            // here: this sink runs on the Dispatcher, the same thread that owns
            // ReceiveAo's deferred slot. release_deferred_rx charges an unlogged
            // block (no file lane) to the loss ledger first, because it was
            // popped off the display ring and the close reset cannot see it; a
            // file-backed block stays owned by the raw ring and is not charged.
            core->rx.wake_blocked();
            RxCtx& rx_ctx = st->recv_ao.context();
            core->release_deferred_rx(rx_ctx.deferred, rx_ctx.has_deferred);
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
            // The backend stops at the first genuine failure but reports in
            // `written` exactly how many bytes reached the driver before it. A
            // short write is therefore NOT discarded: account the bytes the
            // device did receive and name the truncation, so a half frame is
            // visible rather than inferred from a bare "write failed".
            if (written != 0U) {
                core->metrics.tx_bytes.fetch_add(written,
                                                 std::memory_order_relaxed);
            }
            const char* const reason =
                describe_write_failure(error, line_status);
            if (written != 0U && written < len) {
                std::array<char, 160U> message{};
                std::snprintf(message.data(), message.size(),
                              "%s (truncated: %u of %u bytes sent)", reason,
                              static_cast<unsigned>(written),
                              static_cast<unsigned>(len));
                core->errors.push(error != kSerialSuccess ? error : XCOM_ERR_IO,
                                  2U, message.data());
            }
            else {
                core->errors.push(error != kSerialSuccess ? error : XCOM_ERR_IO,
                                  2U, reason);
            }
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
                // Route the fault through the AO: this callback runs on the
                // SessionWriter thread, so it cannot call serial_publish()
                // (Dispatcher-owned SerialCtx::state), but the Fault signal
                // does run serial_do_fault() -> owner_close + serial_publish().
                // Publish directly ONLY when even the critical-reserve signal
                // is rejected, since then the AO never runs; the store is an
                // I1 exception (design §2.3), idempotent (writes only FAULT).
                // Latch the fault too: this runs on the SessionWriter thread, so
                // owner_close cannot run here (it joins this thread), and the
                // local SerialCtx::state must be reconciled on the Dispatcher
                // before the next Open (CoreCtx::fault_pending).
                if (!core->submit_control(to_signal(Signal::Fault), 0U, true)) {
                    core->errors.push(XCOM_ERR_IO, 0U,
                                      "writer fault signal rejected");
                    core->port_state.store(XCOM_PORT_FAULT,
                                           std::memory_order_release);
                    core->fault_pending.store(1U, std::memory_order_release);
                }
            }
            return;
        }
        core->tx_fail_streak.store(0U, std::memory_order_relaxed);
        core->metrics.tx_bytes.fetch_add(written, std::memory_order_relaxed);
        *result = XCOM_OK;
    }

    // Live DTR/RTS hot switch. Called from the ABI thread (not the Dispatcher):
    // the backend only issues EscapeCommFunction, which is thread-safe on an
    // open handle. The result is reported per pin so a driver-owned RTS (under
    // RTS/CTS) and a failed Win32 call are distinct from an applied level - a
    // silent success on a pin that never moved is the defect this avoids.
    static XcomStatus sink_owner_set_lines(CoreCtx* core, bool dtr_asserted,
                                           bool rts_asserted) noexcept
    {
        if (core == nullptr || core->virtual_port) {
            return XCOM_ERR_NOT_OPEN;
        }
        CoreState* const state = static_cast<CoreState*>(core->sink.impl);
        if (state == nullptr || !state->serial_backend.is_open()) {
            return XCOM_ERR_NOT_OPEN;
        }
        XcomStatus result = XCOM_OK;
        switch (state->serial_backend.set_dtr(dtr_asserted)) {
        case LineApplyResult::Applied:
            break;
        case LineApplyResult::Failed:
            result = XCOM_ERR_IO;
            break;
        case LineApplyResult::Closed:
            result = XCOM_ERR_NOT_OPEN;
            break;
        default:
            // DTR is never flow-control owned; treat any future outcome as a
            // failed write rather than a silent success.
            result = XCOM_ERR_IO;
            break;
        }
        switch (state->serial_backend.set_rts(rts_asserted)) {
        case LineApplyResult::Applied:
            break;
        case LineApplyResult::DriverOwned:
            // RTS/CTS owns the pin: the requested level was NOT applied. Report
            // it only if nothing worse happened to DTR - a real DTR failure
            // (device gone) must outrank the routine RTS refusal, otherwise the
            // caller would lose a genuine fault.
            if (result == XCOM_OK) {
                result = XCOM_ERR_UNSUPPORTED;
            }
            break;
        case LineApplyResult::Failed:
            if (result == XCOM_OK) {
                result = XCOM_ERR_IO;
            }
            break;
        case LineApplyResult::Closed:
            if (result == XCOM_OK) {
                result = XCOM_ERR_NOT_OPEN;
            }
            break;
        default:
            if (result == XCOM_OK) {
                result = XCOM_ERR_IO;
            }
            break;
        }
        return result;
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
            // A rejected event must release the local last-value-wins gate or
            // later ticks would be suppressed. coact does ship a MergeCell and a
            // PolicyOps merge hook, but its submit pipeline drives no per-signal
            // merge registry (the coordinator leaves the merge hint
            // unimplemented), so coalescing has to stay local to this AO rather
            // than being handed to the framework.
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
        if (st == nullptr) {
            return XCOM_ERR_IO;
        }
        const XcomStatus status = st->log_writer.append(data, size);
        if (status == XCOM_ERR_FULL) {
            /* Logging was requested and the writer had no room, so these bytes
               never reach the file. Count them: the status return is the only
               signal and the drain path does not inspect it, so without this the
               capture would lose data silently while the snapshot still claimed
               a clean run. Deliberately not counted for a closed/unopened log,
               where nothing was asked to be persisted. */
            core->metrics.save_rejected_bytes.fetch_add(
                size, std::memory_order_relaxed);
        }
        return status;
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
// test seam. One copy per <=4096 B segment into a ref-counted block that is
// fanned out to the display lane and (when a log is open) the raw/file lane.
//
// Loss policy: the file lane is LOSSLESS. When it cannot claim a block the
// read thread BLOCKS on the lane wake and retries - visible as a storage stall
// (rx_file_block_events / rx_file_blocked_ms), never a drop. The display lane
// never blocks the reader: when it cannot take a segment (the file reserve
// must stay intact) those bytes are counted as DISPLAY BACKLOG
// (rx_pool_exhausted_bytes) and the reader continues; the file log keeps the
// authoritative complete stream. With NO log open there is no authoritative
// copy, so a segment the display cannot take is real loss and is counted in
// save_rejected_bytes (the ledger the UI shows as DATA LOSS), never as backlog.
// ---------------------------------------------------------------------------
RxIngressResult rx_ingress(CoreCtx* core, const uint8_t* data,
                           uint32_t size) noexcept
{
    if (core == nullptr || data == nullptr || size == 0U) {
        return RxIngressResult::kAllAccepted;
    }
    if (core->port_state.load(std::memory_order_acquire) != XCOM_PORT_OPEN) {
        // The read thread starts inside owner_open (serial_backend_win.cpp:224)
        // while the AO has already published OPENING, so a device that is
        // already transmitting can deliver a completed read before OPEN is
        // published; a late batch after a close lands here too. Neither has an
        // owner, and a silent return here was the open-path twin of the
        // close-window loss. Count it in the loss ledger the UI shows.
        core->count_rejected_rx(size);
        core->diag_emit(0U, static_cast<uint16_t>(DiagEvent::kRxDrop), size,
                        core->metrics.save_rejected_bytes.load(
                            std::memory_order_relaxed),
                        0U, 0U);
        return RxIngressResult::kPartialAccepted;
    }
    core->metrics.callback_count.fetch_add(1U, std::memory_order_relaxed);

    CoreState* const state = static_cast<CoreState*>(core->sink.impl);
    // Lease the file lane for the whole ingress. close() closes admission and
    // waits for every in-flight lease before it drains the raw ring and resets
    // the file, so a segment that sampled a file owner can never publish after
    // the final drain. A refused lease means close began: the segment has no
    // file owner, and any drop of it is counted as loss below.
    const bool file_lane =
        (state != nullptr) && state->log_writer.acquire_lease();

    uint32_t remaining = size;
    const uint8_t* p = data;
    uint32_t display_backlog = 0U;
    uint32_t unowned_drop = 0U;
    bool block_episode = false;
    std::chrono::steady_clock::time_point block_start{};

    while (remaining > 0U) {
        bool display_ok = false;
        coact::Event* const ev = core->rx.try_alloc(file_lane, display_ok);
        if (ev == nullptr) {
            if (file_lane) {
                // File-lane reserve exhausted: the disk has stalled for
                // seconds. Block until the writer releases a block; NEVER drop.
                if (!block_episode) {
                    block_episode = true;
                    block_start = std::chrono::steady_clock::now();
                    core->metrics.rx_file_block_events.fetch_add(
                        1U, std::memory_order_relaxed);
                    if (core->rx_backpressured.exchange(
                            1U, std::memory_order_acq_rel) == 0U) {
                        core->metrics.rx_backpressure_events.fetch_add(
                            1U, std::memory_order_relaxed);
                    }
                    core->errors.push(XCOM_ERR_IO, 0U,
                                      "storage stalled: RX file lane full");
                }
                if (core->callback_admission.load(std::memory_order_acquire) ==
                        0U ||
                    core->port_state.load(std::memory_order_acquire) !=
                        XCOM_PORT_OPEN) {
                    // Session closing: the tail has no owner. Count it too, so
                    // a close boundary never silently swallows accepted bytes.
                    unowned_drop += remaining;
                    break;
                }
                static_cast<void>(core->rx.wait_for_free(50U));
                continue;
            }
            // No log owner: there is no authoritative copy of these bytes, so
            // they are true loss, not display backlog. Count them in the loss
            // ledger the UI surfaces; rx_pool_exhausted_bytes stays reserved
            // for display backlog that a log still holds.
            unowned_drop += remaining;
            break;
        }

        const uint32_t n =
            (remaining > kRxBlockBytes) ? kRxBlockBytes : remaining;
        std::memcpy(core->rx.payload(ev), p, n);

        RxDesc ref;
        ref.event = ev;
        ref.len = static_cast<uint16_t>(n);
        ref.gen = static_cast<uint16_t>(
            core->generation.load(std::memory_order_relaxed));
        ref.ingress_ms =
            static_cast<uint32_t>(coact::pal::monotonic_ms());
        // rx_sequence stays the ABI's committed-block counter.
        static_cast<void>(
            core->metrics.rx_seq.fetch_add(1U, std::memory_order_relaxed));

        if (!core->rx.publish(ref, file_lane, display_ok)) {
            display_backlog += n;   // display skipped this segment
        }
        if (file_lane && state != nullptr) {
            state->log_writer.wake_rx();
        }
        core->metrics.rx_bytes.fetch_add(n, std::memory_order_relaxed);
        remaining -= n;
        p += n;
    }

    if (block_episode) {
        const auto elapsed =
            std::chrono::duration_cast<std::chrono::milliseconds>(
                std::chrono::steady_clock::now() - block_start)
                .count();
        core->metrics.rx_file_blocked_ms.fetch_add(
            static_cast<uint32_t>(elapsed), std::memory_order_relaxed);
    }

    const uint32_t accepted = size - remaining;
    if (display_backlog != 0U) {
        core->metrics.rx_pool_exhausted_bytes.fetch_add(
            display_backlog, std::memory_order_relaxed);
        // Locate the display gap in the accepted stream. This is display
        // backlog, not file loss: the raw lane still holds every byte.
        core->metrics.rx_loss_offset.store(
            core->metrics.rx_bytes.load(std::memory_order_relaxed),
            std::memory_order_relaxed);
        core->diag_emit(0U, static_cast<uint16_t>(DiagEvent::kRxDrop),
                        display_backlog,
                        core->metrics.rx_pool_exhausted_bytes.load(
                            std::memory_order_relaxed), 0U, 0U);
    }
    if (unowned_drop != 0U) {
        // No file and no display slot: these bytes are gone. Ledger them where
        // the UI already looks for loss so accepted != persisted is visible.
        core->count_rejected_rx(unowned_drop);
        core->diag_emit(0U, static_cast<uint16_t>(DiagEvent::kRxDrop),
                        unowned_drop,
                        core->metrics.save_rejected_bytes.load(
                            std::memory_order_relaxed), 0U, 0U);
    }
    if (accepted != 0U && core->kick_gate.try_arm()) {
        core->submit_rx_kick();
    }
    if (file_lane && state != nullptr) {
        // Every reference is on the raw ring before the lease drops, which is
        // what makes the Close drain see it.
        state->log_writer.release_lease();
    }
    return remaining == 0U ? RxIngressResult::kAllAccepted
                            : RxIngressResult::kPartialAccepted;
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

// ---------------------------------------------------------------------------
// Thread liveness observer (design §4.2 item 3). Runs on the existing 250 ms
// snapshot poll; it only REPORTS (one ErrorRing entry per fault episode and one
// per recovery) and never kills a thread or drops data (design §4.3).
// ---------------------------------------------------------------------------
namespace {

// `parked` also carries "not expected to run right now" (port closed, or the
// thread has not started); `running` is false once the thread has stopped, so a
// stale stamp is not read as an endless stall. The state is owned by the single
// snapshot-poll observer.
void report_thread_health(CoreCtx* core, const char* name,
                          LivenessState& state, std::uint32_t last_beat_ms,
                          std::uint32_t timeout_ms, bool running,
                          bool parked) noexcept
{
    state.last_beat_ms = last_beat_ms;
    const LivenessResult result = liveness_evaluate(
        state, static_cast<std::uint32_t>(coact::pal::monotonic_ms()),
        timeout_ms, running, parked);
    std::array<char, 256U> message{};
    if (result.edge == LivenessEdge::kFault) {
        std::snprintf(
            message.data(), message.size(),
            "thread stalled: %s no beat for %u ms (reported, not killed)",
            name, result.elapsed_ms);
        core->errors.push(XCOM_ERR_TIMEOUT, 0U, message.data());
    }
    else if (result.edge == LivenessEdge::kRecovery) {
        std::snprintf(message.data(), message.size(),
                      "thread recovered: %s beating again", name);
        core->errors.push(XCOM_OK, 0U, message.data());
    }
}

// Distinct from report_thread_health: a long park is NOT a stall. It is pushed
// with XCOM_OK (non-alarming) and worded so the operator can see "parked" and
// know this signal cannot tell healthy idleness from a lost-wakeup hang.
void report_dispatcher_park(CoreCtx* core, std::uint32_t parked_since_ms,
                            bool running) noexcept
{
    ParkWatchState& state = core->heartbeats.dispatcher_park_state;
    const LivenessResult result = liveness_evaluate_park(
        state, static_cast<std::uint32_t>(coact::pal::monotonic_ms()),
        parked_since_ms, kDispatcherParkedInfoMs, running);
    std::array<char, 256U> message{};
    if (result.edge == LivenessEdge::kFault) {
        std::snprintf(message.data(), message.size(),
                      "dispatcher parked %u ms: idle (healthy) or lost wakeup "
                      "- this signal cannot distinguish",
                      result.elapsed_ms);
        core->errors.push(XCOM_OK, 0U, message.data());
    }
    else if (result.edge == LivenessEdge::kRecovery) {
        core->errors.push(XCOM_OK, 0U,
                          "dispatcher left a long parked wait");
    }
}

}  // namespace

void check_thread_health(CoreCtx* core) noexcept
{
    if (core == nullptr) {
        return;
    }
    const uint16_t port_state =
        core->port_state.load(std::memory_order_relaxed);

    // Serial read: only while a physical read thread is expected to run. A
    // virtual session owns no read thread and a closed port's thread has exited,
    // so an absent beat is healthy there, not a wedge.
    const bool read_active =
        (port_state == XCOM_PORT_OPEN) && (!core->virtual_port);
    report_thread_health(
        core, "serial read", core->heartbeats.serial_read_state,
        core->heartbeats.serial_read_ms.load(std::memory_order_relaxed),
        kSerialReadBeatTimeoutMs, true, !read_active);

    // Dispatcher: a synchronous owner_open/owner_close may legitimately block
    // for seconds while the port is OPENING/CLOSING/FAULT (the ABI open caller
    // waits up to ~2 s), so suspend the check during a transition rather than
    // misreport a legitimate block as a wedge. The lifecycle gate suppresses
    // the stale stamp a stopped Dispatcher leaves behind.
    const bool dispatcher_running =
        (core->heartbeats.dispatcher_running.load(std::memory_order_acquire) != 0U);
    const bool dispatcher_transitioning =
        (port_state == XCOM_PORT_OPENING) ||
        (port_state == XCOM_PORT_CLOSING) ||
        (port_state == XCOM_PORT_FAULT);
    const bool dispatcher_parked =
        dispatcher_running &&
        (dispatcher_transitioning ||
         (core->heartbeats.dispatcher_parked.load(std::memory_order_acquire) != 0U));
    report_thread_health(
        core, "dispatcher", core->heartbeats.dispatcher_state,
        core->heartbeats.dispatcher_ms.load(std::memory_order_relaxed),
        kDispatcherBeatTimeoutMs, dispatcher_running, dispatcher_parked);

    // Parked-watch: a park is not a stall, so this is a separate informational
    // signal. Only a REAL wait-park is watched here (a transition park is a
    // synchronous action, already exempt above).
    const bool wait_parked =
        (core->heartbeats.dispatcher_parked.load(std::memory_order_acquire) != 0U);
    const std::uint32_t parked_since_ms = wait_parked
        ? core->heartbeats.dispatcher_parked_since_ms.load(std::memory_order_acquire)
        : 0U;
    report_dispatcher_park(core, parked_since_ms, dispatcher_running);

    // Log writer: its lifecycle gate is 0 until the writer thread starts and
    // after it has stopped, so a zero stamp is skipped and a stale one is not a
    // wedge. It parks around its INFINITE idle wake, so a merely-quiet writer
    // stays healthy. A writer retrying a dead disk keeps beating; the
    // storage-stall episode - not this check - reports that.
    const bool log_writer_running =
        (core->heartbeats.log_writer_running.load(std::memory_order_acquire) != 0U);
    report_thread_health(
        core, "log writer", core->heartbeats.log_writer_state,
        core->heartbeats.log_writer_ms.load(std::memory_order_relaxed),
        kLogWriterBeatTimeoutMs, log_writer_running,
        core->heartbeats.log_writer_parked.load(std::memory_order_acquire) != 0U);
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
