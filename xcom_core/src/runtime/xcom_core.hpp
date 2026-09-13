// xcom_core.hpp - XCOM shared core context, block pools, rings, AOs.
//
// This header is the heartbeat of xcom_core:
//   - lock-free Rx/Tx block pools + SpscRings (receive + display data plane)
//   - the RxKickGate (P0 wake bridge: an empty->non-empty ready ring submits a
//     single static SIG_RX_KICK coact event to ReceiveAo)
//   - metrics, display handoff, error ring
//   - the four coact base-typed AOs (SerialAo / ReceiveAo / SendAo /
//     DiagnosticAo) declared via coact::Ao<Ctx, Hsm<Ctx>, Traits>
//
// Design notes honored (see docs/implementation-plan.md §5):
//   - Rx/Display blocks are fixed-slot ownership transfers; the hot path never
//     allocates coact events nor ref-counts Rx/Display blocks.
//   - ReceiveAo drains the ready ring on the Dispatcher with a
//     drain -> disarm gate -> acquire recheck -> CAS arm -> re-submit protocol.
//   - Send is last-value-wins per auto-send; manual send is a synchronous copy
//     into TxBlockPool (enforced by the ABI layer).
//
// SPDX-License-Identifier: MIT
#pragma once
#ifndef XCOM_CORE_HPP_
#define XCOM_CORE_HPP_

#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>

#include <atomic>
#include <algorithm>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <optional>
#include <string_view>
#include <utility>   // std::move

#include "xcom_config.hpp"
#include "thread_health.hpp"
#include "foundation/fixed_pool.hpp"
#include "foundation/rx_block_lane.hpp"
#include "foundation/text.hpp"
#include <xcom/xcom.h>   // XCOM_PORT_* / XcomStatus result constants
#include "coact/ao.hpp"
#include "coact/assert.hpp"
#include "coact/hsm.hpp"
#include "coact/pool.hpp"      // EventBlockLayout / alloc_typed
#include "coact/spsc_ring.hpp"

