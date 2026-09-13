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
// A third window is covered by test_display_reset_charges_only_unlogged: the
// session-boundary display reset (CoreCtx::reset_display_committed, called from
// reset_display_at_commit on the open/close commit). A batch that arrived after
// the log closed but before the close committed took a display slot, was never
// displayed (the exit path stopped the timer first), and was discarded by the
// reset without touching the ledger. The reset now charges the SOURCE bytes of
// only those batches whose source segment had no file lane.
//   * delete the `count_rejected_rx(unlogged)` call in reset_display_committed:
//     the unlogged bytes are not counted (the test's 300-byte batch is lost).
//   * pass `true` for every batch instead of the stored flag: the file-backed
//     batch is charged too (save_rejected_bytes becomes 500, not 300).
//   * charge the formatted `len` instead of the source `rx_meta` count: the
//     test's 40-vs-300 split fails.
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

// A session-boundary display reset (open/close commit) must charge the SOURCE
// bytes of exactly those discarded batches that carried NO file lane, and never
// a batch a log already holds. This is the close-window defect: a batch that
// arrives after the log closed but before the close commits is never displayed
// (timers already stopped) and was previously discarded silently - absent from
// both the DATA LOSS ledger and the file.
void test_display_reset_charges_only_unlogged(CoreCtx& core)
{
    core.metrics.rx_bytes.store(4000U, std::memory_order_relaxed);
    core.metrics.save_rejected_bytes.store(0U, std::memory_order_relaxed);
    core.metrics.rx_loss_offset.store(0U, std::memory_order_relaxed);
    core.metrics.display_pending.store(0U, std::memory_order_relaxed);

    // Batch A: no log lane at ingress -> the only copy, 300 source bytes.
    // Batch B: file lane present at ingress -> the log holds it, 200 bytes.
    uint16_t id_a = 0U;
    uint16_t id_b = 0U;
    uint8_t* buf_a = nullptr;
    uint8_t* buf_b = nullptr;
    const bool got_a = core.display.try_acquire(id_a, buf_a);
    const bool got_b = core.display.try_acquire(id_b, buf_b);
    CHECK(got_a && got_b, "display batches acquired");
    // Formatted len deliberately differs from the source len so a fix that
    // counted the wrong field would be caught.
    CHECK(core.display.push_ready(id_a, 40U, 111U, 1U, 300U, true),
          "unlogged batch pushed");
    CHECK(core.display.push_ready(id_b, 25U, 222U, 1U, 200U, false),
          "file-backed batch pushed");
    core.metrics.display_pending.fetch_add(2U, std::memory_order_relaxed);
    static_cast<void>(buf_a);
    static_cast<void>(buf_b);

    const uint32_t drained = core.reset_display_committed();
    CHECK(drained == 2U, "both parked batches were retired");
    CHECK(core.metrics.save_rejected_bytes.load(std::memory_order_relaxed) ==
              300U,
          "only the unlogged batch's SOURCE bytes are charged to DATA LOSS");
    CHECK(core.metrics.rx_loss_offset.load(std::memory_order_relaxed) == 4000U,
          "the display loss anchors at the accepted-byte position");
    CHECK(core.metrics.display_pending.load(std::memory_order_relaxed) == 0U,
          "display_pending is retired with the batches");

    // Exactly once: a repeat reset finds the ring empty and adds nothing.
    const uint32_t again = core.reset_display_committed();
    CHECK(again == 0U, "a second reset finds no parked batch");
    CHECK(core.metrics.save_rejected_bytes.load(std::memory_order_relaxed) ==
              300U,
          "a repeat reset does not double-count");
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
    test_display_reset_charges_only_unlogged(core);

    if (g_failures != 0) {
        std::fprintf(stderr, "%d check(s) failed\n", g_failures);
        return 1;
    }
    std::printf("rx reject count: all checks passed\n");
    return 0;
}
