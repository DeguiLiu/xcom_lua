// serial_transition_test.cpp - host test for the SerialAo lifecycle matrix.
//
// This exercises the one table-driven transition function
// (xcom::serial_transition) cell by cell. It is Win32-free: xcom_ao.cpp compiles
// against tools/win32-stub and links with a host definition of
// coact::pal::monotonic_ms, so the (state, event) table and its publish
// behaviour can be checked on Linux. Build it directly with g++ on the two
// translation units (serial_transition_test.cpp + src/ao/xcom_ao.cpp), the
// include paths in xcom_core/CMakeLists.txt's xcom_serial_transition_test
// target, and -pthread.
//
// It asserts, for every (state, event) pair, the final AO state and whether
// port_state was published; for the cells that run an owner action it also
// pins the owner_open/owner_close call counts. It additionally covers the two
// latch-compensated "no edge" cells (CLOSED x Close, OPENING x Close) at the
// serial_do_* level, the open-cancellation convergence, and the
// diagnostic-only fault handling. The real Win32 serial backend, the Dispatcher
// and xcom_close's CLOSED poll are not reachable here (see the report).
//
// SPDX-License-Identifier: MIT
#include "xcom_ao.hpp"

#include "coact/event.hpp"
#include "coact/pal_windows.hpp"

#include <atomic>
#include <cstdint>
#include <cstdio>

// xcom_ao.cpp's beat_dispatcher() calls coact::pal::monotonic_ms(), whose real
// definition lives in coact's Win32 PAL. The transition matrix never needs a
// clock, so a constant host definition completes the link.
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

constexpr std::uint16_t kNoPublish = 0x55AAU;

int g_failures = 0;

#define CHECK(cond, msg)                                                     \
    do {                                                                     \
        if (!(cond)) {                                                       \
            std::fprintf(stderr, "FAIL: %s (%s:%d)\n", msg, __FILE__,        \
                         __LINE__);                                          \
            ++g_failures;                                                    \
        }                                                                    \
    } while (0)

// ---- action hooks ---------------------------------------------------------

// The AO-local state the close action observes when it runs. On a
// publish_first edge the target is published BEFORE the action, so this proves
// the publish ordering (and, for the Cancel fallback, the two-step
// CLOSING-then-FAULT sequence) rather than only the final state.
SerialCtx* g_ctx = nullptr;
int g_close_observed_state = -1;

int g_open_calls = 0;
int g_close_calls = 0;
int g_submit_calls = 0;
bool g_submit_ok = true;
std::int32_t g_owner_open_result = XCOM_ERR_IO;

void hook_open(CoreCtx* core)
{
    ++g_open_calls;
    core->last_open_result.store(g_owner_open_result,
                                 std::memory_order_release);
}

void hook_close(CoreCtx* /*core*/)
{
    ++g_close_calls;
    if (g_ctx != nullptr) {
        g_close_observed_state = static_cast<int>(g_ctx->state);
    }
}

bool hook_submit(CoreCtx* /*core*/, std::uint16_t /*signal*/,
                 std::uint32_t /*word*/, bool /*critical*/)
{
    ++g_submit_calls;
    return g_submit_ok;
}

void reset_hooks()
{
    g_ctx = nullptr;
    g_close_observed_state = -1;
    g_open_calls = 0;
    g_close_calls = 0;
    g_submit_calls = 0;
    g_submit_ok = true;
    g_owner_open_result = XCOM_ERR_IO;
}

void install_hooks(CoreCtx& core)
{
    core.sink.owner_open = &hook_open;
    core.sink.owner_close = &hook_close;
    core.sink.submit_control = &hook_submit;
}

// ---- matrix ---------------------------------------------------------------

struct Cell {
    SerialState from;
    SerialEvent event;
    SerialState expect_state;
    bool expect_publish;
    int expect_open;
    int expect_close;
    bool submit_ok = true;
    std::int32_t pre_open_result = XCOM_ERR_IO;
    int expect_close_observed = -1;   // -1 = not checked
};