namespace xcom {

struct CoreCtx;  // forward

// A transmit descriptor carried in a typed control event's payload (v1.2 §6).
// It never copies the TxBlock payload; it only owns {block_id, length, session
// generation}. Trivially copyable so it satisfies EventPool::alloc_typed's
// payload contract. Unlike a bare shared 32-bit word, each accepted Tx has its
// OWN descriptor in its OWN pooled event, so a second xcom_send cannot
// overwrite a still-queued first send's descriptor (the pending_write_word bug).
struct TxDescriptor {
    uint16_t block = 0U;
    uint16_t length = 0U;
    uint32_t generation = 0U;
};
static_assert(sizeof(TxDescriptor) == 8U,
              "coact: TxDescriptor must be 8 bytes for loopback stability");
static_assert(alignof(TxDescriptor) <= alignof(std::max_align_t),
              "TxDescriptor must fit the EventPool's aligned block storage");

// Typed event-block layout carrying a TxDescriptor in the payload region.
struct TxCtlMeta {
    uint16_t pad = 0U;   // keeps the Meta member non-empty (MSVC-safe)
};
using TxWriteLayout = coact::EventBlockLayout<TxCtlMeta, sizeof(TxDescriptor),
                                              alignof(TxDescriptor)>;

struct AutoTemplateDescriptor {
    std::uint16_t block = 0xFFFFU;
    std::uint16_t length = 0U;
    std::uint32_t interval_ms = 0U;
};
static_assert(sizeof(AutoTemplateDescriptor) == 8U,
              "AutoTemplateDescriptor must remain one aligned control payload");
static_assert(alignof(AutoTemplateDescriptor) <= alignof(std::max_align_t),
              "AutoTemplateDescriptor must fit EventPool storage");

struct AutoTemplateCtlMeta {
    std::uint16_t pad = 0U;
};
using AutoTemplateLayout = coact::EventBlockLayout<
    AutoTemplateCtlMeta, sizeof(AutoTemplateDescriptor),
    alignof(AutoTemplateDescriptor)>;

// ---------------------------------------------------------------------------
// Dispatch sink: xcom_core.cpp (which owns the concrete coact Runtime) installs
// these function pointers so the non-template CoreCtx and the AOs can submit
// events without depending on the template runtime's exact type.
// ---------------------------------------------------------------------------
struct DispatchSink {
    // Submits the static SIG_RX_KICK event to ReceiveAo. Called from the
    // callback/inject thread; must not block. Returns true only when the wake
    // was accepted (queued or dispatched), false when the scheduler refused it.
    // A false return means NO wake is in flight, so the caller must release the
    // RxKickGate latch instead of leaving it armed forever.
    bool (*submit_rx_kick)(CoreCtx* core) = nullptr;
    // Submits a control event allocated from the control EventPool (owned
    // reference). Takes a signal and a 32-bit word. Consumes the pooled event
    // reference in all cases (releases it on rejection/drop).
    bool (*submit_control)(CoreCtx* core, uint16_t signal, uint32_t word,
                           bool critical) = nullptr;
    // v1.2 §6: submit a typed send event with an OWNED TxDescriptor payload
    // (alloc_typed), never a shared single slot. Consumes the pooled ref on all
    // paths (releases on rejection/drop). Returns XCOM_OK when the event was
    // queued or dispatched, XCOM_ERR_FULL for real capacity exhaustion, and
    // XCOM_ERR_BUSY when the scheduler refused it (overload breaker / state /
    // policy) - the caller must be able to tell those apart.
    XcomStatus (*submit_write)(CoreCtx* core, const TxDescriptor& desc) = nullptr;
    bool (*submit_autosend_config)(
        CoreCtx* core, const AutoTemplateDescriptor& desc) = nullptr;
    // P0-1 (W-P0-A2): hand an accepted Tx to the session write worker. Returns
    // true if the worker owns the block (it will release it after writeData);
    // false if it was NOT handed over (caller still owns and must release).
    bool (*enqueue_write)(CoreCtx* core, uint16_t block, uint16_t len,
                          uint32_t gen, bool auto_send) = nullptr;
    // Serial owner operations (run on the SerialAo owner thread). For a real
    // port these drive WinSerialBackend; for the virtual/test session they no-op.
    void (*owner_open)(CoreCtx* core) = nullptr;
    void (*owner_close)(CoreCtx* core) = nullptr;
    void (*owner_write)(CoreCtx* core, uint16_t block, uint16_t len,
                        int32_t* result) = nullptr;
    // v1.4: live modem-line hot switch. Applies DTR/RTS while the port is
    // open; bits are 1 = asserted, 0 = deasserted (same sense as
    // XcomPortConfig.dtr_enable/rts_enable). Safe to call from the ABI
    // thread; the backend only issues EscapeCommFunction. Returns XCOM_OK when
    // every requested level was applied, XCOM_ERR_UNSUPPORTED when the RTS half
    // was not applied because RTS/CTS handshake owns the pin (DTR is still
    // applied), XCOM_ERR_IO when a pin write failed, or XCOM_ERR_NOT_OPEN when
    // the session has no open physical port (virtual/test or CLOSED). Never
    // XCOM_OK for a pin that did not move.
    XcomStatus (*owner_set_lines)(CoreCtx* core, bool dtr_asserted,
                                  bool rts_asserted) = nullptr;
    // Arm/cancel the low-priority auto-send periodic timer (interval_ms==0
    // cancels). Runs only on the Dispatcher through AutoSendAo.
    void (*autosend_set)(CoreCtx* core, uint32_t interval_ms) = nullptr;
    XcomStatus (*log_open)(CoreCtx* core, const char* utf8_path,
                           bool append) = nullptr;
    XcomStatus (*log_append)(CoreCtx* core, const uint8_t* data,
                             uint32_t size) = nullptr;
    XcomStatus (*log_flush)(CoreCtx* core, uint32_t timeout_ms) = nullptr;
    XcomStatus (*log_close)(CoreCtx* core, uint32_t timeout_ms) = nullptr;
    XcomStatus (*file_submit_atomic)(CoreCtx* core, const char* utf8_path,
                                      const uint8_t* data, uint32_t size,
                                      uint64_t request_id) = nullptr;
    XcomStatus (*file_submit_atomic_borrowed)(
        CoreCtx* core, const char* utf8_path, const uint8_t* data,
        uint32_t size, uint64_t request_id) = nullptr;
    XcomStatus (*file_stream_begin)(CoreCtx* core, const char* utf8_path,
                                    uint64_t stream_id,
                                    uint64_t request_id) = nullptr;
    XcomStatus (*file_stream_append_borrowed)(
        CoreCtx* core, uint64_t stream_id, const uint8_t* data, uint32_t size,
        uint64_t request_id) = nullptr;
    XcomStatus (*file_stream_commit)(CoreCtx* core, uint64_t stream_id,
                                     uint64_t request_id) = nullptr;
    XcomStatus (*file_stream_abort)(CoreCtx* core, uint64_t stream_id,
                                    uint64_t request_id) = nullptr;
    XcomStatus (*file_take_completion)(CoreCtx* core, uint64_t* request_id,
                                       XcomStatus* status) = nullptr;
    // coact::diag diagnostic emit (task #5). Called from the Dispatcher AO
    // actions / sinks; non-blocking (pushes a 24-byte record + wake). event_id
    // is a logical DiagEvent; no-op if the writer is disabled.
    void (*diag_emit)(CoreCtx* core, uint16_t source, uint16_t event_id,
                      uint32_t a0, uint32_t a1, uint32_t a2,
                      uint32_t a3) = nullptr;
    void* impl = nullptr;  // reserved: owning CoreState on the runtime side
};

// ---------------------------------------------------------------------------
// RxKickGate (P0 wake bridge). atomic pending bit: 0 -> 1 is the only live
// state independently triggering a staged SIG_RX_KICK; a second callback while
// a kick is already staged does not re-submit (edge-triggered). ReceiveAo
// disarm()s when it has drained, then acquire-rechecks the ready ring.
// ---------------------------------------------------------------------------
class RxKickGate {
public:
    // Returns true exactly for the caller that performed the 0 -> 1 transition.
    [[nodiscard]] bool try_arm() noexcept
    {
        uint32_t expected = 0U;
        return pending_.compare_exchange_strong(
            expected, 1U, std::memory_order_acq_rel, std::memory_order_relaxed);
    }
    void disarm() noexcept { pending_.store(0U, std::memory_order_release); }
    [[nodiscard]] bool armed() const noexcept
    {
        return pending_.load(std::memory_order_acquire) != 0U;
    }

private:
    std::atomic<uint32_t> pending_{0U};
};

// ---------------------------------------------------------------------------
// Receive descriptor carried on the display handoff ring. It is the foundation
// lane's ref-counted descriptor (one owned reference to a pool RX block); the
// same type rides the raw/file ring, so both consumers hold the SAME block
// rather than two copies. See foundation/rx_block_lane.hpp for the ownership
// contract.
// ---------------------------------------------------------------------------
using RxDesc = foundation::RxBlockRef;

// ---------------------------------------------------------------------------
// Tx block pool: 32 x 4096 bytes, lock-free LIFO free list. xcom_send copies
// the payload in synchronously, then routes a descriptor to the Dispatcher.
// ---------------------------------------------------------------------------
class TxBlockPool {
public:
    void init() noexcept {}

