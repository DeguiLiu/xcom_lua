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
// A fourth window is covered by test_deferred_release_charges_only_unlogged:
// when rx_format_block cannot store a block (display ring full / display
// paused) the descriptor is retained in ReceiveAo's deferred slot. Because
// rx_kick_action popped it OFF the display ring, the session-boundary reset can
// never see it; releasing the slot at close/shutdown used to discard its bytes
// silently. CoreCtx::release_deferred_rx now charges the SOURCE bytes of only an
// UNLOGGED block (no file lane) before releasing the reference.
//   * drop the `count_rejected_rx(bytes)` call in count_deferred_display_loss:
//     the unlogged block's 300 bytes are not charged.
//   * count every descriptor instead of checking kDisplayUnloggedBit: the
//     file-backed block is charged too (the ledger becomes 500, not 300).
//   * remove the has_deferred guard / fail to clear it: the repeat release adds
//     a second 300 and the "adds nothing" assertion fails.
//
// Defect "stale-generation batches in drain_into" is covered by
// test_defect2_commit_reset_then_drain_no_double_count, which pins the verdict
// that no change to drain_into is correct: generation advances only at
// kOpenCommit/kCloseCommit, each of which drains+charges the ready ring on the
// same Dispatcher thread before the consumer can poll again, so the stale bytes
// are already counted at the commit and charging again would double count.
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

// A ReceiveAo-deferred display descriptor was popped off the display ring, so
// the session-boundary reset can no longer see it. Releasing it at
// close/shutdown must charge its SOURCE bytes to the loss ledger - but only when
// the source segment had no file lane, because a file-backed block's bytes are
// still owned by the raw ring (and a stranded raw tail is counted by the
// shutdown raw drain).
void test_deferred_release_charges_only_unlogged(CoreCtx& core)
{
    core.metrics.rx_bytes.store(9000U, std::memory_order_relaxed);
    core.metrics.save_rejected_bytes.store(0U, std::memory_order_relaxed);
    core.metrics.rx_loss_offset.store(0U, std::memory_order_relaxed);

    // Unlogged source segment: display is the only lane. The display copy's low
    // 15 bits carry the SOURCE byte count; publish tags the high bit because no
    // file lane took a reference.
    bool display_ok = false;
    coact::Event* const ev = core.rx.try_alloc(false, display_ok);
    CHECK(ev != nullptr && display_ok, "unlogged rx block allocated");
    const xcom::RxDesc ref{ev, 300U, 1U, 111U};
    CHECK(core.rx.publish(ref, false, true),
          "unlogged block published to the display lane");
    xcom::RxDesc deferred{};
    CHECK(core.rx.pop_display(deferred), "deferred descriptor popped");
    bool has_deferred = true;
    CHECK(core.release_deferred_rx(deferred, has_deferred),
          "deferred reference released at the session boundary");
    CHECK(false == has_deferred, "the deferred slot is cleared");
    CHECK(core.metrics.save_rejected_bytes.load(std::memory_order_relaxed) ==
              300U,
          "the unlogged deferred block's SOURCE bytes reach DATA LOSS");
    CHECK(core.metrics.rx_loss_offset.load(std::memory_order_relaxed) == 9000U,
          "the deferred loss anchors at the accepted-byte position");

    // Repeat release is a no-op: the slot is empty, so nothing is released or
    // charged again. This is the close-followed-by-shutdown path.
    CHECK(false == core.release_deferred_rx(deferred, has_deferred),
          "a repeat release finds the slot empty");
    CHECK(core.metrics.save_rejected_bytes.load(std::memory_order_relaxed) ==
              300U,
          "a repeat release adds nothing");

    // File-backed source segment: the raw ring holds the same bytes, so the
    // deferred display reference is released WITHOUT charging.
    const uint32_t before =
        core.metrics.save_rejected_bytes.load(std::memory_order_relaxed);
    display_ok = false;
    coact::Event* const ev2 = core.rx.try_alloc(true, display_ok);
    CHECK(ev2 != nullptr && display_ok, "file-backed rx block allocated");
    const xcom::RxDesc ref2{ev2, 200U, 1U, 222U};
    CHECK(core.rx.publish(ref2, true, true),
          "file-backed block published to both lanes");
    xcom::RxDesc deferred2{};
    CHECK(core.rx.pop_display(deferred2),
          "file-backed display descriptor popped");
    CHECK((deferred2.len & xcom::foundation::RxBlockLane::kDisplayUnloggedBit) ==
              0U,
          "a file-backed display copy is not tagged unlogged");
    // Drop the raw reference; the LogWriter owns those bytes, not the ledger.
    xcom::RxDesc raw{};
    CHECK(core.rx.pop_raw(raw), "raw reference popped");
    core.rx.release(raw.event);
    bool has_deferred2 = true;
    CHECK(core.release_deferred_rx(deferred2, has_deferred2),
          "file-backed deferred reference released");
    CHECK(core.metrics.save_rejected_bytes.load(std::memory_order_relaxed) ==
              before,
          "a file-backed deferred block is never charged (no double count)");
}

