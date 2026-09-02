// xcom_config.hpp - coact configuration and XCOM constants for xcom_core.
// SPDX-License-Identifier: MIT
#pragma once
#ifndef XCOM_CONFIG_HPP_
#define XCOM_CONFIG_HPP_

#include <cstdint>

#include "coact/config.hpp"

namespace xcom {

// coact configuration: High=32 / Normal=64 / Low=32, BatchSizeMax=8,
// LowMaxWaitMs=100. Receive wake, close, and device-fault work use High with
// EventQos::critical=true, protected by the High critical reserve.
struct XcomCoactConfig : coact::DefaultConfig {
    static constexpr std::uint16_t kHighCapacity = 32U;
    static constexpr std::uint16_t kNormalCapacity = 64U;
    static constexpr std::uint16_t kLowCapacity = 32U;
    static constexpr std::uint16_t kCooldownCycles = 100U;
    static constexpr std::uint16_t kHighCriticalReserve = 16U;
    static constexpr std::uint16_t kNormalReservedCapacity = 0U;
    static constexpr std::uint32_t kBatchTimeoutMs = 5U;
    static constexpr std::uint32_t kLowMaxWaitMs = 100U;
    static constexpr std::uint32_t kDispatcherStackBytes = 65536U;
};

// Resource budgets (design §4). These are quantities, not enum variants.
//
// Ring capacities MUST remain powers of two (SpscRing uses a mask).  The RX
// pool and display lane are sized for the peak supported baud (921600 ≈ 90
// KiB/s) with several seconds of headroom, so a smaller pool never drops data
// for the 10 ms drain cadence; it only bounds the transient backlog that can
// accumulate while the consumer thread is briefly descheduled.
inline constexpr std::uint32_t kRxBlockCount = 128U;  // 128 × 4 KiB = 512 KiB
inline constexpr std::uint32_t kRxBlockBytes = 4096U;
inline constexpr std::uint32_t kSerialReadBufferBytes =
    kRxBlockCount * kRxBlockBytes;
inline constexpr std::uint32_t kTxBlockCount = 32U;
inline constexpr std::uint32_t kTxBlockBytes = 4096U;
inline constexpr std::uint32_t kDisplayBatchCount = 32U;  // 32 × 16 KiB = 512 KiB
inline constexpr std::uint32_t kDisplayBatchBytes = 16384U;
inline constexpr std::uint32_t kErrorRingCount = 128U;

enum class Signal : std::uint16_t {
    RxKick = 1U,   // static event -> ReceiveAo (High/critical); wake bridge
    Send = 2U,     // typed TxDescriptor -> SendAo (Normal)
    Autosend = 3U, // -> AutoSendAo (Low); coalesced by AutoTickGate
    Open = 4U,     // -> SerialAo (High)
    Close = 5U,    // -> SerialAo (High, critical)
    OpenDone = 6U,
    CloseDone = 7U,
    AutosendConfig = 8U, // typed template -> AutoSendAo (Low)
    // 9 remains unassigned: v1.2 routes typed user Tx directly to SendAo.
    Fault = 10U,
    Diag = 11U     // -> DiagnosticAo (Low)
};

[[nodiscard]] constexpr std::uint16_t to_signal(Signal signal) noexcept
{
    return static_cast<std::uint16_t>(signal);
}

// EventPool block sizing for low-rate control events (Open/Close/Send/write).
inline constexpr std::uint16_t kCtlBlockSize = 128U;
inline constexpr std::uint16_t kCtlPoolCapacity = 32U;

enum class LogicalPriority : std::uint8_t {
    Serial = 40U,
    Send = 31U,
    Receive = 30U,
    Autosend = 20U,
    Diag = 10U
};

[[nodiscard]] constexpr std::uint8_t
to_priority(LogicalPriority priority) noexcept
{
    return static_cast<std::uint8_t>(priority);
}

// Fixed AO TargetIds (registry 1-based).
inline constexpr std::uint8_t kTargetSerial = 1U;
inline constexpr std::uint8_t kTargetReceive = 2U;
inline constexpr std::uint8_t kTargetSend = 3U;
inline constexpr std::uint8_t kTargetDiag = 4U;
inline constexpr std::uint8_t kTargetAutoSend = 5U;

}  // namespace xcom

#endif /* XCOM_CONFIG_HPP_ */