    [[nodiscard]] uint8_t* try_alloc(uint16_t& out_id) noexcept
    {
        void* const block = blocks_.allocate();
        if (block == nullptr) {
            return nullptr;
        }
        out_id = static_cast<uint16_t>(blocks_.block_index(block));
        return static_cast<uint8_t*>(block);
    }

    void release(uint16_t id) noexcept
    {
        COACT_ASSERT(id < kTxBlockCount);
        blocks_.release(blocks_.block_ptr(id));
    }

    uint8_t* block(uint16_t id) noexcept
    {
        COACT_ASSERT(id < kTxBlockCount);
        return static_cast<uint8_t*>(blocks_.block_ptr(id));
    }

private:
    foundation::FixedPool<kTxBlockBytes, kTxBlockCount> blocks_;
};

// ---------------------------------------------------------------------------
// Display batch (<= 16 KiB UTF-8 text) owner-transfer ring. Producer is the
// Dispatcher/ReceiveAo and consumer is the ABI drain caller (the Lua UI
// thread). The public ABI polls this lane, so the hot receive path deliberately
// has no Win32 event signal or kernel transition per batch.
//
// Free-list invariant (fixes the former two-producer SPSC violation): the
// batch buffers are a tagged-CAS foundation::FixedPool, NOT an SpscRing. The
// Dispatcher returns a batch on the zero-byte path / a publish failure
// (xcom_ao.cpp) while the drain thread returns one when it finishes copying;
// both producers may run concurrently, and FixedPool's atomic CAS head makes
// concurrent release safe (no lost update, no double-issue, no stranded id).
// SpscRing was wrong here because its single-producer contract assumes exactly
// one releaser.
// ---------------------------------------------------------------------------
class DisplayLane {
public:
    [[nodiscard]] bool init() noexcept { return true; }

    [[nodiscard]] bool try_acquire(uint16_t& out_id, uint8_t*& out_buf) noexcept
    {
        void* const block = buffers_.allocate();
        if (block == nullptr) {
            return false;
        }
        out_id = static_cast<uint16_t>(buffers_.block_index(block));
        out_buf = static_cast<uint8_t*>(block);
        return true;
    }
    void release_buf(uint16_t id) noexcept
    {
        COACT_ASSERT(id < kDisplayBatchCount);
        buffers_.release(buffers_.block_ptr(id));
    }

