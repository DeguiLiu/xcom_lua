// rx_block_lane.hpp - ref-counted RX block pool + two SPSC handoff rings.
//
// This header is deliberately Win32-free: it depends only on the header-only
// coact EventPool / SpscRing primitives and on the XCOM resource constants, so
// the block lifetime and the file-lane reservation can be unit-tested on a
// Linux host with g++ (see xcom_core/tests/rx_block_lane_test.cpp), not merely
// parsed on Windows.
//
// Ownership model (owner constraints: REFERENCE COUNTING, minimise memory, and
// serial data MUST NOT be lost for the file lane):
//   - A single fixed pool of coact::EventPool blocks backs every RX segment. A
//     block is allocated with ref_ctr == 1 by the serial read thread.
//   - The read thread FANS OUT one segment to two independent consumers by
//     carrying the SAME coact::Event* on two descriptors: the display lane
//     (Dispatcher) and the raw/file lane (LogWriter's own thread). Each
//     handed-off descriptor owns exactly ONE reference; publish() performs the
//     single event_ref_inc for the second consumer.
//   - Each consumer calls release() exactly once when it is done (after
//     formatting / after writing). The last release returns the block to the
//     pool. ref_ctr is the leak guard: an over-release aborts inside event_gc
//     (COACT_ASSERT), and a missed release shows up as pool.used() never
//     returning to zero.
//   - No second 512 KiB RX buffer: the second consumer reads the very same
//     block, so the raw bytes are preserved byte-for-byte with no extra copy.
//
// File-lane reservation (the display must never be able to starve the file):
//   - The pool is partitioned by a floor of kRxRawReserveBlocks. A block is
//     claimed with two different coact entries:
//       * both lanes:  pool.alloc_with_margin(sig, kRxRawReserveBlocks) - the
//         reservation check and the free-list pop share ONE critical section,
//         so the floor can never be consumed by the display even under
//         concurrent allocators;
//       * file only:   pool.alloc(sig) - taken only after the margin claim
//         failed, i.e. the file lane dipping into its own reserve.
//     The display lane therefore never holds a reference on a block below the
//     floor, so a stalled display cannot starve the file lane.
//   - When the file lane genuinely cannot claim (the floor is exhausted, i.e.
//     the disk has stalled for seconds), the reader BLOCKS on a condition
//     variable rather than dropping: the file stream is lossless. The blocked
//     episode is timed by the caller and surfaced as a storage stall.
//   - When the display cannot claim it simply falls behind; the caller counts
//     those bytes as DISPLAY BACKLOG (rx_pool_exhausted_bytes), not as loss,
//     because the file log keeps the complete authoritative stream.
//
// Concurrency: the read thread is the sole allocator (both the live callback
// and the injected test seam funnel through one ingress entry), and it is the
// sole producer on both ready rings. Release is multi-producer and goes
// through the pool's short spinlock, never held across I/O or a blocking wait.
//
// SPDX-License-Identifier: MIT
#pragma once
#ifndef XCOM_FOUNDATION_RX_BLOCK_LANE_HPP_
#define XCOM_FOUNDATION_RX_BLOCK_LANE_HPP_

#include <array>
#include <chrono>
#include <condition_variable>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <mutex>
#include <type_traits>
#include <utility>

#include "coact/assert.hpp"
#include "coact/event.hpp"
#include "coact/pal.hpp"
#include "coact/pool.hpp"
#include "coact/spsc_ring.hpp"

#include "xcom_config.hpp"

