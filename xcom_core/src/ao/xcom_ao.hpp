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
    // It is retried after the CoreWorker drains a display batch; it is never
    // converted into ui_trimmed_bytes merely because the UI is briefly slow.
    RxDesc deferred{};
    bool has_deferred = false;
};

// Write the `[HH:MM:SS.mmm] ` timestamp prefix (15 bytes) into `out` when the
// `timestamp` display option is enabled. Returns the number of chars written
// (0 when disabled). Defined in xcom_ao.cpp.
uint32_t rx_timestamp_prefix(const CoreCtx* core, uint8_t* out) noexcept;

// Format one received block [bytes..bytes+len) into the display lane per the
// current view. The block is released by the caller. Defined in xcom_ao.cpp.
bool rx_format_block(RxCtx* self, const uint8_t* bytes, uint32_t len);

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
// DiagnosticAo - periodic snapshot / heartbeat accounting.
// ---------------------------------------------------------------------------
struct DiagCtx {
    CoreCtx* core = nullptr;
};

// Periodic heartbeat: surface key saturated counters. Defined in xcom_ao.cpp.
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
// SerialAo - the single owner of the port. HSM: Closed/Open/Fault (a
// documented simplification of the plan's Closed/Opening/Open/Closing/Fault;
// Opening/Closing are short-lived intermediate states driven off the same
// owner thread and the authoritative reflection of the port is the CoreCtx
// port_state atomic). It owns lifecycle/configuration; SessionWriter is the
// only caller of potentially blocking native serial writes.
// ---------------------------------------------------------------------------
struct SerialCtx {
    CoreCtx* core = nullptr;
};

enum SerialState : int8_t {
    S_ROOT = 0,
    S_CLOSED = 1,
    S_OPEN = 2,
    S_FAULT = 3
};

// SIG_OPEN: transition Closed -> Open (or Fault on a failed real open) and
// claim the session generation. Defined in xcom_ao.cpp.
void serial_do_open(SerialCtx& ctx, const coact::Event& evt) noexcept;

// SIG_CLOSE: transition back to Closed and advance the generation. Defined in
// xcom_ao.cpp.
void serial_do_close(SerialCtx& ctx, const coact::Event& evt) noexcept;

// SIG_FAULT: transition Closed/Open -> Fault and reflect the fault in the
// port_state atomic (and error ring). Defined in xcom_ao.cpp.
void serial_do_fault(SerialCtx& ctx, const coact::Event& evt) noexcept;

struct SerialTraits {
    static constexpr uint64_t kRtcBudgetNs = 2000000ULL;   // 2 ms
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