    bool push_ready(uint16_t id, uint32_t len, uint32_t ingress_ms,
                    uint32_t generation) noexcept
    {
        DisplayDesc d{};
        d.buf = id;
        d.len = len;
        d.ingress_ms = ingress_ms;
        d.gen = generation;
        return ready_ring_.try_push(std::move(d));
    }
    // Return every batch still parked on the ready ring to the pool at a
    // session boundary. Without this the ring (capacity == pool capacity, 32)
    // strands every undrained id in the pool on close: a later try_acquire
    // returns false forever and the handle's display never works again; and the
    // next session's UI drains the previous session's bytes. Returns the count
    // drained so the caller keeps metrics.display_pending consistent.
    //
    // Threading: called on the Dispatcher from the SerialAo open/close commit.
    // The producer (ReceiveAo push_ready) is that same Dispatcher, so it is
    // serialised. The consumer (drain_into) is the single ABI caller thread
    // (xcom_abi.cpp:5: "Only ONE caller thread ... may call into this ABI"),
    // and at both commit points it is not inside drain_into: xcom_close /
    // xcom_open are synchronous and park that thread until CLOSED / OPEN, and
    // the Lua display timer is armed only while connected (window.lua
    // _render_ui_state), so it is not polling an unconnected session. The
    // consumer's own in-flight descriptor is deliberately NOT touched here: it
    // is consumer-owned non-atomic state, and drain_into drops it by generation
    // instead. A late old-generation push that lands after this drain stays in
    // the ring and is dropped (and released) by drain_into, or by the next
    // session's reset.
    uint32_t reset() noexcept
    {
        uint32_t drained = 0U;
        DisplayDesc stale{};
        while (ready_ring_.try_pop(stale)) {
            release_buf(stale.buf);
            ++drained;
        }
        return drained;
    }
    // Consume up to capacity bytes of the oldest batch. The consumer retains
    // its descriptor until every byte is copied, so a small ABI buffer never
    // truncates a batch or returns its slot early. `current_generation` is the
    // session generation the caller is rendering: a descriptor from an older
    // session is released and skipped (never copied), so a batch that spanned a
    // close/reopen cannot leak stale bytes into the new view. Only the consumer
    // ever releases its own active batch, which keeps a stale reset from
    // double-freeing it.  `out_ingress_ms` receives the active batch's arrival
    // time (monotonic ms) and is left untouched when nothing is buffered, so
    // the timestamp-aware ABI drain can anchor arrival wall-time.
    bool drain_into(char* output, uint32_t capacity, uint32_t current_generation,
                    uint32_t& written, bool& completed,
                    uint32_t& out_ingress_ms) noexcept
    {
        written = 0U;
        completed = false;
        if (output == nullptr || capacity == 0U) {
            return false;
        }
        if (consumer_active_ && consumer_desc_.gen != current_generation) {
            release_buf(consumer_desc_.buf);
            consumer_active_ = false;
        }
        if (false == consumer_active_) {
            for (;;) {
                if (false == ready_ring_.try_pop(consumer_desc_)) {
                    return false;
                }
                if (consumer_desc_.gen == current_generation) {
                    consumer_offset_ = 0U;
                    consumer_active_ = true;
                    break;
                }
                release_buf(consumer_desc_.buf);
            }
        }
        out_ingress_ms = consumer_desc_.ingress_ms;
        const uint32_t remaining = consumer_desc_.len - consumer_offset_;
        const uint32_t count = remaining < capacity ? remaining : capacity;
        std::memcpy(output,
                    static_cast<uint8_t*>(buffers_.block_ptr(consumer_desc_.buf)) +
                        consumer_offset_,
                    count);
        consumer_offset_ += count;
        written = count;
        if (consumer_offset_ == consumer_desc_.len) {
            release_buf(consumer_desc_.buf);
            consumer_active_ = false;
            completed = true;
        }
        return true;
    }
    uint8_t* buffer(uint16_t id) noexcept
    {
        return static_cast<uint8_t*>(buffers_.block_ptr(id));
    }

private:
    struct alignas(16) DisplayDesc {
        uint16_t buf;
        uint16_t pad0;
        uint32_t len;
        // Arrival time (monotonic ms) of the source RX block, carried so the
        // Lua drain can timestamp by REAL ingress time rather than format/drain
        // time.  Reuses the former sequence word (which was never read), so the
        // descriptor stays one 16-byte slot.
        uint32_t ingress_ms;
        // Session generation at push time (reuses the former padding word, so
        // the descriptor stays one 16-byte slot). drain_into compares it to the
        // caller's current generation to discard a batch that crossed a
        // close/reopen.
        uint32_t gen;
    };
    static_assert(sizeof(DisplayDesc) == 16U && alignof(DisplayDesc) == 16U,
                  "DisplayDesc slots must be one cache-line divisor");
    foundation::FixedPool<kDisplayBatchBytes, kDisplayBatchCount> buffers_;
    coact::SpscRing<DisplayDesc, kDisplayBatchCount> ready_ring_;
    // xcom_drain_display has exactly one caller, the Lua UI thread. These
    // fields are deliberately non-atomic to keep the 16 KiB drain path
    // copy-only.
    DisplayDesc consumer_desc_{};
    uint32_t consumer_offset_ = 0U;
    bool consumer_active_ = false;
};

// ---------------------------------------------------------------------------
// Monotonic snapshot counters and backpressure accounting.
// ---------------------------------------------------------------------------
struct Metrics {
    // Callback producer: isolate hot serial-thread stores from the Dispatcher
    // and ABI snapshot reader so every received block avoids false sharing.
    alignas(64)
    std::atomic<uint32_t> rx_bytes{0U};
    // DISPLAY BACKLOG bytes: a log is open and the display lane could not take
    // a segment because the raw/file lane's reserved floor had to be preserved.
    // These bytes are NOT lost serial data - the file log holds the
    // authoritative complete stream - they are simply not rendered. With NO log
    // open there is no authoritative copy, so a drop is charged to
    // save_rejected_bytes instead, never here. Do not read this as a data-loss
    // counter.
    std::atomic<uint32_t> rx_pool_exhausted_bytes{0U};
    // Edge-counted episodes where the read callback found every RX block in
    // use. For the file lane this means the disk has stalled for seconds: the
    // reader waits (rx_file_block_events / rx_file_blocked_ms) rather than
    // dropping, and keeps draining once the writer releases a block.
    std::atomic<uint32_t> rx_backpressure_events{0U};
    // v1.6 storage-stall visibility: read-thread episodes blocked waiting for
    // the file lane's reserve to free up, and the cumulative blocked time.
    // A stalled disk shows up here instead of as silent loss.
    std::atomic<uint32_t> rx_file_block_events{0U};
    std::atomic<uint32_t> rx_file_blocked_ms{0U};
    // Accepted-byte offset (rx_bytes at the time) of the most recent observed
    // receive loss, whether display backlog or a driver overrun report.
    // Locates WHERE in the accepted stream the gap starts. Only meaningful
    // once a loss counter is non-zero.
    std::atomic<uint32_t> rx_loss_offset{0U};
    std::atomic<uint32_t> rx_callback_oversize_bytes{0U};
    std::atomic<uint32_t> callback_count{0U};
    std::atomic<uint32_t> rx_seq{0U};

    // Dispatcher producer / ABI consumer. Keep the frequently read count on
    // its own line so snapshot polling cannot invalidate display sequencing.
    alignas(64)
    std::atomic<uint32_t> display_pending{0U};
    // Dispatcher-only display accounting.
    alignas(64)
    std::atomic<uint32_t> display_seq{0U};
    std::atomic<uint32_t> ui_trimmed_bytes{0U};
    std::atomic<uint32_t> display_paused_bytes{0U};

