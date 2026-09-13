// fault_latch_reconcile_test.cpp - host test for the rejected-Fault fallback.
//
// Defect (review P1-9): when the critical Fault signal is rejected because the
// control pool is exhausted, serial_fault_callback() / sink_owner_write() run
// off the Dispatcher (backend read thread / SessionWriter thread). They cannot
// call owner_close (it joins the calling thread -> self-join -> terminate), so
// they publish port_state = FAULT directly (I1 exception) and latch the fault
// in CoreCtx::fault_pending. Without reconciliation the Dispatcher-owned
// SerialCtx::state stays S_OPEN, so the FAULT --Open--> OPENING edge can never
// be found: xcom_open() sees port_state == FAULT (accepted), submits Open, the
// AO matches nothing, last_open_result stays BUSY and the open times out after
// ~2 s while the stale COM handle is still held (ERROR_ACCESS_DENIED for any
// other program).
//
// This test drives the real Dispatcher-side entry points (serial_do_open /
// serial_do_fault / serial_do_close) from xcom_ao.cpp, exactly like
// serial_transition_test.cpp. It is Win32-free (tools/win32-stub) and links a
// host coact::pal::monotonic_ms, so it runs on Linux.
//
// Mutation that must make it fail:
//   * test_reopen_releases_latched_fault: delete the
//     `serial_reconcile_pending_fault(ctx);` call at the top of serial_do_open()
//     (xcom_ao.cpp). Then no Fault edge runs, kOpen from S_OPEN has no edge,
//     owner_open/owner_close are never called and the checks on g_close_calls /
//     g_open_calls / final state fail.
//   * test_fault_clears_latch: delete the
//     `core->fault_pending.store(0U, ...)` line in serial_do_fault(). Then the
//     latch survives and the final `!fault_pending` check fails.
//   * test_close_clears_latch: delete the corresponding store in
//     serial_do_close(). Then the latch survives the close.
//
// BUILD (Linux, from the repository root):
//   g++ -std=c++17 -pthread -Itools/win32-stub -Ixcom_core/include
//       -Ixcom_core/src -Ixcom_core/src/runtime -Ixcom_core/src/foundation
//       -Ixcom_core/src/ao -Ixcom_core/src/diagnostics -Ixcom_core/src/io
//       -I../coact/include xcom_core/tests/fault_latch_reconcile_test.cpp
//       xcom_core/src/ao/xcom_ao.cpp -o /tmp/fault_latch_reconcile_test
//
// SPDX-License-Identifier: MIT
#include "xcom_ao.hpp"

#include "coact/event.hpp"
#include "coact/pal_windows.hpp"

#include <atomic>
#include <cstdint>
#include <cstdio>

// xcom_ao.cpp's beat_dispatcher() calls coact::pal::monotonic_ms(), whose real
// definition lives in coact's Win32 PAL. These actions never need a clock, so a
// constant host definition completes the link.
namespace coact {
namespace pal {

std::uint64_t monotonic_ms() noexcept
{
    return 0U;
}

}  // namespace pal
}  // namespace coact

namespace {

using xcom::CoreCtx;
using xcom::SerialCtx;
using xcom::SerialEvent;
using xcom::SerialState;

int g_failures = 0;

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

int g_open_calls = 0;
int g_close_calls = 0;
std::int32_t g_owner_open_result = XCOM_OK;

void hook_open(CoreCtx* core)
{
    ++g_open_calls;
    core->last_open_result.store(g_owner_open_result,
                                 std::memory_order_release);
}

void hook_close(CoreCtx* /*core*/)
{
    ++g_close_calls;
}

void install_hooks(CoreCtx& core)
{
    core.sink.owner_open = &hook_open;
    core.sink.owner_close = &hook_close;
}

void reset_hooks()
{
    g_open_calls = 0;
    g_close_calls = 0;
    g_owner_open_result = XCOM_OK;
}

// A rejected-fault fallback left port_state = FAULT and fault_pending = 1 while
// the local state is still S_OPEN. Reopening must reconcile: the Fault edge runs
// first (owner_close releases the stale handle) and then Open proceeds to OPEN.
void test_reopen_releases_latched_fault()
{
    reset_hooks();

    CoreCtx core{};
    install_hooks(core);
    core.port_state.store(XCOM_PORT_FAULT, std::memory_order_release);
    core.fault_pending.store(1U, std::memory_order_release);
    core.last_open_result.store(XCOM_ERR_BUSY, std::memory_order_release);

    SerialCtx ctx{};
    ctx.core = &core;
    ctx.state = SerialState::S_OPEN;   // the un-reconciled local state

    coact::Event evt{};
    xcom::serial_do_open(ctx, evt);

    CHECK(g_close_calls == 1,
          "reopen releases the stale handle through owner_close first");
    CHECK(g_open_calls == 1,
          "reopen then runs owner_open (the Open edge was found from FAULT)");
    CHECK(ctx.state == SerialState::S_OPEN,
          "reconciled reopen lands in OPEN");
    CHECK(core.port_state.load(std::memory_order_acquire) ==
              static_cast<std::uint16_t>(SerialState::S_OPEN),
          "reconciled reopen publishes OPEN");
    CHECK(core.fault_pending.load(std::memory_order_acquire) == 0U,
          "the latch is consumed by the reconciliation");
}

// A normal Fault signal (control pool had room) clears the latch on entry so it
// cannot re-trigger a second Fault edge on the next lifecycle event.
void test_fault_clears_latch()
{
    reset_hooks();

    CoreCtx core{};
    install_hooks(core);
    core.port_state.store(XCOM_PORT_OPEN, std::memory_order_release);
    core.fault_pending.store(1U, std::memory_order_release);

    SerialCtx ctx{};
    ctx.core = &core;
    ctx.state = SerialState::S_OPEN;

    coact::Event evt{};
    xcom::serial_do_fault(ctx, evt);

    CHECK(ctx.state == SerialState::S_FAULT, "Fault edge lands in FAULT");
    CHECK(g_close_calls == 1, "Fault edge releases the handle");
    CHECK(core.fault_pending.load(std::memory_order_acquire) == 0U,
          "processing the Fault clears the latch");
}

// A close after a latched fault releases the handle (kClose/kCloseDone run
// owner_close) and clears the latch, so it cannot fire on a later event.
void test_close_clears_latch()
{
    reset_hooks();

    CoreCtx core{};
    install_hooks(core);
    core.port_state.store(XCOM_PORT_FAULT, std::memory_order_release);
    core.fault_pending.store(1U, std::memory_order_release);

    SerialCtx ctx{};
    ctx.core = &core;
    ctx.state = SerialState::S_OPEN;

    coact::Event evt{};
    xcom::serial_do_close(ctx, evt);

    CHECK(ctx.state == SerialState::S_CLOSED, "close lands CLOSED");
    CHECK(g_close_calls == 1, "close releases the handle");
    CHECK(core.fault_pending.load(std::memory_order_acquire) == 0U,
          "close clears the latched fault");
}

}  // namespace

int main()
{
    test_reopen_releases_latched_fault();
    test_fault_clears_latch();
    test_close_clears_latch();

    if (g_failures != 0) {
        std::fprintf(stderr, "%d check(s) failed\n", g_failures);
        return 1;
    }
    std::printf("fault latch reconcile: all checks passed\n");
    return 0;
}
