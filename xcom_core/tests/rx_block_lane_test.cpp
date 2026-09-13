// rx_block_lane_test.cpp - hardware-free test for the ref-counted RX lane.
//
// This is the evidence the owner asked for: the FILE lane must never lose
// serial data even while the display is stalled (window opening, modal dialog,
// pause), and the reader must block rather than drop when the disk itself has
// stalled. It is Win32-free, so it compiles and runs on Linux with g++:
//
//   g++ -std=c++17 -O2 -pthread \
//       -Ixcom_core/src -Ixcom_core/src/runtime -Ixcom_core/src/foundation \
//       -I../coact/include xcom_core/tests/rx_block_lane_test.cpp -o /tmp/rx_lane_test
//   /tmp/rx_lane_test
//
// It drives the lane exactly as the read thread does (one allocator, sole
// producer of both rings) and asserts:
//   (a) raw/file bytes are byte-identical and complete while the display is
//       never drained;
//   (b) the display-backlog counter moves while the raw-loss counter stays 0;
//   (c) pool.used() returns to 0 and the free count returns to capacity after
//       teardown.
// A second phase asserts the lossless backpressure: with the file reserve
// exhausted the reader blocks (wait_for_free times out) instead of dropping,
// and unblocks as soon as the file consumer releases a block. It also releases
// two holders of one block in both orders and proves the pool returns to 0.
//
// SPDX-License-Identifier: MIT
#include "foundation/fixed_pool.hpp"
#include "foundation/rx_block_lane.hpp"

#include <array>
#include <atomic>
#include <chrono>
#include <csignal>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <sys/wait.h>
#include <thread>
#include <unistd.h>
#include <vector>

using xcom::foundation::RxBlockLane;
using xcom::foundation::RxBlockRef;

static int g_failures = 0;

#define CHECK(cond, msg)                                                \
    do {                                                                \
        if (!(cond)) {                                                  \
            std::fprintf(stderr, "FAIL: %s (%s:%d)\n", msg, __FILE__,   \
                         __LINE__);                                     \
            ++g_failures;                                               \
        }                                                               \
        else {                                                          \
            std::printf("ok: %s\n", msg);                               \
        }                                                               \
        std::fflush(stdout);                                            \
    } while (0)

static void fill_block(std::uint8_t* p, std::uint32_t len, std::uint32_t seed)
{
    for (std::uint32_t i = 0U; i < len; ++i) {
        p[i] = static_cast<std::uint8_t>((seed * 7U + i * 31U + 3U) & 0xFFU);
    }
}