// Defect "stale-generation batches dropped on the floor" verdict: NO CHANGE.
// A display batch's generation can go stale only when `generation` advances, and
// generation advances only in kOpenCommit/kCloseCommit, each of which runs
// reset_display_at_commit on the SAME Dispatcher thread that pushes batches (a
// push stamps the then-current generation). The commit reset drains the ready
// ring and charges exactly its unlogged source bytes, so any queued batch that
// goes stale is charged once at that commit; by the time the ABI consumer could
// observe a mismatched generation the ring is already empty. Charging again in
// drain_into would double count. Pin that ordering.
void test_defect2_commit_reset_then_drain_no_double_count(CoreCtx& core)
{
    core.metrics.rx_bytes.store(4000U, std::memory_order_relaxed);
    core.metrics.save_rejected_bytes.store(0U, std::memory_order_relaxed);
    core.metrics.rx_loss_offset.store(0U, std::memory_order_relaxed);
    core.metrics.display_pending.store(0U, std::memory_order_relaxed);

    uint16_t id = 0U;
    uint8_t* buf = nullptr;
    CHECK(core.display.try_acquire(id, buf), "stale-candidate batch acquired");
    CHECK(core.display.push_ready(id, 40U, 111U, /*generation=*/1U, 300U, true),
          "unlogged batch queued in generation 1");
    core.metrics.display_pending.fetch_add(1U, std::memory_order_relaxed);
    static_cast<void>(buf);

    // The commit that advances generation 1 -> 2 drains the ring and charges the
    // unlogged batch's source bytes.
    CHECK(core.reset_display_committed() == 1U,
          "the commit reset retired the queued batch");
    CHECK(core.metrics.save_rejected_bytes.load(std::memory_order_relaxed) ==
              300U,
          "the commit charged the stale batch exactly once");

    // The consumer now drains under the NEW generation: the ring is empty, so
    // there is no stale descriptor to release and nothing is charged again.
    char out[64] = {};
    uint32_t written = 0U;
    uint32_t ingress = 0U;
    bool completed = false;
    CHECK(false == core.display.drain_into(out, sizeof(out), 2U, written,
                                           completed, ingress),
          "the new-generation drain finds nothing stale to discard");
    CHECK(core.metrics.save_rejected_bytes.load(std::memory_order_relaxed) ==
              300U,
          "drain_into does not charge bytes the commit already counted");
    CHECK(core.metrics.display_pending.load(std::memory_order_relaxed) == 0U,
          "display_pending was retired by the commit reset, not double dropped");
}

}  // namespace

int main()
{
    // CoreCtx embeds the 128 x 4 KiB RX pool and the 32 x 16 KiB display lane;
    // keep it off the stack.
    static xcom::CoreCtx core;
    static coact::SpinCriticalSection rx_spin;
    CHECK(core.init_rx(coact::make_spin_critical_section(rx_spin)),
          "ref-counted RX lane init");

    test_zero_is_not_loss(core);
    test_rejected_batch_is_counted(core);
    test_ledger_accumulates(core);
    test_offset_tracks_accepted_bytes(core);
    test_display_reset_charges_only_unlogged(core);
    test_deferred_release_charges_only_unlogged(core);
    test_defect2_commit_reset_then_drain_no_double_count(core);

    if (g_failures != 0) {
        std::fprintf(stderr, "%d check(s) failed\n", g_failures);
        return 1;
    }
    std::printf("rx reject count: all checks passed\n");
    return 0;
}
