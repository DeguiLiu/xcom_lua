// diagnostic.hpp - XCOM diagnostic log writer built on coact::diag.
//
// task #5: a Windows writer adapter over the frozen header-only
// coact::diag::Logger (xcom_core/framework/coact/include/coact/diag/log.hpp). The Logger is
// the platform-independent core (two CS-guarded lanes, admission-only drop,
// QPC counter, wake hooks); this TU supplies the Windows-specific FILE* sink,
// the QPC clock, an auto-reset wake event and a dedicated writer thread. It
// deliberately does NOT use log_rtthread.hpp because that adapter depends on
// rtthread.h, which is unavailable on the Windows host.
//
// Producer path (runs on the coact Dispatcher / timer / hotplug threads) only
// pushes a 24-byte binary record + SetEvent(wake); it never does file I/O, so
// a slow disk cannot block the receive callback. The writer thread does all the
// FILE I/O and rotates the file when it exceeds a size bound.
//
// SPDX-License-Identifier: MIT
#pragma once
#ifndef XCOM_DIAGNOSTIC_HPP_
#define XCOM_DIAGNOSTIC_HPP_

#include <cstdint>

#include "coact/diag/log.hpp"
#include "coact/pal.hpp"

namespace xcom {

// Logical diagnostic event ids (1-based to match coact EventId != 0 contract).
// The writer maps each id to a compile-time {level, catalog event_id} so the
// record path stays template-gated per coact::diag.
enum class DiagEvent : uint16_t {
    kOpenOk = 1,
    kOpenFail = 2,
    kCloseOk = 3,
    kFault = 4,
    kWriteFail = 5,
    kRxDrop = 6,       // rx_pool_exhausted / oversize accounting
    kTxRejected = 7,
    kErrPushed = 8,    // any error-ring entry
    kDiagTick = 9,     // periodic heartbeat snapshot (DiagnosticAo)
    kDiagStart = 10,   // writer started / configured
    kDiagRotate = 11,  // file rotated on size bound
};

struct CoreCtx;

// Windows writer adapter (NOT thread-safe for its own thread; producers only
// call emit which is Logger-internal-CS-safe).
class DiagnosticWriter {
public:
    DiagnosticWriter();
    ~DiagnosticWriter();
    DiagnosticWriter(const DiagnosticWriter&) = delete;
    DiagnosticWriter& operator=(const DiagnosticWriter&) = delete;

    // Bind the logger + launch the writer thread. Path default "xcom_diag.log"
    // in the CWD, overridable via XCOM_DIAG_LOG (non-empty) and disabled via
    // XCOM_DIAG_DISABLE=1. Returns false if the thread could not start (the
    // logger is then left disabled and emit becomes a no-op).
    bool start(CoreCtx* core) noexcept;
    void shutdown() noexcept;

    // Non-blocking producer entry. No-ops before bind()/after shutdown().
    void emit(DiagEvent ev, uint16_t source, uint32_t a0 = 0U, uint32_t a1 = 0U,
              uint32_t a2 = 0U, uint32_t a3 = 0U) noexcept;

    bool enabled() const noexcept { return bound_; }

private:
    struct Impl;
    Impl* impl_ = nullptr;

    bool bound_ = false;
};

}  // namespace xcom

#endif /* XCOM_DIAGNOSTIC_HPP_ */
