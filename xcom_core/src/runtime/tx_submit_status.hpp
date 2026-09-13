// tx_submit_status.hpp - map a coact submit disposition to the status that
// xcom_send returns, so a caller can tell WHY a send was rejected.
//
// The collapse this header exists to prevent: the Send AO path used to return a
// bare bool, and xcom_send reported every rejection as XCOM_ERR_FULL ("TxBlockPool
// / dispatcher queue full"). That is wrong for the overload Breaker: when the
// Send AO's breaker degrades to BrokenL2 the coordinator drops every
// non-critical event (the manual sends) while the TxBlockPool may be completely
// empty. Telling the user "buffer full" makes them throttle a send path that was
// never under buffer pressure.
//
// The two signals are distinct on purpose:
//   - XCOM_ERR_FULL: a pool or the dispatcher's own queue is out of capacity.
//     The caller really is producing faster than the pipeline drains; reducing
//     the send rate is the right response.
//   - XCOM_ERR_BUSY: the scheduler refused the event (breaker downgrade / state
//     / policy). This is transient and unrelated to capacity. BUSY shares its
//     code with "open in progress", which is likewise a retryable refusal.
//
// Win32-free on purpose: tests/tx_submit_status_test.cpp compiles this header
// with a plain g++ on Linux.
//
// SPDX-License-Identifier: MIT
#pragma once
#ifndef XCOM_TX_SUBMIT_STATUS_HPP_
#define XCOM_TX_SUBMIT_STATUS_HPP_

#include <coact/config.hpp>
#include <xcom/xcom.h>

namespace xcom {

inline XcomStatus tx_submit_status(coact::SubmitDisposition disposition) noexcept
{
    switch (disposition) {
    case coact::SubmitDisposition::Direct:
    case coact::SubmitDisposition::Queued:
    case coact::SubmitDisposition::Merged:
        return XCOM_OK;
    case coact::SubmitDisposition::DroppedOverload:
    case coact::SubmitDisposition::RejectedState:
    case coact::SubmitDisposition::DroppedPolicy:
    case coact::SubmitDisposition::DroppedRateLimit:
        return XCOM_ERR_BUSY;
    case coact::SubmitDisposition::RejectedFull:
        return XCOM_ERR_FULL;
    default:
        // Unknown dispositions are refusals, not successes; report capacity
        // pressure rather than inventing a new code.
        return XCOM_ERR_FULL;
    }
}

}  // namespace xcom

#endif /* XCOM_TX_SUBMIT_STATUS_HPP_ */