void run_cell(const Cell& c)
{
    reset_hooks();
    g_submit_ok = c.submit_ok;
    g_owner_open_result = c.pre_open_result;

    CoreCtx core{};
    install_hooks(core);
    core.port_state.store(kNoPublish, std::memory_order_release);
    core.last_open_result.store(c.pre_open_result, std::memory_order_release);

    SerialCtx ctx{};
    ctx.core = &core;
    ctx.state = c.from;
    g_ctx = &ctx;

    xcom::serial_transition(ctx, c.event);

    const std::uint16_t published =
        core.port_state.load(std::memory_order_acquire);
    const std::uint16_t expected_publish =
        c.expect_publish ? static_cast<std::uint16_t>(c.expect_state)
                         : kNoPublish;
    const bool observed_ok =
        (c.expect_close_observed < 0) ||
        (g_close_observed_state == c.expect_close_observed);
    if (ctx.state != c.expect_state || published != expected_publish ||
        g_open_calls != c.expect_open || g_close_calls != c.expect_close ||
        false == observed_ok) {
        std::fprintf(stderr,
                     "FAIL cell (%d,%d): state=%d/%d publish=%u/%u "
                     "open=%d/%d close=%d/%d observed=%d/%d\n",
                     static_cast<int>(c.from), static_cast<int>(c.event),
                     static_cast<int>(ctx.state),
                     static_cast<int>(c.expect_state), published,
                     expected_publish, g_open_calls, c.expect_open,
                     g_close_calls, c.expect_close, g_close_observed_state,
                     c.expect_close_observed);
        ++g_failures;
    }
}

void test_matrix()
{
    const Cell kCells[] = {
        // CLOSED
        {SerialState::S_CLOSED, SerialEvent::kOpen, SerialState::S_OPENING,
         true, 1, 0},
        {SerialState::S_CLOSED, SerialEvent::kClose, SerialState::S_CLOSED,
         false, 0, 0},   // L: ABI short-circuits; no edge here
        {SerialState::S_CLOSED, SerialEvent::kFault, SerialState::S_CLOSED,
         false, 0, 0},   // no session -> diagnostic only, never FAULT
        {SerialState::S_CLOSED, SerialEvent::kOpenDone, SerialState::S_CLOSED,
         false, 0, 0},
        {SerialState::S_CLOSED, SerialEvent::kCloseDone, SerialState::S_CLOSED,
         false, 0, 0},
        {SerialState::S_CLOSED, SerialEvent::kCancel, SerialState::S_CLOSED,
         false, 0, 0},
        // OPENING
        {SerialState::S_OPENING, SerialEvent::kOpen, SerialState::S_OPENING,
         false, 0, 0},
        {SerialState::S_OPENING, SerialEvent::kClose, SerialState::S_OPENING,
         false, 0, 0},   // L: latch converts this to Cancel at owner completion
        {SerialState::S_OPENING, SerialEvent::kFault, SerialState::S_FAULT,
         true, 0, 1, true, XCOM_ERR_IO, 4},   // publish FAULT before teardown
        {SerialState::S_OPENING, SerialEvent::kOpenDone, SerialState::S_OPEN,
         true, 0, 0, true, XCOM_OK},
        {SerialState::S_OPENING, SerialEvent::kOpenDone, SerialState::S_CLOSED,
         true, 0, 0, true, XCOM_ERR_IO},
        {SerialState::S_OPENING, SerialEvent::kCloseDone,
         SerialState::S_OPENING, false, 0, 0},
        {SerialState::S_OPENING, SerialEvent::kCancel, SerialState::S_CLOSING,
         true, 0, 0},
        {SerialState::S_OPENING, SerialEvent::kCancel, SerialState::S_FAULT,
         true, 0, 1, false, XCOM_ERR_IO,
         3},   // publishes CLOSING, then falls back to FAULT after the action
        // OPEN
        {SerialState::S_OPEN, SerialEvent::kOpen, SerialState::S_OPEN, false, 0,
         0},
        {SerialState::S_OPEN, SerialEvent::kClose, SerialState::S_CLOSING, true,
         0, 1, true, XCOM_ERR_IO, 3},   // CLOSING published before owner_close
        {SerialState::S_OPEN, SerialEvent::kFault, SerialState::S_FAULT, true,
         0, 1, true, XCOM_ERR_IO, 4},   // FAULT published before owner_close
        {SerialState::S_OPEN, SerialEvent::kOpenDone, SerialState::S_OPEN,
         false, 0, 0},
        {SerialState::S_OPEN, SerialEvent::kCloseDone, SerialState::S_OPEN,
         false, 0, 0},
        {SerialState::S_OPEN, SerialEvent::kCancel, SerialState::S_OPEN, false,
         0, 0},
        // CLOSING
        {SerialState::S_CLOSING, SerialEvent::kOpen, SerialState::S_CLOSING,
         false, 0, 0},
        {SerialState::S_CLOSING, SerialEvent::kClose, SerialState::S_CLOSING,
         true, 0, 1, true, XCOM_ERR_IO, 3},   // re-entrant, owner_close idempotent
        {SerialState::S_CLOSING, SerialEvent::kFault, SerialState::S_CLOSED,
         true, 0, 1, true, XCOM_ERR_IO,
         0},   // CLOSED published before owner_close; close intent satisfied
        {SerialState::S_CLOSING, SerialEvent::kOpenDone, SerialState::S_CLOSING,
         false, 0, 0},
        {SerialState::S_CLOSING, SerialEvent::kCloseDone, SerialState::S_CLOSED,
         true, 0, 0},
        {SerialState::S_CLOSING, SerialEvent::kCancel, SerialState::S_CLOSING,
         false, 0, 0},
        // FAULT
        {SerialState::S_FAULT, SerialEvent::kOpen, SerialState::S_OPENING,
         true, 1, 0},
        {SerialState::S_FAULT, SerialEvent::kClose, SerialState::S_CLOSING,
         true, 0, 1, true, XCOM_ERR_IO, 3},   // CLOSING published before teardown
        {SerialState::S_FAULT, SerialEvent::kFault, SerialState::S_FAULT, false,
         0, 0},
        {SerialState::S_FAULT, SerialEvent::kOpenDone, SerialState::S_FAULT,
         false, 0, 0},
        {SerialState::S_FAULT, SerialEvent::kCloseDone, SerialState::S_FAULT,
         false, 0, 0},
        {SerialState::S_FAULT, SerialEvent::kCancel, SerialState::S_FAULT,
         false, 0, 0},
    };
    for (const Cell& c : kCells) {
        run_cell(c);
    }
}

