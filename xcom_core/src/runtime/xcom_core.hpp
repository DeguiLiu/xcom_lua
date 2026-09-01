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
#include "foundation/fixed_pool.hpp"
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
    // callback/inject thread; must not block.
    void (*submit_rx_kick)(CoreCtx* core) = nullptr;
    // Submits a control event allocated from the control EventPool (owned
    // reference). Takes a signal and a 32-bit word. Consumes the pooled event
    // reference in all cases (releases it on rejection/drop).
    bool (*submit_control)(CoreCtx* core, uint16_t signal, uint32_t word,
                           bool critical) = nullptr;
    // v1.2 §6: submit a typed send event with an OWNED TxDescriptor payload
    // (alloc_typed), never a shared single slot. Consumes the pooled ref on all
    // paths (releases on rejection/drop).
    bool (*submit_write)(CoreCtx* core, const TxDescriptor& desc) = nullptr;
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
    void (*owner_resume_rx)(CoreCtx* core) = nullptr;
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
// A receive block descriptor (ready ring payload). Carries ownership of a
// fixed RxBlockPool slot; never copies the big payload.
// ---------------------------------------------------------------------------
struct alignas(16) RxDesc {
    uint16_t block = 0U;
    uint16_t len = 0U;
    uint32_t seq = 0U;
    uint16_t gen = 0U;
    uint16_t pad0 = 0U;
    uint32_t pad1 = 0U;
};
static_assert(sizeof(RxDesc) == 16U && alignof(RxDesc) == 16U,
              "RxDesc slots must be one cache-line divisor");

// ---------------------------------------------------------------------------
// Lock-free free-id pool of fixed 4096-byte receive blocks (design §4/§7.1).
// free_ring_ is consumed by the callback/inject producer and returned by the
// Dispatcher; ready_ring_ is the opposite role (producer pushes, ReceiveAo
// pops).
// ---------------------------------------------------------------------------
class RxDatalane {
public:
    [[nodiscard]] bool init() noexcept
    {
        for (uint16_t i = 0U; i < kRxBlockCount; ++i) {
            if (!free_ring_.try_push(std::move(i))) {
                return false;
            }
        }
        return true;
    }

    // Producer side: acquire an owned 4096-byte block. Returns a stable pointer
    // to fill, or nullptr when the pool is exhausted (caller counts the
    // unaccepted bytes and never truncates silently).
    [[nodiscard]] uint8_t* try_acquire_block(uint16_t& out_id) noexcept
    {
        uint16_t id;
        if (!free_ring_.try_pop(id)) {
            return nullptr;
        }
        out_id = id;
        return blocks_[id].data();
    }

    void release_block(uint16_t id) noexcept
    {
        COACT_ASSERT(free_ring_.try_push(std::move(id)));
    }

    // Publish a completed descriptor to the ready ring. empty->non-empty
    // transition is detected by the caller via the gate.
    [[nodiscard]] bool push_ready(RxDesc d) noexcept
    {
        return ready_ring_.try_push(std::move(d));
    }
    [[nodiscard]] bool pop_ready(RxDesc& out) noexcept
    {
        return ready_ring_.try_pop(out);
    }
    [[nodiscard]] bool ready_empty() noexcept
    {
        // size() is a point-in-time relaxed read; adequate for the
        // disarm->recheck gate protocol (any post-check publish is re-caught
        // by the gate re-arm).
        return ready_ring_.size() == 0U;
    }
    [[nodiscard]] bool has_free_block() noexcept
    {
        return free_ring_.size() != 0U;
    }
    [[nodiscard]] uint32_t free_block_count() noexcept
    {
        return free_ring_.size();
    }
    uint8_t* block(uint16_t id) noexcept { return blocks_[id].data(); }

private:
    using RxBlock = std::array<std::uint8_t, kRxBlockBytes>;
    alignas(64) std::array<RxBlock, kRxBlockCount> blocks_;
    coact::SpscRing<uint16_t, kRxBlockCount> free_ring_;
    coact::SpscRing<RxDesc, kRxBlockCount> ready_ring_;
};

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
// Display batch (<= 64 KiB UTF-8 text) owner-transfer ring. Producer is the
// Dispatcher/ReceiveAo and consumer is the CoreWorker/drain caller. The public
// ABI polls this lane, so the hot receive path deliberately has no Win32 event
// signal or kernel transition per batch.
// ---------------------------------------------------------------------------
class DisplayLane {
public:
    [[nodiscard]] bool init() noexcept
    {
        for (uint16_t i = 0U; i < kDisplayBatchCount; ++i) {
            if (!free_ring_.try_push(std::move(i))) {
                return false;
            }
        }
        return true;
    }

    [[nodiscard]] bool try_acquire(uint16_t& out_id, uint8_t*& out_buf) noexcept
    {
        uint16_t id;
        if (!free_ring_.try_pop(id)) {
            return false;
        }
        out_id = id;
        out_buf = buffers_[id].data();
        return true;
    }
    void release_buf(uint16_t id) noexcept
    {
        COACT_ASSERT(free_ring_.try_push(std::move(id)));
    }

