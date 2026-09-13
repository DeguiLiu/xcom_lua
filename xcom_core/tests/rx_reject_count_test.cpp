// rx_reject_count_test.cpp - host test for the unowned-receive loss ledger.
//
// Defect: a receive batch that arrives with no owner was discarded without
// touching the loss ledger. Two windows fed it:
//   * close/shutdown: sink_owner_close (xcom_core.cpp:932) and
//     CoreState::shutdown (xcom_core.cpp:592) zero callback_admission BEFORE
//     serial_backend.close() joins the read thread, so a read that completes
//     concurrently with the stop - now reaped and delivered by the sibling
//     backend fix (serial_backend_win.cpp:655-663) - reaches
//     serial_read_callback with admission already 0;
//   * open: the read thread starts inside owner_open (serial_backend_win.cpp
//     :224) while the AO has already published OPENING, so an in-flight read is
//     delivered before port_state becomes OPEN and rx_ingress returned silently.
// In both cases the bytes were neither delivered nor counted, which is exactly
// the "silent loss" the product forbids.
//
// The fix routes both windows through CoreCtx::count_rejected_rx(), which adds
// the bytes to metrics.save_rejected_bytes - the ledger the snapshot exposes and
// the UI renders as DATA LOSS - and anchors metrics.rx_loss_offset at the
// accepted-byte position so the gap is locatable. This test pins that accounting
// seam (it is inline in xcom_core.hpp precisely so it is host-testable without
// linking xcom_core.cpp).
//
// Mutation that must make it fail:
//   * delete the `metrics.save_rejected_bytes.fetch_add(...)` line in
//     CoreCtx::count_rejected_rx(): tests 2 and 3 fail (no bytes counted).
//   * store a constant / different value into metrics.rx_loss_offset: test 4
//     fails (the gap offset no longer tracks the accepted byte count).
//   * delete the `n == 0U` early return: test 1 fails (a zero-length callback
//     would move the loss offset).
//
// Host-only: xcom_core.hpp pulls in <windows.h>, so the Win32 stub is required
// and the target is built only where that stub exists (same as
// rx_kick_gate_test.cpp).
//
// SPDX-License-Identifier: MIT
#include "xcom_core.hpp"

#include <cstdint>
#include <cstdio>

static int g_failures = 0;

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

namespace {

using xcom::CoreCtx;

// A zero-length batch is not loss: it must not move the ledger or the offset.
void test_zero_is_not_loss(CoreCtx& core)
{
    core.metrics.rx_bytes.store(500U, std::memory_order_relaxed);
    core.metrics.save_rejected_bytes.store(0U, std::memory_order_relaxed);
    core.metrics.rx_loss_offset.store(0U, std::memory_order_relaxed);

    core.count_rejected_rx(0U);

    CHECK(core.metrics.save_rejected_bytes.load(std::memory_order_relaxed) == 0U,
          "a zero-length batch adds nothing to the loss ledger");
    CHECK(core.metrics.rx_loss_offset.load(std::memory_order_relaxed) == 0U,
          "a zero-length batch does not move the loss offset");
}

// A batch that cannot be stored is charged to the UI-visible loss ledger.
void test_rejected_batch_is_counted(CoreCtx& core)
{
    core.metrics.rx_bytes.store(0U, std::memory_order_relaxed);
    core.metrics.save_rejected_bytes.store(0U, std::memory_order_relaxed);
    core.metrics.rx_loss_offset.store(0U, std::memory_order_relaxed);

    core.count_rejected_rx(4096U);

    CHECK(core.metrics.save_rejected_bytes.load(std::memory_order_relaxed) ==
              4096U,
          "the rejected batch lands in save_rejected_bytes (DATA LOSS)");
}

// The ledger is additive across close-window and open-window drops; it never
// resets, so accepted != persisted stays visible for the session.
void test_ledger_accumulates(CoreCtx& core)
{
    core.metrics.rx_bytes.store(0U, std::memory_order_relaxed);
    core.metrics.save_rejected_bytes.store(0U, std::memory_order_relaxed);

    core.count_rejected_rx(10U);   // close-window tail
    core.count_rejected_rx(7U);    // open-window preamble
    core.count_rejected_rx(3U);

    CHECK(core.metrics.save_rejected_bytes.load(std::memory_order_relaxed) == 20U,
          "successive rejected batches accumulate in the loss ledger");
}

// The loss offset is anchored at the accepted-byte count at the moment of the
// drop, so the UI can locate where in the accepted stream the gap begins.
void test_offset_tracks_accepted_bytes(CoreCtx& core)
{
    core.metrics.rx_bytes.store(1234U, std::memory_order_relaxed);
    core.metrics.rx_loss_offset.store(0U, std::memory_order_relaxed);

    core.count_rejected_rx(64U);

    CHECK(core.metrics.rx_loss_offset.load(std::memory_order_relaxed) == 1234U,
          "the loss offset points at the accepted-byte position of the drop");
}

}  // namespace

int main()
{
    // CoreCtx embeds the 128 x 4 KiB RX pool and the 32 x 16 KiB display lane;
    // keep it off the stack.
    static xcom::CoreCtx core;

    test_zero_is_not_loss(core);
    test_rejected_batch_is_counted(core);
    test_ledger_accumulates(core);
    test_offset_tracks_accepted_bytes(core);

    if (g_failures != 0) {
        std::fprintf(stderr, "%d check(s) failed\n", g_failures);
        return 1;
    }
    std::printf("rx reject count: all checks passed\n");
    return 0;
}
