// xcom_ao.hpp - XCOM Active Objects built on coact.
//
// SerialAo / ReceiveAo / SendAo / DiagnosticAo are coact Ao<Ctx, Hsm, Traits>
// instances. They share a non-template CoreCtx; all cross-AO submission goes
// through CoreCtx::submit_rx_kick() / submit_control() which xcom_core.cpp maps
// to the concrete coact Runtime's coordinator.
//
// The concrete StateDef/TransitionDef tables and the Ao instances themselves are
// constructed in xcom_core.cpp. The AO context structs, the SerialAo HSM state
// enum, the AO Traits and the DECLARATIONS of the action callbacks live here;
// the action bodies are compiled once in xcom_ao.cpp (compilation isolation:
// editing an action no longer recompiles every TU that includes this header,
// and the coact/hsm.hpp inline machinery is only pulled by the TUs that build
// the tables).
//
// SPDX-License-Identifier: MIT
#pragma once
#ifndef XCOM_AO_HPP_
#define XCOM_AO_HPP_

#include <cstdint>

#include "coact/event.hpp"

#include <xcom/xcom.h>   // XCOM_PORT_* / XcomStatus constants

#include "xcom_config.hpp"
#include "xcom_core.hpp"

namespace xcom {

// ---------------------------------------------------------------------------
// ReceiveAo - formats Rx blocks into display batches on the Dispatcher.
// ---------------------------------------------------------------------------
struct RxCtx {
    CoreCtx* core = nullptr;
    // A block that could not enter DisplayLane remains owned by ReceiveAo.
    // It is retried after the ABI drain caller (the Lua UI thread) drains a
    // display batch; it is never converted into ui_trimmed_bytes merely because
    // the UI is briefly slow.
    RxDesc deferred{};
    bool has_deferred = false;
};

// Format one received block [bytes..bytes+len) into the display lane per the
// current view.  `ingress_ms` is the block's arrival time (monotonic ms),
// carried onto the display descriptor for the Lua timestamp stage. `unlogged`
// is true when the source segment had no file lane, so the resulting display
// batch is the only copy of those bytes and a session-boundary reset must
// charge them to the loss ledger.  The block is released by the caller.  No
// timestamp text is injected.  Defined in xcom_ao.cpp.
bool rx_format_block(RxCtx* self, const uint8_t* bytes, uint32_t len,
                     uint32_t ingress_ms, bool unlogged);

// Handle a SIG_RX_KICK (P0 wake bridge): drain up to 4 blocks on the
// Dispatcher, then run the disarm -> acquire-recheck -> arm -> resubmit
// protocol so pending work is never left asleep and one kick never doubles.
// Defined in xcom_ao.cpp.
void rx_kick_action(RxCtx& ctx, const coact::Event& evt) noexcept;

struct RxTraits {
    static constexpr uint64_t kRtcBudgetNs = 500000ULL;   // 0.5 ms budget
    static coact::LogicalPrio logical_prio() noexcept
    {
        return static_cast<coact::LogicalPrio>(
            to_priority(LogicalPriority::Receive));
    }
    static coact::PriorityClass priority_class() noexcept
    {
        return coact::PriorityClass::High;
    }
    static bool direct_eligible() noexcept { return false; }
    static bool isr_direct_safe() noexcept { return true; }
};

// ---------------------------------------------------------------------------
// SendAo handles explicit user sends. AutoSendAo is deliberately separate so
// the target AO's fixed PriorityClass keeps timer work in the Low partition.
// ---------------------------------------------------------------------------
struct SendCtx {
    CoreCtx* core = nullptr;
    std::uint16_t autosend_block = 0xFFFFU;
    std::uint16_t autosend_length = 0U;
    std::uint32_t autosend_interval_ms = 0U;
};

void autosend_config_action(SendCtx& ctx, const coact::Event& evt) noexcept;
void send_autosend_action(SendCtx& ctx, const coact::Event& evt) noexcept;
void send_user_action(SendCtx& ctx, const coact::Event& evt) noexcept;

struct SendTraits {
    static constexpr uint64_t kRtcBudgetNs = 500000ULL;
    static coact::LogicalPrio logical_prio() noexcept
    {
        return static_cast<coact::LogicalPrio>(to_priority(LogicalPriority::Send));
    }
    static coact::PriorityClass priority_class() noexcept
    {
        return coact::PriorityClass::Normal;
    }
    static bool direct_eligible() noexcept { return false; }
    static bool isr_direct_safe() noexcept { return false; }
};

struct AutoSendTraits {
    static constexpr uint64_t kRtcBudgetNs = 500000ULL;
    static coact::LogicalPrio logical_prio() noexcept
    {
        return static_cast<coact::LogicalPrio>(
            to_priority(LogicalPriority::Autosend));
    }
    static coact::PriorityClass priority_class() noexcept
    {
        return coact::PriorityClass::Low;
    }
    static bool direct_eligible() noexcept { return false; }
    static bool isr_direct_safe() noexcept { return false; }
};

// ---------------------------------------------------------------------------
// DiagnosticAo - the periodic diag-tick sink.
//
// NOT CURRENTLY ARMED: nothing submits Signal::Diag, so diag_tick_action never
// runs and no periodic snapshot is emitted. The routing (Signal::Diag ->
// kTargetDiag), the Diag state table and the kDiagTick log record are kept as
// the wiring for a periodic snapshot; the counters themselves reach the client
// through XcomSnapshot polling. The dispatcher heartbeat does NOT depend on this
// path - beat_dispatcher() is also called from the SerialAo/ReceiveAo/SendAo
// actions in xcom_ao.cpp.
// ---------------------------------------------------------------------------
struct DiagCtx {
    CoreCtx* core = nullptr;
};

// The Diag target's only action. Defined in xcom_ao.cpp; currently unreachable
// because no code submits Signal::Diag (see above).
void diag_tick_action(DiagCtx& ctx, const coact::Event& evt) noexcept;

struct DiagTraits {
    static constexpr uint64_t kRtcBudgetNs = 200000ULL;
    static coact::LogicalPrio logical_prio() noexcept
    {
        return static_cast<coact::LogicalPrio>(to_priority(LogicalPriority::Diag));
    }
    static coact::PriorityClass priority_class() noexcept
    {
        return coact::PriorityClass::Low;
    }
    static bool direct_eligible() noexcept { return false; }
    static bool isr_direct_safe() noexcept { return false; }
};

// ---------------------------------------------------------------------------
// SerialAo - the single owner of the port and the SOLE authority for the port
// lifecycle. SerialCtx::state carries the full 5-state machine (Closed /
// Opening / Open / Closing / Fault); CoreCtx::port_state is a publish-only
// VIEW written exclusively by serial_transition() and never read as a guard.
// It owns lifecycle/configuration; SessionWriter is the only caller of
// potentially blocking native serial writes.
// ---------------------------------------------------------------------------
// Numeric values deliberately equal the XCOM_PORT_* ABI values so publishing
// the local state is a plain cast and any consumer sees the same encoding.
enum SerialState : int8_t {
    S_CLOSED = XCOM_PORT_CLOSED,     // 0
    S_OPENING = XCOM_PORT_OPENING,   // 1
    S_OPEN = XCOM_PORT_OPEN,         // 2
    S_CLOSING = XCOM_PORT_CLOSING,   // 3
    S_FAULT = XCOM_PORT_FAULT        // 4
};

static_assert(static_cast<int>(S_CLOSED) == XCOM_PORT_CLOSED, "state/ABI drift");
static_assert(static_cast<int>(S_OPENING) == XCOM_PORT_OPENING, "state/ABI drift");
static_assert(static_cast<int>(S_OPEN) == XCOM_PORT_OPEN, "state/ABI drift");
static_assert(static_cast<int>(S_CLOSING) == XCOM_PORT_CLOSING, "state/ABI drift");
static_assert(static_cast<int>(S_FAULT) == XCOM_PORT_FAULT, "state/ABI drift");

// Inputs accepted by serial_transition(). Open/Close/Fault arrive as coact
// signals; OpenDone/CloseDone complete the intermediate opening/closing states,
// and Cancel is the ABI's timed-out/close-request handoff.
enum class SerialEvent : uint8_t {
    kOpen = 0,
    kClose = 1,
    kFault = 2,
    kOpenDone = 3,
    kCloseDone = 4,
    kCancel = 5
};

struct SerialCtx {
    CoreCtx* core = nullptr;
    // AO-local authoritative port state. Only serial_transition() mutates it,
    // and only on the SerialAo thread (the coact Dispatcher).
    SerialState state = S_CLOSED;
};

// The one table-driven transition function (design §2.2). It resolves the
// (state, event) edge, runs the edge action and publishes port_state exactly
// once per transition; intermediate states are published on entry, before the
// blocking owner action. Unsupported (state, event) pairs leave the state
// unchanged and publish nothing. Defined in xcom_ao.cpp.
void serial_transition(SerialCtx& ctx, SerialEvent event) noexcept;

// coact action callbacks. Each delegates to serial_transition() rather than
// reading or writing port_state. Defined in xcom_ao.cpp.
void serial_do_open(SerialCtx& ctx, const coact::Event& evt) noexcept;
void serial_do_close(SerialCtx& ctx, const coact::Event& evt) noexcept;
void serial_do_fault(SerialCtx& ctx, const coact::Event& evt) noexcept;

struct SerialTraits {
    // Budget rule: the RTC budget must exceed the AO's DOCUMENTED worst-case
    // legitimate dispatch, not the other way round. This AO's own transition
    // contract (above) says the intermediate OPENING/CLOSING state is published
    // "before the blocking owner action", and the blocking owner actions are
    // documented: xcom_open polls its lifecycle result for ~2 s
    // (xcom_abi.cpp: 200 x 10 ms) and close reserves the same ~2 s budget
    // (serial_backend_win.hpp keeps kTxDrainGraceMs "well under the 2000 ms ABI
    // close budget"). A 2 ms budget therefore made EVERY legitimate open/close
    // over-budget; three in a row (idle open/close, or reconnect churn) pushed
    // the Breaker to BrokenL2 and started dropping user sends as
    // "buffer full". 5 s gives clear headroom over the ~2 s legal bound.
    //
    // This does not weaken the real protection. The Dispatcher measures elapsed
    // time only AFTER try_dispatch_queued() returns (dispatcher.hpp), so
    // rtc_timeout_consec advances only for a dispatch that COMPLETED slowly. An
    // AO that is truly wedged never returns, never reaches the measurement
    // point, and never advances this counter - detecting that is the heartbeat's
    // job (thread_health.hpp), not the Breaker's. The budget only has to
    // separate "slow but legal" from "returned pathologically late".
    static constexpr uint64_t kRtcBudgetNs = 5000000000ULL;   // 5 s > ~2 s legal
    static coact::LogicalPrio logical_prio() noexcept
    {
        return static_cast<coact::LogicalPrio>(
            to_priority(LogicalPriority::Serial));
    }
    static coact::PriorityClass priority_class() noexcept
    {
        return coact::PriorityClass::High;
    }
    static bool direct_eligible() noexcept { return false; }
    static bool isr_direct_safe() noexcept { return false; }
};

}  // namespace xcom

#endif /* XCOM_AO_HPP_ */