namespace xcom::foundation {

// One owned reference to a pool RX block, plus the per-segment metadata the
// consumers need. The valid byte length lives ONLY here (never in the pool
// event's `signal`, which is set to Signal::RxBlock). Trivially copyable so it
// can ride an SPSC ring; moving it between rings does not change the count.
struct RxBlockRef {
    coact::Event* event = nullptr;   // pool block owning one reference
    std::uint16_t len = 0U;          // valid bytes copied into the payload
    std::uint16_t gen = 0U;          // session generation at ingress
    // Monotonic milliseconds sampled at INGRESS (not at format time). Carried
    // with the block so the display can emit gap-based timestamps against the
    // arrival time even when backlog is formatted seconds later; same 16-byte
    // slot as a sequence number, no growth.
    std::uint32_t ingress_ms = 0U;
};
static_assert(sizeof(RxBlockRef) == 16U,
              "RxBlockRef must be one compact ring payload");
static_assert(std::is_trivially_copyable<RxBlockRef>::value,
              "RxBlockRef must move through SPSC rings without a nontrivial op");

// Fixed pool + the two ready rings. Each ring has exactly one producer (the
// read thread) and exactly one consumer (Dispatcher / LogWriter), so the SPSC
// contract holds for both.
class RxBlockLane {
public:
    static constexpr std::uint16_t kBlockSize =
        static_cast<std::uint16_t>(sizeof(coact::Event) + kRxBlockBytes);
    static constexpr std::size_t kBlockAlign = alignof(std::max_align_t);
    // EventPool rounds BlockSize up to BlockAlign for the block stride; mirror
    // it so the backing storage yields exactly kRxBlockCount blocks.
    static constexpr std::size_t kStride =
        (kBlockSize + kBlockAlign - 1U) & ~(kBlockAlign - 1U);

    using Pool = coact::EventPool<kBlockSize,
                                  static_cast<std::uint16_t>(kRxBlockCount),
                                  coact::HostSmpProfile,
                                  kBlockAlign>;

    RxBlockLane() noexcept = default;
    RxBlockLane(const RxBlockLane&) = delete;
    RxBlockLane& operator=(const RxBlockLane&) = delete;

    // Inject the platform critical section (a real spinlock on SMP hosts, an
    // irq mask on single-core, a no-op in single-threaded host tests). Must
    // outlive this lane.
    [[nodiscard]] bool init(coact::CriticalSection cs) noexcept
    {
        return pool_.init(storage_.data(), storage_.size(), cs);
    }

    // Read thread: claim a block for one segment.
    //   file_lane  - a log is open and this segment must be persisted.
    //   display_ok - set true when the display lane may also hold a reference
    //                (i.e. the claim preserved the file-lane reserve).
    // Returns nullptr only when the requested lane cannot be served at all:
    // for file_lane that means the pool is truly exhausted and the caller must
    // BLOCK (never drop); for the display-only case the caller counts display
    // backlog and keeps reading.
    [[nodiscard]] coact::Event* try_alloc(bool file_lane,
                                          bool& display_ok) noexcept
    {
        const uint16_t sig = to_signal(Signal::RxBlock);
        display_ok = false;
        coact::Event* const both =
            pool_.alloc_with_margin(sig, kRxRawReserveBlocks);
        if (both != nullptr) {
            // Free after the claim is still >= the reserve: both lanes share it.
            display_ok = true;
            return both;
        }
        if (!file_lane) {
            return nullptr;   // display cannot touch the reserve
        }
        // File lane dipping into its own reserved floor: file-only, so the
        // display falls behind rather than the file losing bytes.
        return pool_.alloc(sig);
    }

    // Byte payload of a block: the region after the coact::Event header.
    [[nodiscard]] static std::uint8_t* payload(coact::Event* event) noexcept
    {
        return reinterpret_cast<std::uint8_t*>(event) + sizeof(coact::Event);
    }

    // Release exactly one owned reference. Multi-producer safe (any consumer
    // thread may call it); the block returns to the pool at the last release.
    // A blocked file-lane reader is woken only on an actual release.
    void release(coact::Event* event) noexcept
    {
        coact::event_gc(event);
        if (waiters_.load(std::memory_order_acquire) != 0U) {
            std::lock_guard<std::mutex> lock(mutex_);
            cv_.notify_all();
        }
    }