    // Write worker / timer producer counters.
    alignas(64)
    std::atomic<uint32_t> tx_bytes{0U};
    std::atomic<uint32_t> tx_rejected{0U};
    // Attributable subset of tx_rejected: sends the Send AO's overload Breaker
    // refused (DroppedOverload / RejectedState / DroppedPolicy / rate limit),
    // reported to the caller as XCOM_ERR_BUSY. This is NOT buffer-full: the
    // TxBlockPool may be empty. Kept separate so a "tx_rejected" spike can be
    // told apart from TxBlockPool pressure (which stays XCOM_ERR_FULL).
    std::atomic<uint32_t> tx_rejected_overload{0U};
    std::atomic<uint32_t> auto_tick_coalesced{0U};
    // Bytes that were accepted for capture but not retained: a queued log
    // segment could not be written before shutdown, the read thread had no file
    // owner and no display slot for a segment (no log open), or the writer
    // queue was full. The file lane shares the display lane's ref-counted RX
    // block, so this is an explicit, counted drop rather than a silent one.
    // Written by the read thread (ingress drop), the LogWriter thread (unwritten
    // tail) and the log-append path (writer queue full).
    std::atomic<uint32_t> save_rejected_bytes{0U};

    // v1.5 serial read-thread producer: ClearCommError line-error counters.
    // Own cache line so the 250 ms snapshot poll cannot invalidate the hot RX
    // byte counters. `flow_hold_events` counts rising flow-control holds (a
    // degraded-but-not-corrupt condition) and is diagnostic-only: it never
    // faults the link. Exported in XcomSnapshot since v1.6.
    alignas(64)
    std::atomic<uint32_t> framing_errors{0U};
    std::atomic<uint32_t> parity_errors{0U};
    std::atomic<uint32_t> overrun_errors{0U};
    std::atomic<uint32_t> break_events{0U};
    std::atomic<uint32_t> flow_hold_events{0U};
};

// v1.5: fold one ClearCommError line-status report into CoreCtx::metrics and
// emit a bounded diagnostic (first occurrence + power-of-two milestones, never
// per event, so an overflow storm cannot flood the diag lane). Shared by the
// real serial read callback and the xcom_test_inject_line_errors test seam.
// Each argument is an increment; the backend reports at most 1 per category
// per poll because ClearCommError returns a latched bitmask, not counts.
void line_status_ingress(CoreCtx* core, uint32_t framing_errors,
                         uint32_t parity_errors, uint32_t overrun_errors,
                         uint32_t break_events, uint32_t hold_events) noexcept;

// ---------------------------------------------------------------------------
// Error ring (128 entries).
// ---------------------------------------------------------------------------
struct ErrorEntry {
    int32_t code;
    uint16_t source;   // 0 core, 1 serial backend, 2 Win32
    std::array<char, 256U> message{};
};

class ErrorRing {
public:
    ErrorRing() noexcept
    {
        for (uint32_t index = 0U; index < kErrorRingCount; ++index) {
            entries_[index].sequence.store(index, std::memory_order_relaxed);
        }
    }

    void push(int32_t code, uint16_t source, std::string_view msg) noexcept
    {
        uint32_t position = enqueue_pos_.load(std::memory_order_relaxed);
        ErrorSlot* slot = nullptr;
        for (;;) {
            slot = &entries_[position & (kErrorRingCount - 1U)];
            const uint32_t sequence =
                slot->sequence.load(std::memory_order_acquire);
            const int32_t difference = static_cast<int32_t>(sequence - position);
            if (difference == 0) {
                if (enqueue_pos_.compare_exchange_weak(
                        position, position + 1U, std::memory_order_relaxed,
                        std::memory_order_relaxed)) {
                    break;
                }
                continue;
            }
            if (difference < 0) {
                dropped_.fetch_add(1U, std::memory_order_relaxed);
                return;
            }
            position = enqueue_pos_.load(std::memory_order_relaxed);
        }

        slot->entry.code = code;
        slot->entry.source = source;
        // string_view input: clamp to the fixed 256-byte message field and
        // NUL-terminate. An empty view (the old nullptr case) writes just the
        // terminator, exactly as before.
        const size_t cap = slot->entry.message.size() - 1U;
        const size_t n = msg.size() < cap ? msg.size() : cap;
        if (n > 0U) {
            std::memcpy(slot->entry.message.data(), msg.data(), n);
        }
        slot->entry.message[n] = '\0';
        slot->sequence.store(position + 1U, std::memory_order_release);
    }

    // Single-consumer pop. Producers reserve a slot, fill it, then publish its
    // sequence with release semantics; this avoids the old head-before-payload
    // race when the write worker and Dispatcher report errors concurrently.
    // Returns the whole ErrorEntry (or nullopt when the ring is empty) instead
    // of the former bool + four out-parameters.
    std::optional<ErrorEntry> take() noexcept
    {
        ErrorSlot& slot = entries_[dequeue_pos_ & (kErrorRingCount - 1U)];
        const uint32_t sequence = slot.sequence.load(std::memory_order_acquire);
        if (static_cast<int32_t>(sequence - (dequeue_pos_ + 1U)) != 0) {
            return std::nullopt;
        }
        // xcom_take_error is called only by the single ABI caller thread (the
        // Lua UI thread).
        ErrorEntry entry = slot.entry;
        slot.sequence.store(dequeue_pos_ + kErrorRingCount,
                            std::memory_order_release);
        ++dequeue_pos_;
        return entry;
    }

private:
    struct ErrorSlot {
        std::atomic<uint32_t> sequence{0U};
        ErrorEntry entry{};
    };