// ---- serial_do_* level: latch compensation and convergence ----------------

// Open completes successfully while the ABI has already asked to close (the
// OPENING x Close latch): the AO takes OPENING --Cancel--> CLOSING and the
// pending Close signal then drives CLOSING -> CLOSED.
void test_open_cancel_converges_closed()
{
    reset_hooks();
    g_owner_open_result = XCOM_OK;

    CoreCtx core{};
    install_hooks(core);
    core.port_state.store(kNoPublish, std::memory_order_release);
    core.cancel_open.store(1U, std::memory_order_release);

    SerialCtx ctx{};
    ctx.core = &core;
    ctx.state = SerialState::S_CLOSED;
    g_ctx = &ctx;

    coact::Event evt{};
    xcom::serial_do_open(ctx, evt);
    CHECK(ctx.state == SerialState::S_CLOSING, "cancel during open -> CLOSING");
    CHECK(core.port_state.load(std::memory_order_acquire) ==
              static_cast<std::uint16_t>(SerialState::S_CLOSING),
          "cancel during open publishes CLOSING");
    CHECK(g_open_calls == 1, "cancel during open ran owner_open once");
    CHECK(g_submit_calls == 1, "cancel during open requested a critical Close");

    // The Dispatcher then runs the Close signal the cancel edge submitted.
    xcom::serial_do_close(ctx, evt);
    CHECK(ctx.state == SerialState::S_CLOSED,
          "cancel then close converges to CLOSED");
    CHECK(core.port_state.load(std::memory_order_acquire) ==
              static_cast<std::uint16_t>(SerialState::S_CLOSED),
          "converged close publishes CLOSED");
    CHECK(g_close_observed_state == static_cast<int>(SerialState::S_CLOSING),
          "converged close publishes CLOSING before owner_close");
}

// Failed owner_open: OPENING -> CLOSED (no session was ever established).
void test_failed_open_lands_closed()
{
    reset_hooks();
    g_owner_open_result = XCOM_ERR_IO;

    CoreCtx core{};
    install_hooks(core);
    core.port_state.store(kNoPublish, std::memory_order_release);

    SerialCtx ctx{};
    ctx.core = &core;
    ctx.state = SerialState::S_CLOSED;

    coact::Event evt{};
    xcom::serial_do_open(ctx, evt);
    CHECK(ctx.state == SerialState::S_CLOSED, "failed open lands CLOSED");
    CHECK(core.port_state.load(std::memory_order_acquire) ==
              static_cast<std::uint16_t>(SerialState::S_CLOSED),
          "failed open publishes CLOSED, never FAULT");
    CHECK(g_close_calls == 0, "failed open never ran owner_close");
}