    bool push_ready(uint16_t id, uint32_t len, uint32_t seq) noexcept
    {
        DisplayDesc d{};
        d.buf = id;
        d.len = len;
        d.seq = seq;
        return ready_ring_.try_push(std::move(d));
    }
    // Consume up to capacity bytes of the oldest batch. The consumer retains
    // its descriptor until every byte is copied, so a small ABI buffer never
    // truncates a batch or returns its slot early.
    bool drain_into(char* output, uint32_t capacity, uint32_t& written,
                    bool& completed) noexcept
    {
        written = 0U;
        completed = false;
        if (output == nullptr || capacity == 0U) {
            return false;
        }
        if (!consumer_active_) {
            if (!ready_ring_.try_pop(consumer_desc_)) {
                return false;
            }
            consumer_offset_ = 0U;
            consumer_active_ = true;
        }
        const uint32_t remaining = consumer_desc_.len - consumer_offset_;
        const uint32_t count = remaining < capacity ? remaining : capacity;
        std::memcpy(output, buffers_[consumer_desc_.buf].data() +
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
    uint8_t* buffer(uint16_t id) noexcept { return buffers_[id].data(); }

private:
    struct alignas(16) DisplayDesc {
        uint16_t buf;
        uint16_t pad0;
        uint32_t len;
        uint32_t seq;
        uint32_t pad1;
    };
    static_assert(sizeof(DisplayDesc) == 16U && alignof(DisplayDesc) == 16U,
                  "DisplayDesc slots must be one cache-line divisor");
    using DisplayBatch = std::array<std::uint8_t, kDisplayBatchBytes>;
    alignas(64) std::array<DisplayBatch, kDisplayBatchCount> buffers_;
    coact::SpscRing<uint16_t, kDisplayBatchCount> free_ring_;
    coact::SpscRing<DisplayDesc, kDisplayBatchCount> ready_ring_;
    // xcom_drain_display has exactly one CoreWorker caller. These fields are
    // deliberately non-atomic to keep the 64 KiB drain path copy-only.
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
    std::atomic<uint32_t> rx_pool_exhausted_bytes{0U};
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
    std::atomic<uint32_t> auto_tick_coalesced{0U};
    std::atomic<uint32_t> save_rejected_bytes{0U};
};

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
        // xcom_take_error is called only by the single ABI/CoreWorker thread.
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
// Full core context shared by the AOs and the C ABI. Owned (as a member) by the
// CoreState in xcom_core.cpp.
// ---------------------------------------------------------------------------
struct CoreCtx {
    DispatchSink sink;
    RxDatalane rx;
    TxBlockPool tx;
    DisplayLane display;
    RxKickGate kick_gate;
    Metrics metrics;
    ErrorRing errors;

    // Independent option bytes: the ABI writer and ReceiveAo reader never need
    // a coherent multi-field snapshot, so atomics replace the old mutex.
    std::atomic<std::uint8_t> hex_view{0U};
    std::atomic<std::uint8_t> timestamp{0U};
    std::atomic<std::uint8_t> pause_display{0U};

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
    uint8_t cfg_dtr_enable = 0U;
    uint8_t cfg_rts_enable = 0U;

    // RxIngress admission (see docs §9 / high-performance §2). in_callback is
    // a release/acquire counter the read thread bumps before copying and drops
    // after; admission is closed before WinSerialBackend::close() joins its
    // read thread, so no callback starts after admission is checked at 0.
    std::atomic<uint32_t> callback_admission{1U};   // 1 = admit new callbacks
    std::atomic<uint32_t> in_callback{0U};
    // Set when the backend read callback waits because every owned Rx slot is
    // in use. This is a visible backpressure state, not a discard counter.
    std::atomic<uint32_t> rx_backpressured{0U};
    // Open result set by the owner on the Dispatcher; read by xcom_open on the
    // caller thread after port_state leaves OPENING/FAULT.
    std::atomic<int32_t> last_open_result{XCOM_ERR_IO};

    // Injected test session flag.
    std::atomic<uint32_t> test_session{0U};

    [[nodiscard]] bool init() noexcept
    {
        if (!rx.init()) {
            return false;
        }
        tx.init();
        if (!display.init()) {
            return false;
        }

        return sync_port_name(nullptr);
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
    void submit_rx_kick()
    {
        if (sink.submit_rx_kick != nullptr) {
            sink.submit_rx_kick(this);
        }
    }
    bool submit_control(uint16_t signal, uint32_t word, bool critical)
    {
        if (sink.submit_control != nullptr) {
            return sink.submit_control(this, signal, word, critical);
        }
        return false;
    }
    bool submit_write(const TxDescriptor& descriptor)
    {
        if (sink.submit_write != nullptr) {
            return sink.submit_write(this, descriptor);
        }
        return false;
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
        if (sink.owner_resume_rx != nullptr) {
            sink.owner_resume_rx(this);
        }
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