    alignas(64) std::atomic<uint32_t> enqueue_pos_{0U};
    alignas(64) uint32_t dequeue_pos_ = 0U;
    alignas(64) std::array<ErrorSlot, kErrorRingCount> entries_{};
    std::atomic<uint32_t> dropped_{0U};
};

// ---------------------------------------------------------------------------
// Thread heartbeat storage (design §4.2 item 3). One monotonic-ms stamp per
// monitored thread, plus a "parked" flag for the two threads that block in an
// INFINITE idle wait (the coact Dispatcher and the log writer): a parked thread
// is alive but produces no beat, so the observer must not read an old stamp as
// a wedge. The read thread returns from ReadFile ~every 50 ms and needs no
// parked flag. These are internal CoreCtx fields, NOT part of XcomSnapshot (the
// 80-byte ABI struct stays untouched). `*_state` is mutated only by the single
// snapshot-poll observer (check_thread_health).
// ---------------------------------------------------------------------------
struct ThreadHeartbeats {
    alignas(64) std::atomic<std::uint32_t> serial_read_ms{0U};
    std::atomic<std::uint32_t> dispatcher_ms{0U};
    std::atomic<std::uint32_t> log_writer_ms{0U};
    std::atomic<std::uint32_t> dispatcher_parked{0U};
    std::atomic<std::uint32_t> log_writer_parked{0U};
    // Lifecycle gates: 1 while the thread is alive and expected to beat, 0
    // before it starts and after it has been joined. A stopped thread leaves a
    // stale stamp and a cleared parked flag, which is indistinguishable from a
    // stall; the observer skips it (and recovers any open episode) while 0.
    std::atomic<std::uint32_t> dispatcher_running{0U};
    std::atomic<std::uint32_t> log_writer_running{0U};
    // Monotonic stamp when the Dispatcher entered its blocking wait, 0 when not
    // parked. Exposed so the observer can report a LONG park as a separate,
    // non-alarming signal: a park is not a stall, but silence would hide a lost
    // wakeup (the two cannot be told apart - design section 4.4 item 1).
    std::atomic<std::uint32_t> dispatcher_parked_since_ms{0U};
    LivenessState serial_read_state{};
    LivenessState dispatcher_state{};
    LivenessState log_writer_state{};
    ParkWatchState dispatcher_park_state{};
};

// Sample each monitored thread once. Called from xcom_get_snapshot, i.e. on the
// existing 250 ms UI status poll - no new thread and no timer. On a beat
// timeout it pushes ONE ErrorRing entry (and, later, ONE recovery entry) naming
// the thread and the elapsed time; it NEVER kills a thread and never drops data
// (design §4.3). Defined in xcom_core.cpp.
void check_thread_health(CoreCtx* core) noexcept;

// ---------------------------------------------------------------------------
// Full core context shared by the AOs and the C ABI. Owned (as a member) by the
// CoreState in xcom_core.cpp.
// ---------------------------------------------------------------------------
struct CoreCtx {
    DispatchSink sink;
    // Ref-counted RX block pool + the display and raw/file handoff rings. The
    // read thread is the sole producer on both ready rings; Dispatcher and
    // LogWriter's thread are the respective consumers. See
    // foundation/rx_block_lane.hpp.
    foundation::RxBlockLane rx;
    TxBlockPool tx;
    DisplayLane display;
    RxKickGate kick_gate;
    Metrics metrics;
    ErrorRing errors;
    ThreadHeartbeats heartbeats;

    // Independent option bytes: the ABI writer and ReceiveAo reader never need
    // a coherent multi-field snapshot, so atomics replace the old mutex.
    std::atomic<std::uint8_t> hex_view{0U};
    std::atomic<std::uint8_t> timestamp{0U};
    std::atomic<std::uint8_t> pause_display{0U};
    // Dispatcher-owned receive formatting state.  Serial callbacks may split
    // a logical line across blocks; timestamps must never be inserted in the
    // middle of that line.
    bool display_at_line_start = true;
    // Dispatcher-owned ANSI-strip state for the text view (rx_format_block).
    // 0 = outside a sequence, 1 = saw ESC, 2 = inside CSI, 3 = inside OSC,
    // 4 = ESC inside OSC (ST terminator).  Persists across blocks so an
    // escape split over two receive callbacks still resolves; reset on
    // open/close alongside display_at_line_start.
    std::uint8_t rx_strip_state = 0U;
    // Text-view CRLF carry across a receive-block boundary. True when the last
    // processed text byte was a lone CR; a following LF in the NEXT block is
    // then swallowed as the other half of one CRLF instead of rendering a
    // second blank line. Only the text path touches it, and it is reset on
    // open/close alongside display_at_line_start.
    bool rx_pending_cr = false;

    // AutoTickGate: the template itself is owned by AutoSendAo after a typed
    // coact event transfers its TxBlock. 1 means a tick is queued/in flight.
    std::atomic<uint32_t> autosend_armed{0U};
    std::atomic<uint64_t> autosend_next_tick_ns{0U};