// A Close on an already-CLOSED port has no edge (the ABI short-circuits it);
// serial_do_close must still be a no-op and publish nothing.
void test_close_on_closed_is_noop()
{
    reset_hooks();
    CoreCtx core{};
    install_hooks(core);
    core.port_state.store(kNoPublish, std::memory_order_release);

    SerialCtx ctx{};
    ctx.core = &core;
    ctx.state = SerialState::S_CLOSED;

    coact::Event evt{};
    xcom::serial_do_close(ctx, evt);
    CHECK(ctx.state == SerialState::S_CLOSED, "CLOSED x Close stays CLOSED");
    CHECK(core.port_state.load(std::memory_order_acquire) == kNoPublish,
          "CLOSED x Close publishes nothing");
    CHECK(g_close_calls == 0, "CLOSED x Close never runs owner_close");
}

// A late fault report while CLOSED must not publish FAULT; it is recorded as a
// diagnostic only. A repeated fault while already FAULT stays deduplicated.
void test_fault_diagnostics()
{
    reset_hooks();
    CoreCtx core{};
    install_hooks(core);
    core.port_state.store(kNoPublish, std::memory_order_release);

    SerialCtx ctx{};
    ctx.core = &core;
    ctx.state = SerialState::S_CLOSED;

    coact::Event evt{};
    xcom::serial_do_fault(ctx, evt);
    CHECK(ctx.state == SerialState::S_CLOSED, "CLOSED x Fault stays CLOSED");
    CHECK(core.port_state.load(std::memory_order_acquire) == kNoPublish,
          "CLOSED x Fault publishes nothing");
    CHECK(g_close_calls == 0, "CLOSED x Fault never runs owner_close");
    CHECK(core.errors.take().has_value(),
          "CLOSED x Fault still records the device-gone diagnostic");

    // Re-entering the same diagnostic must not duplicate the visible fault.
    ctx.state = SerialState::S_FAULT;
    xcom::serial_do_fault(ctx, evt);
    CHECK(ctx.state == SerialState::S_FAULT, "repeated FAULT x Fault no-ops");
    CHECK(false == core.errors.take().has_value(),
          "repeated FAULT x Fault pushes no second diagnostic");
}

// A fault during CLOSING releases the handle and lands CLOSED (a completed
// close), not FAULT (which would time out xcom_close's CLOSED poll).
void test_fault_during_closing()
{
    reset_hooks();
    CoreCtx core{};
    install_hooks(core);
    core.port_state.store(kNoPublish, std::memory_order_release);

    SerialCtx ctx{};
    ctx.core = &core;
    ctx.state = SerialState::S_CLOSING;
    g_ctx = &ctx;

    coact::Event evt{};
    xcom::serial_do_fault(ctx, evt);
    CHECK(ctx.state == SerialState::S_CLOSED,
          "CLOSING x Fault lands CLOSED (close succeeded)");
    CHECK(g_close_observed_state == static_cast<int>(SerialState::S_CLOSED),
          "CLOSING x Fault publishes CLOSED before releasing the handle");
    CHECK(core.port_state.load(std::memory_order_acquire) ==
              static_cast<std::uint16_t>(SerialState::S_CLOSED),
          "CLOSING x Fault publishes CLOSED");
    CHECK(g_close_calls == 1, "CLOSING x Fault releases the handle");
    CHECK(core.errors.take().has_value(),
          "CLOSING x Fault records the device-gone diagnostic");
}

}  // namespace

int main()
{
    test_matrix();
    test_open_cancel_converges_closed();
    test_failed_open_lands_closed();
    test_close_on_closed_is_noop();
    test_fault_diagnostics();
    test_fault_during_closing();

    if (g_failures != 0) {
        std::fprintf(stderr, "%d check(s) failed\n", g_failures);
        return 1;
    }
    std::printf("serial transition matrix: all checks passed\n");
    return 0;
}