    // Fan one segment out to the lanes that may hold a reference. Consumes the
    // caller's reference: display gets one (when display_ok) and file gets one
    // (when file_lane). At least one of those is always true for a successful
    // try_alloc, so the caller's reference is never stranded. Returns whether
    // the display lane took its reference (false = display backlog bytes).
    bool publish(const RxBlockRef& ref, bool file_lane,
                 bool display_ok) noexcept
    {
        coact::Event* const event = ref.event;
        COACT_ASSERT(event != nullptr);
        // The caller's allocation reference is exactly one lane's reference.
        // A second lane needs an explicit increment; a file-only claim (the
        // reserve fallback, display_ok == false) keeps the single reference.
        if (file_lane && display_ok) {
            coact::event_ref_inc(event);   // second consumer's reference
        }
        if (file_lane) {
            // Raw ring capacity equals pool capacity and every queued entry
            // holds a reference, so a successful claim guarantees room here.
            const bool pushed = raw_ready_.try_push(
                RxBlockRef{event, ref.len, ref.gen, ref.ingress_ms});
            COACT_ASSERT(pushed);
        }
        if (display_ok) {
            const bool pushed = display_ready_.try_push(
                RxBlockRef{event, ref.len, ref.gen, ref.ingress_ms});
            COACT_ASSERT(pushed);
            return true;
        }
        return false;
    }

    // Display lane: producer read thread, consumer Dispatcher.
    [[nodiscard]] bool pop_display(RxBlockRef& out) noexcept
    {
        return display_ready_.try_pop(out);
    }
    [[nodiscard]] bool display_ready_empty() noexcept
    {
        return display_ready_.size() == 0U;
    }

    // Raw/file lane: producer read thread, consumer LogWriter's thread.
    [[nodiscard]] bool pop_raw(RxBlockRef& out) noexcept
    {
        return raw_ready_.try_pop(out);
    }
    [[nodiscard]] bool raw_ready_empty() noexcept
    {
        return raw_ready_.size() == 0U;
    }

    // Block until at least one block is free (the file lane's reserve is the
    // only way to reach this). Returns false on timeout so the caller can
    // re-check admission/port state. Never called on the non-blocking display
    // path.
    bool wait_for_free(std::uint32_t timeout_ms) noexcept
    {
        waiters_.fetch_add(1U, std::memory_order_acq_rel);
        std::unique_lock<std::mutex> lock(mutex_);
        const bool free_now = cv_.wait_for(
            lock, std::chrono::milliseconds(timeout_ms),
            [this] { return pool_.used() < kRxBlockCount; });
        waiters_.fetch_sub(1U, std::memory_order_acq_rel);
        return free_now;
    }

    // Wake a blocked reader immediately (close/teardown).
    void wake_blocked() noexcept
    {
        std::lock_guard<std::mutex> lock(mutex_);
        cv_.notify_all();
    }

    // Teardown-only drains: release every reference still queued so no block is
    // stranded when a consumer stops. The returned byte counts let the caller
    // account for bytes that were accepted but never written.
    std::uint32_t drain_display() noexcept
    {
        std::uint32_t bytes = 0U;
        RxBlockRef ref{};
        while (display_ready_.try_pop(ref)) {
            bytes += ref.len;
            coact::event_gc(ref.event);
        }
        return bytes;
    }
    std::uint32_t drain_raw() noexcept
    {
        std::uint32_t bytes = 0U;
        RxBlockRef ref{};
        while (raw_ready_.try_pop(ref)) {
            bytes += ref.len;
            coact::event_gc(ref.event);
        }
        return bytes;
    }

    [[nodiscard]] std::uint16_t used() const noexcept { return pool_.used(); }
    [[nodiscard]] std::uint16_t capacity() const noexcept
    {
        return pool_.capacity();
    }
    [[nodiscard]] std::uint16_t free_blocks() const noexcept
    {
        return static_cast<std::uint16_t>(pool_.capacity() - pool_.used());
    }

private:
    alignas(64) std::array<std::byte, kStride * kRxBlockCount> storage_{};
    Pool pool_;
    coact::SpscRing<RxBlockRef, kRxBlockCount> display_ready_;
    coact::SpscRing<RxBlockRef, kRxBlockCount> raw_ready_;
    // Blocking-file-lane rendezvous. Only touched when the reserve is
    // exhausted (reader) or when a waiter exists (release), so the hot path
    // stays lock-free.
    std::atomic<std::uint32_t> waiters_{0U};
    std::mutex mutex_;
    std::condition_variable cv_;
};

}  // namespace xcom::foundation

#endif  // XCOM_FOUNDATION_RX_BLOCK_LANE_HPP_