    // Port / session state.
    std::atomic<uint16_t> port_state{0U};   // XCOM_PORT_*
    std::atomic<uint32_t> generation{0U};
    std::atomic<uint32_t> open_generation{0U};
    // Set by an ABI open timeout or close request while the SerialAo is still
    // running the synchronous native open. The owner consumes it before
    // publishing OPEN and schedules its legal Open -> Close HSM transition.
    std::atomic<uint32_t> cancel_open{0U};
    // Off-Dispatcher fault latch. Set (release) by serial_fault_callback /
    // sink_owner_write when the critical Fault signal is rejected (the control
    // pool is exhausted, so the AO never gets scheduled). SerialAo drains it
    // (acq_rel exchange) before its next lifecycle transition and runs the real
    // Fault edge then, whose kOwnerClose releases the stale handle on the
    // Dispatcher. The reporters must NOT call owner_close themselves: this
    // callback runs on the backend read or write thread, and owner_close joins
    // exactly that thread (serial_backend close() joins the read thread;
    // SessionWriter joins the write thread), so it would self-join and
    // terminate. This is the design-exception-matrix rule 6 reconciliation:
    // SerialCtx::state is never written from an off-Dispatcher thread.
    std::atomic<uint32_t> fault_pending{0U};
    bool virtual_port = false;
    std::array<char, 64U> port_name{};

    // Serial configuration snapshot (copied at xcom_open; read by the owner
    // sink on the Dispatcher). Never races: written before the open event is
    // submitted and only mutated by the serialized owner thereafter.
    uint32_t cfg_baud = 0U;
    uint8_t cfg_data_bits = 8U;
    uint8_t cfg_stop_bits = 0U;   // ABI encoding 0=1,1=1.5,2=2
    uint8_t cfg_parity = 0U;
    uint8_t cfg_flow_control = 0U;
    // Snapshot of XcomPortConfig.dtr_enable/rts_enable, kept as the raw ABI
    // tri-state (0 = deassert, 1 = assert, 2 = leave alone) and cast to
    // LineDrive when the backend is opened. Preserved verbatim, not collapsed to
    // a bool, so "leave this line alone" survives to the open path.
    uint8_t cfg_dtr_enable = 0U;
    uint8_t cfg_rts_enable = 0U;

    // RxIngress admission (see docs §9 / high-performance §2). in_callback is
    // a release/acquire counter the read thread bumps before copying and drops
    // after; admission is closed before WinSerialBackend::close() joins its
    // read thread, so no callback starts after admission is checked at 0.
    std::atomic<uint32_t> callback_admission{1U};   // 1 = admit new callbacks
    std::atomic<uint32_t> in_callback{0U};
    // Set when the read callback found the RX pool exhausted: for the file
    // lane that means the disk stalled and the reader is BLOCKING (lossless),
    // for the display lane that means display backlog. A visible state
    // (edge-counted through rx_backpressure_events), cleared when ReceiveAo
    // releases a block. It is not a discard counter.
    std::atomic<uint32_t> rx_backpressured{0U};
    // Open result set by the owner on the Dispatcher; read by xcom_open on the
    // caller thread after port_state leaves OPENING/FAULT.
    std::atomic<int32_t> last_open_result{XCOM_ERR_IO};

    // Consecutive failed native writes. Written by the SessionWriter thread,
    // read/cleared by it too; a fatal device-removed/access-denied error or a
    // run of this many failures escalates the session to FAULT instead of
    // leaving port_state OPEN while every subsequent write hits a dead handle.
    std::atomic<uint32_t> tx_fail_streak{0U};

    // Injected test session flag.
    std::atomic<uint32_t> test_session{0U};

    // Init the non-RX lanes. The RX lane needs a platform CriticalSection (a
    // real spinlock on SMP), so it is initialized separately by CoreState
    // through init_rx() once the spinlock storage exists.
    [[nodiscard]] bool init() noexcept
    {
        tx.init();
        if (!display.init()) {
            return false;
        }

        return sync_port_name(nullptr);
    }

    // Init the ref-counted RX pool. `cs` must remain valid for the lifetime of
    // this CoreCtx (CoreState owns the SpinCriticalSection).
    [[nodiscard]] bool init_rx(coact::CriticalSection cs) noexcept
    {
        return rx.init(cs);
    }

    void shutdown() noexcept {}

    [[nodiscard]] bool sync_port_name(const char* name) noexcept
    {
        if (name == nullptr) {
            port_name.front() = '\0';
            return true;
        }
        const std::string_view input{name};
        if (input.size() >= port_name.size()) {
            port_name.front() = '\0';
            return false;
        }
        foundation::copy_text(input, port_name);
        return true;
    }

