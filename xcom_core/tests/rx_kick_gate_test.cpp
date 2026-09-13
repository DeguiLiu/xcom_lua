// rx_kick_gate_test.cpp - host test for the RxKickGate rejection contract.
//
// The receive display is driven by a single edge-triggered static SIG_RX_KICK
// event. The producer arms RxKickGate (0 -> 1) and then submits the wake; only
// ReceiveAo's rx_kick_action disarms it. If the scheduler REFUSES the submit
// (High ring full -> RejectedFull, or a closed/saturated submission admission ->
// RejectedState) and the latch is left armed, no later kick is ever submitted:
// display_ready fills while the view stops refreshing forever - a silent
// blackhole with live data.
//
// This test pins the invariant at the exact seam that owns it, CoreCtx's sink
// wrapper + gate, with a fake sink that reports acceptance or refusal. It needs
// no real Dispatcher, no serial port and no threads.
//
// Mutation that must make it fail: delete `kick_gate.disarm();` from the
// refusal path of CoreCtx::submit_rx_kick() (xcom_core.hpp). Then a refused wake
// leaves the gate armed and test_rejected_wake_releases_gate fails on
// `!armed()`, i.e. the regression is caught at the unit level.
//
// Reverting the sink's bool return type to void also fails to compile, which is
// the second guard: the caller must be able to learn the submit was refused.
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

std::uint32_t g_accept_calls = 0U;

bool fake_accept(CoreCtx*) noexcept
{
    ++g_accept_calls;
    return true;
}

bool fake_reject(CoreCtx*) noexcept
{
    return false;
}

// A refused submit means no wake is in flight. The gate MUST be released, and a
// later arrival MUST be able to arm and submit again - otherwise the receive
// display latches dead while data keeps arriving.
void test_rejected_wake_releases_gate(CoreCtx& core)
{
    core.sink.submit_rx_kick = &fake_reject;
    core.kick_gate.disarm();

    CHECK(core.kick_gate.try_arm(), "producer arms the gate");
    CHECK(!core.submit_rx_kick(), "refused submit is reported as not accepted");
    CHECK(!core.kick_gate.armed(),
          "a refused wake releases the gate (no armed-without-kick latch)");
    CHECK(core.kick_gate.try_arm(),
          "the next arrival can re-arm after a refusal");

    // Recovery: the re-armed gate's next submit is accepted and the wake is
    // owned by ReceiveAo (gate stays armed until rx_kick_action disarms it).
    core.sink.submit_rx_kick = &fake_accept;
    CHECK(core.submit_rx_kick(), "the retried wake is accepted");
    CHECK(core.kick_gate.armed(), "accepted wake leaves disarming to ReceiveAo");
    core.kick_gate.disarm();
}

// An accepted submit keeps the latch armed until ReceiveAo drains (that is the
// existing close-drain protocol); only then may the next producer arm.
void test_accepted_wake_keeps_gate_until_drained(CoreCtx& core)
{
    core.sink.submit_rx_kick = &fake_accept;
    core.kick_gate.disarm();

    CHECK(core.kick_gate.try_arm(), "producer arms the gate");
    CHECK(core.submit_rx_kick(), "accepted submit reports success");
    CHECK(core.kick_gate.armed(), "in-flight wake keeps the gate armed");

    core.kick_gate.disarm();  // ReceiveAo rx_kick_action drains and disarms
    CHECK(!core.kick_gate.armed(), "ReceiveAo disarm releases the latch");
}

// The gate is edge-triggered: a second producer while armed must NOT submit a
// duplicate wake (the call sites skip submit when try_arm is false).
void test_armed_gate_is_edge_triggered(CoreCtx& core)
{
    core.sink.submit_rx_kick = &fake_accept;
    core.kick_gate.disarm();
    g_accept_calls = 0U;

    CHECK(core.kick_gate.try_arm(), "first producer arms the gate");
    CHECK(core.submit_rx_kick(), "first wake submitted");
    CHECK(!core.kick_gate.try_arm(),
          "second producer cannot re-arm while a wake is in flight");
    CHECK(g_accept_calls == 1U, "exactly one wake submitted per edge");

    core.kick_gate.disarm();
    CHECK(core.kick_gate.try_arm(), "a new edge can arm after drain");
    CHECK(core.submit_rx_kick(), "wake submitted for the new edge");
    CHECK(g_accept_calls == 2U, "second edge submits exactly one more wake");
    core.kick_gate.disarm();
}

// No sink installed is also a refusal: the gate must not stay latched.
void test_missing_sink_releases_gate(CoreCtx& core)
{
    core.sink.submit_rx_kick = nullptr;
    core.kick_gate.disarm();

    CHECK(core.kick_gate.try_arm(), "producer arms the gate");
    CHECK(!core.submit_rx_kick(), "missing sink reports not accepted");
    CHECK(!core.kick_gate.armed(), "missing sink releases the gate");
}

}  // namespace

int main()
{
    // CoreCtx embeds the 128 x 4 KiB RX pool and the 32 x 16 KiB display lane;
    // keep it off the stack.
    static xcom::CoreCtx core;

    test_rejected_wake_releases_gate(core);
    test_accepted_wake_keeps_gate_until_drained(core);
    test_armed_gate_is_edge_triggered(core);
    test_missing_sink_releases_gate(core);

    if (g_failures != 0) {
        std::fprintf(stderr, "%d check(s) failed\n", g_failures);
        return 1;
    }
    std::printf("rx_kick_gate_test: all checks passed\n");
    return 0;
}