int main()
{
    RxBlockLane lane;
    coact::SpinCriticalSection spin;   // real serialization, as production uses
    CHECK(lane.init(coact::make_spin_critical_section(spin)),
          "lane init");
    CHECK(lane.capacity() == xcom::kRxBlockCount, "capacity is kRxBlockCount");
    CHECK(lane.used() == 0U, "fresh pool used == 0");
    CHECK(lane.free_blocks() == lane.capacity(), "fresh pool free == capacity");

    // --- two holders of one block, released in BOTH orders -----------------
    for (int order = 0; order < 2; ++order) {
        bool display_ok = false;
        coact::Event* const ev = lane.try_alloc(true, display_ok);
        CHECK(ev != nullptr && display_ok, "both-lane claim succeeds");
        std::memset(RxBlockLane::payload(ev), 0xAB, 8U);
        const RxBlockRef ref{ev, 8U, 1U, 1234U};
        CHECK(lane.publish(ref, true, true), "display takes its reference");
        CHECK(lane.used() == 1U, "one block now owned");
        RxBlockRef raw{};
        RxBlockRef disp{};
        CHECK(lane.pop_raw(raw) && raw.event == ev, "raw holds the same block");
        CHECK(lane.pop_display(disp) && disp.event == ev,
              "display holds the same block");
        if (order == 0) {
            lane.release(raw.event);
            CHECK(lane.used() == 1U, "one holder released, block still owned");
            lane.release(disp.event);
        }
        else {
            lane.release(disp.event);
            CHECK(lane.used() == 1U, "one holder released, block still owned");
            lane.release(raw.event);
        }
        CHECK(lane.used() == 0U, "last holder release returns the block");
    }

    // --- phase A: display stalled, file drained ----------------------------
    constexpr std::uint32_t kSegBytes = 100U;
    constexpr std::uint32_t kSegments = 400U;
    std::uint32_t display_backlog = 0U;
    std::uint32_t raw_lost = 0U;
    std::vector<coact::Event*> pinned_display;
    for (std::uint32_t s = 0U; s < kSegments; ++s) {
        bool display_ok = false;
        coact::Event* const ev = lane.try_alloc(true, display_ok);
        if (ev == nullptr) {
            ++raw_lost;   // a lossless lane must never take this path here
            continue;
        }
        std::uint8_t* const payload = RxBlockLane::payload(ev);
        fill_block(payload, kSegBytes, s);
        const RxBlockRef ref{ev, static_cast<std::uint16_t>(kSegBytes), 1U, s};
        const bool display_took = lane.publish(ref, true, display_ok);
        if (!display_took) {
            display_backlog += kSegBytes;
        }
        else {
            pinned_display.push_back(ev);   // display never drains it
        }
        // File consumer: drain and verify every byte immediately.
        RxBlockRef out{};
        if (!lane.pop_raw(out)) {
            ++raw_lost;
            continue;
        }
        std::uint8_t expect[kSegBytes];
        fill_block(expect, kSegBytes, s);
        if (out.len != kSegBytes ||
            std::memcmp(RxBlockLane::payload(out.event), expect, kSegBytes) !=
                0) {
            ++raw_lost;
        }
        lane.release(out.event);
    }
    CHECK(raw_lost == 0U, "file lane delivered every byte (raw loss == 0)");
    CHECK(display_backlog > 0U, "display backlog counted while file kept all");
    // The display is stalled, so exactly the non-reserved headroom is pinned.
    CHECK(lane.used() ==
              (xcom::kRxBlockCount - xcom::kRxRawReserveBlocks),
          "stalled display pins only the non-reserved share");
    CHECK(pinned_display.size() == lane.used(),
          "pinned display refs match used()");

    // --- phase B: file stalled -> reader blocks, never drops ---------------
    std::vector<coact::Event*> pinned_file;
    bool all_file_only = true;
    for (;;) {
        bool display_ok = false;
        coact::Event* const ev = lane.try_alloc(true, display_ok);
        if (ev == nullptr) {
            break;
        }
        all_file_only = all_file_only && !display_ok;
        pinned_file.push_back(ev);   // hold the raw reference: disk stalled
    }
    CHECK(all_file_only, "reserve claims are file-only (display excluded)");
    CHECK(lane.free_blocks() == 0U, "file reserve fully consumed by the stall");
    CHECK(lane.wait_for_free(10U) == false,
          "reader blocks (wait_for_free times out) instead of dropping");
    CHECK(raw_lost == 0U, "no drop while blocked");
    // Writer makes progress: release one reference and the reader unblocks.
    CHECK(!pinned_file.empty(), "had reserved blocks to release");
    lane.release(pinned_file.back());
    pinned_file.pop_back();
    CHECK(lane.wait_for_free(100U) == true,
          "releasing one block unblocks the reader");

    // --- teardown: release every pinned reference --------------------------
    for (coact::Event* ev : pinned_file) {
        lane.release(ev);
    }
    // The display was never drained: pop each queued descriptor and release
    // its single reference exactly once.
    {
        RxBlockRef disp{};
        while (lane.pop_display(disp)) {
            lane.release(disp.event);
        }
    }
    static_cast<void>(lane.drain_raw());
    static_cast<void>(lane.drain_display());
    CHECK(lane.used() == 0U, "pool used() back to 0 after teardown");
    CHECK(lane.free_blocks() == lane.capacity(),
          "pool free count back to capacity after teardown");

    // --- display-only lane: no file lane, so no reserve is withheld --------
    // With NO log open the display lane is the only consumer of the pool. The
    // kRxRawReserveBlocks floor protects the FILE lane from the display, so
    // with no file lane there is nothing to protect and the display must be
    // able to use the WHOLE pool. Kills the mutation that passes
    // kRxRawReserveBlocks to alloc_with_margin regardless of file_lane (the
    // old bug left only capacity - reserve = 32 blocks usable and counted the
    // rest as display backlog / drop far too early).
    {
        RxBlockLane display_only;
        CHECK(display_only.init(coact::make_spin_critical_section(spin)),
              "display-only lane init");
        std::array<coact::Event*, xcom::kRxBlockCount> held{};
        std::uint32_t claimed = 0U;
        bool all_display_ok = true;
        for (std::uint32_t i = 0U; i < xcom::kRxBlockCount; ++i) {
            bool display_ok = false;
            coact::Event* const ev = display_only.try_alloc(false, display_ok);
            if (ev == nullptr) {
                break;
            }
            all_display_ok = all_display_ok && display_ok;
            held[claimed] = ev;
            ++claimed;
        }
        // Assert the measured usable-block count, not merely a flag change.
        CHECK(claimed == xcom::kRxBlockCount,
              "display-only lane claims the FULL pool (128 usable blocks)");
        CHECK(all_display_ok,
              "display-only claims never withhold a non-existent file reserve");
        CHECK(display_only.free_blocks() == 0U,
              "no block stays reserved when no file lane exists");
        bool beyond_ok = true;
        CHECK(display_only.try_alloc(false, beyond_ok) == nullptr,
              "a display-only claim is refused only when the pool is truly full");
        CHECK(beyond_ok == false, "refused claim did not mark display_ok");
        for (std::uint32_t i = 0U; i < claimed; ++i) {
            display_only.release(held[i]);
        }
        CHECK(display_only.used() == 0U, "display-only lane back to 0");
    }

    // --- a blocked reader is woken by a release, not by the timeout --------
    // Kills the mutation that deletes cv_.notify_all() in release(): without
    // the wake the waiter only re-checks its predicate at the timeout, so the
    // observed latency would be the full wait rather than a prompt wake.
    {
        RxBlockLane blocked;
        CHECK(blocked.init(coact::make_spin_critical_section(spin)),
              "blocked-wake lane init");
        std::vector<coact::Event*> pinned;
        for (;;) {
            bool display_ok = false;
            coact::Event* const ev = blocked.try_alloc(true, display_ok);
            if (ev == nullptr) {
                break;
            }
            pinned.push_back(ev);
        }
        CHECK(blocked.free_blocks() == 0U, "wake lane fully pinned");
        constexpr std::uint32_t kWaitTimeoutMs = 5000U;
        constexpr std::uint32_t kMaxWakeLatencyMs = 2000U;
        std::atomic<bool> waiting{false};
        std::atomic<bool> woke{false};
        std::atomic<std::uint32_t> latency_ms{0U};
        std::thread waiter([&blocked, &waiting, &woke, &latency_ms] {
            waiting.store(true, std::memory_order_release);
            const auto start = std::chrono::steady_clock::now();
            const bool freed = blocked.wait_for_free(kWaitTimeoutMs);
            const auto elapsed =
                std::chrono::duration_cast<std::chrono::milliseconds>(
                    std::chrono::steady_clock::now() - start)
                    .count();
            latency_ms.store(static_cast<std::uint32_t>(elapsed),
                             std::memory_order_release);
            woke.store(freed, std::memory_order_release);
        });
        while (!waiting.load(std::memory_order_acquire)) {
            std::this_thread::yield();
        }
        // Let the waiter enter cv_.wait_for and register on waiters_ before the
        // release checks that counter; generous so the test is not timing-flaky.
        std::this_thread::sleep_for(std::chrono::milliseconds(50));
        blocked.release(pinned.back());
        pinned.pop_back();
        waiter.join();
        CHECK(woke.load(std::memory_order_acquire),
              "blocked reader observed the freed block");
        CHECK(latency_ms.load(std::memory_order_acquire) < kMaxWakeLatencyMs,
              "blocked reader was woken promptly, not by the timeout");
        for (coact::Event* ev : pinned) {
            blocked.release(ev);
        }
        CHECK(blocked.used() == 0U, "wake lane back to 0");
    }

    // --- the file-lane reserve is load-bearing, not parametric --------------
    // While a file lane is active the display must stop at exactly the
    // non-reserved share, so a stalled display can never pin the file lane's
    // floor. Kills the mutation that drops kRxRawReserveBlocks from the
    // file-lane margin (display_ok would then stay true into the reserve) and
    // the mutation that shrinks the reserve (the share would grow).
    {
        RxBlockLane with_file;
        CHECK(with_file.init(coact::make_spin_critical_section(spin)),
              "file-reserve lane init");
        const std::uint32_t display_share =
            xcom::kRxBlockCount - xcom::kRxRawReserveBlocks;
        std::vector<coact::Event*> held;
        std::uint32_t display_ok_count = 0U;
        bool share_is_contiguous = true;
        for (;;) {
            bool display_ok = false;
            coact::Event* const ev = with_file.try_alloc(true, display_ok);
            if (ev == nullptr) {
                break;
            }
            held.push_back(ev);
            if (display_ok) {
                ++display_ok_count;
                share_is_contiguous =
                    share_is_contiguous && (display_ok_count <= display_share);
            }
            else {
                // Once the floor is reached the display must never come back.
                share_is_contiguous =
                    share_is_contiguous && (display_ok_count >= display_share);
            }
        }
        CHECK(display_ok_count == display_share,
              "display_ok stops at exactly capacity - kRxRawReserveBlocks");
        CHECK(share_is_contiguous,
              "the reserve is one contiguous floor, never re-entered");
        CHECK(held.size() == xcom::kRxBlockCount,
              "the file lane still reaches the full pool via its reserve");
        for (coact::Event* ev : held) {
            with_file.release(ev);
        }
        CHECK(with_file.used() == 0U, "file-reserve lane back to 0");
    }

    // --- Item 1: tagged-CAS FixedPool is safe with TWO release producers ----
    // The old DisplayLane free ring was an SpscRing with two releasers and
    // lost an update on a plain head store, stranding a 16 KiB buffer. This
    // releases one pool from two concurrent threads and proves every id is
    // conserved exactly once.
    {
        xcom::foundation::FixedPool<16U, 32U> pool;
        std::vector<void*> blocks;
        for (int i = 0; i < 32; ++i) {
            blocks.push_back(pool.allocate());
        }
        bool all_allocated = true;
        for (void* b : blocks) {
            all_allocated = all_allocated && (b != nullptr);
        }
        CHECK(all_allocated, "dual-producer pool allocates all 32 blocks");
        std::thread t1([&pool, &blocks] {
            for (int i = 0; i < 16; ++i) {
                pool.release(blocks[static_cast<std::size_t>(i)]);
            }
        });
        std::thread t2([&pool, &blocks] {
            for (int i = 16; i < 32; ++i) {
                pool.release(blocks[static_cast<std::size_t>(i)]);
            }
        });
        t1.join();
        t2.join();
        int reissued = 0;
        while (pool.allocate() != nullptr) {
            ++reissued;
        }
        CHECK(reissued == 32, "concurrent release conserves all 32 blocks");
        CHECK(pool.allocate() == nullptr, "no double-issue after concurrent release");
    }

    // --- Defect 2: allocate vs a concurrent release -------------------------
    // allocate reads the head block's free-list link before its CAS. The link is
    // published by a plain store that precedes the releaser's release CAS, so
    // the head load and the CAS failure path must both acquire or a weakly-
    // ordered target can read the link stale and hand out a claimed block.
    // x86-64 TSO is sequentially consistent for these loads, so this cannot fail
    // here even with the old relaxed ordering; it is the conservation guard
    // against "optimizing" the acquire back to relaxed.
    {
        xcom::foundation::FixedPool<16U, 32U> pool;
        std::atomic<std::uint32_t> held_mask{0U};
        std::atomic<bool> double_issued{false};
        auto worker = [&pool, &held_mask, &double_issued] {
            for (int i = 0; i < 200000; ++i) {
                void* const b = pool.allocate();
                if (b == nullptr) {
                    continue;
                }
                const std::uint32_t bit =
                    1U << pool.block_index(b);
                const std::uint32_t before = held_mask.fetch_or(
                    bit, std::memory_order_acq_rel);
                if ((before & bit) != 0U) {
                    double_issued.store(true, std::memory_order_relaxed);
                }
                held_mask.fetch_and(~bit, std::memory_order_acq_rel);
                pool.release(b);
            }
        };
        std::thread w1(worker);
        std::thread w2(worker);
        std::thread w3(worker);
        std::thread w4(worker);
        w1.join();
        w2.join();
        w3.join();
        w4.join();
        CHECK(false == double_issued.load(std::memory_order_relaxed),
              "no block issued twice while allocate/release race");
        int total = 0;
        while (pool.allocate() != nullptr) {
            ++total;
        }
        CHECK(total == 32, "concurrent allocate/release conserves all 32 blocks");
    }

#ifndef NDEBUG
    // --- Defect 3: double release of a valid id is detected (debug builds) ---
    // The detector is compiled out of release builds (see fixed_pool.hpp), so
    // this probe only exists when NDEBUG is unset. It aborts, so run it in a
    // forked child and require SIGABRT.
    {
        const pid_t pid = fork();
        if (0 == pid) {
            xcom::foundation::FixedPool<16U, 8U> pool;
            void* const b = pool.allocate();
            pool.release(b);
            pool.release(b);   // must abort before the second free-list push
            _exit(0);          // reached only if the detector is missing
        }
        CHECK(pid > 0, "forked the double-release probe");
        if (pid > 0) {
            int status = 0;
            static_cast<void>(waitpid(pid, &status, 0));
            CHECK(WIFSIGNALED(status) && SIGABRT == WTERMSIG(status),
                  "double release of a valid id aborts in debug builds");
        }
    }
#endif

    if (g_failures != 0) {
        std::fprintf(stderr, "rx-block-lane tests FAILED (%d)\n", g_failures);
        return 1;
    }
    std::printf("rx-block-lane tests PASS\n");
    return 0;
}