    // Registered sinks (installed by CoreState).
    // Returns true when the wake was accepted. On refusal the RxKickGate latch
    // would otherwise stay armed with no event in flight, so it is released
    // here: the next receive callback or ABI resume trigger re-arms and retries.
    // The display therefore cannot stall permanently while data keeps arriving.
    // Safe on the caller thread: disarm only clears the latch, never blocks.
    bool submit_rx_kick()
    {
        if (sink.submit_rx_kick != nullptr && sink.submit_rx_kick(this)) {
            return true;
        }
        kick_gate.disarm();
        return false;
    }
    bool submit_control(uint16_t signal, uint32_t word, bool critical)
    {
        if (sink.submit_control != nullptr) {
            return sink.submit_control(this, signal, word, critical);
        }
        return false;
    }
    XcomStatus submit_write(const TxDescriptor& descriptor)
    {
        if (sink.submit_write != nullptr) {
            return sink.submit_write(this, descriptor);
        }
        // No send pipeline installed: the port cannot be open.
        return XCOM_ERR_NOT_OPEN;
    }
    bool submit_autosend_config(const AutoTemplateDescriptor& descriptor)
    {
        return sink.submit_autosend_config != nullptr &&
               sink.submit_autosend_config(this, descriptor);
    }
    bool enqueue_write(uint16_t block, uint16_t len, uint32_t gen,
                       bool auto_send)
    {
        if (sink.enqueue_write != nullptr) {
            return sink.enqueue_write(this, block, len, gen, auto_send);
        }
        return false;
    }
    void resume_rx() noexcept
    {
        // The read thread no longer blocks on RX capacity: it drops the
        // unaccepted segments into the per-lane counters and keeps reading.
        // Nothing has to be woken, so this is retained only as the clearing
        // point for the visible backpressure edge flag.
        rx_backpressured.store(0U, std::memory_order_release);
    }
    XcomStatus log_open(const char* path, bool append) noexcept
    {
        return sink.log_open != nullptr ? sink.log_open(this, path, append)
                                        : XCOM_ERR_IO;
    }
    XcomStatus log_append(const uint8_t* data, uint32_t size) noexcept
    {
        return sink.log_append != nullptr ? sink.log_append(this, data, size)
                                          : XCOM_ERR_IO;
    }
    XcomStatus log_flush(uint32_t timeout_ms) noexcept
    {
        return sink.log_flush != nullptr ? sink.log_flush(this, timeout_ms)
                                         : XCOM_ERR_IO;
    }
    XcomStatus log_close(uint32_t timeout_ms) noexcept
    {
        return sink.log_close != nullptr ? sink.log_close(this, timeout_ms)
                                         : XCOM_ERR_IO;
    }
    XcomStatus file_submit_atomic(const char* path, const uint8_t* data,
                                  uint32_t size, uint64_t request_id) noexcept
    {
        return sink.file_submit_atomic != nullptr
                   ? sink.file_submit_atomic(this, path, data, size, request_id)
                   : XCOM_ERR_IO;
    }

    XcomStatus file_submit_atomic_borrowed(
        const char* path, const uint8_t* data, uint32_t size,
        uint64_t request_id) noexcept
    {
        return sink.file_submit_atomic_borrowed != nullptr
                   ? sink.file_submit_atomic_borrowed(this, path, data, size,
                                                       request_id)
                   : XCOM_ERR_IO;
    }
    XcomStatus file_stream_begin(const char* path, uint64_t stream_id,
                                 uint64_t request_id) noexcept
    {
        return sink.file_stream_begin != nullptr
                   ? sink.file_stream_begin(this, path, stream_id, request_id)
                   : XCOM_ERR_IO;
    }
    XcomStatus file_stream_append_borrowed(
        uint64_t stream_id, const uint8_t* data, uint32_t size,
        uint64_t request_id) noexcept
    {
        return sink.file_stream_append_borrowed != nullptr
                   ? sink.file_stream_append_borrowed(this, stream_id, data,
                                                       size, request_id)
                   : XCOM_ERR_IO;
    }
    XcomStatus file_stream_commit(uint64_t stream_id,
                                  uint64_t request_id) noexcept
    {
        return sink.file_stream_commit != nullptr
                   ? sink.file_stream_commit(this, stream_id, request_id)
                   : XCOM_ERR_IO;
    }
    XcomStatus file_stream_abort(uint64_t stream_id,
                                 uint64_t request_id) noexcept
    {
        return sink.file_stream_abort != nullptr
                   ? sink.file_stream_abort(this, stream_id, request_id)
                   : XCOM_ERR_IO;
    }
    XcomStatus file_take_completion(uint64_t* request_id,
                                    XcomStatus* status) noexcept
    {
        return sink.file_take_completion != nullptr
                   ? sink.file_take_completion(this, request_id, status)
                   : XCOM_ERR_IO;
    }
    // Account receive bytes that reached the callback but have no owner and
    // cannot be stored: the session admission gate is closed (the close /
    // shutdown reaping window) or the port is not OPEN (bytes delivered during
    // owner_open before OPEN is published). They will never reach the display or
    // the log, so they are real loss, not backlog, and must land in the same
    // ledger the UI surfaces as DATA LOSS rather than vanish silently. Mirrors
    // the unowned-drop tail accounting in rx_ingress; the caller emits the
    // kRxDrop diag record. Inline so the accounting is unit-testable on the
    // host without linking xcom_core.cpp.
    void count_rejected_rx(uint32_t n) noexcept
    {
        if (n == 0U) {
            return;
        }
        metrics.save_rejected_bytes.fetch_add(n, std::memory_order_relaxed);
        metrics.rx_loss_offset.store(
            metrics.rx_bytes.load(std::memory_order_relaxed),
            std::memory_order_relaxed);
    }

    void diag_emit(uint16_t source, uint16_t event_id, uint32_t a0,
                   uint32_t a1, uint32_t a2, uint32_t a3) noexcept
    {
        if (sink.diag_emit != nullptr) {
            sink.diag_emit(this, source, event_id, a0, a1, a2, a3);
        }
    }
};

}  // namespace xcom

#endif /* XCOM_CORE_HPP_ */
