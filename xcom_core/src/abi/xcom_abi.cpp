// xcom_abi.cpp - the versioned C ABI surface of xcom_core.dll.
//
// All exported functions are no-throw across the boundary: every body is
// wrapped so a C++ exception cannot escape (returns an XcomStatus error).
// Only ONE caller thread (the Lua UI thread) may call into this ABI at a
// time; inside the core all work is serialized onto the coact Dispatcher.
//
// Synchronous contracts honored here:
//   - xcom_open / xcom_close wait only for their bounded lifecycle result on
//     the SerialAo/Dispatcher. An open timeout requests cancellation; it never
//     later publishes an unobserved OPEN state.
//   - xcom_send copies data[0:size] into TxBlockPool synchronously, then
//     queues the write and returns. The write result is asynchronous.
//   - xcom_drain_display is non-blocking and copies the next formatted batch
//     (or a prefix when the caller buffer is smaller).
//
// SPDX-License-Identifier: MIT
#include <cstdint>
#include <array>
#include <algorithm>
#include <cstring>
#include <optional>
#include <string_view>

#include <xcom/xcom.h>

#include "xcom_abi_internal.hpp"
#include "open_failure_status.hpp"
#include "xcom_core.hpp"
// enumerate_serial_ports_ex: the ABI-level error/occupancy-aware port lister.
// Only the function declaration is needed; no Win32 registry type leaks here
// (xcom_core.hpp already pulls windows.h for the core context).
#include "serial_backend_win.hpp"
#include "foundation/text.hpp"
#include "coact/pal_windows.hpp"

namespace xcom {
namespace {

// Reserved virtual/test port name: opens an in-process session with no serial
// hardware so the automated receive-path E2E (xcom_test_inject_rx) runs on any
// Windows machine. string_view over the NUL-terminated ABI string: exact match
// on "VIRTUAL" or the "TEST" prefix, byte-identical to the former
// strcmp/strncmp pair.
bool is_virtual_port(const char* name) noexcept
{
    if (name == nullptr) {
        return false;
    }
    const std::string_view sv(name);
    return sv == "VIRTUAL" || sv.substr(0U, 4U) == "TEST";
}

XcomStatus port_name_from_config(const XcomPortConfig* cfg,
                                 std::array<char, 64U>& destination) noexcept
{
    if (cfg == nullptr) {
        return XCOM_ERR_PARAM;
    }
    if (cfg->struct_size < sizeof(XcomPortConfig)) {
        return XCOM_ERR_PARAM;
    }
    if (cfg->port == nullptr) {
        return XCOM_ERR_PARAM;
    }
    foundation::copy_text(cfg->port, destination);
    return XCOM_OK;
}

// Translate a failed open attempt into the caller-visible status. The verdict
// comes from the recorded owner result, NOT from port_state: an open that never
// established a session lands in CLOSED, and CLOSED alone cannot distinguish
// "closed, never opened" from "closed because the attempt failed".
// last_open_result encodes that distinction. It has a MIXED value domain: the
// lifecycle writers store XCOM_OK / XCOM_ERR_* (0 or negative, with
// XCOM_ERR_BUSY as the queued sentinel), while the serial owner sink stores the
// raw POSITIVE Win32 code from the native open. XcomStatus is 0-or-negative by
// contract, so the raw Win32 code MUST be mapped back onto an enumerator before
// it crosses the ABI; open_failure_status_from_result() owns that mapping (and
// documents why it never yields BUSY). Anything that is not a resolved failure
// is reported as XCOM_ERR_IO, so a caller polling a CLOSED port can never read
// a stale XCOM_OK from a previous successful session.
XcomStatus open_failure_status(CoreCtx* core) noexcept
{
    return open_failure_status_from_result(
        core->last_open_result.load(std::memory_order_acquire));
}

}  // namespace
}  // namespace xcom

// Bring the xcom enumerators (SIG_*, kTxBlockBytes, XCOM_PORT_*, XCOM_OK/ERR)
// and helper names into scope for the extern "C" surface.
using namespace xcom;

extern "C" {

XCOM_API uint32_t xcom_version(void)
{
    return (static_cast<uint32_t>(XCOM_VERSION_MAJOR) << 16U) |
           (static_cast<uint32_t>(XCOM_VERSION_MINOR) << 8U) |
           static_cast<uint32_t>(XCOM_VERSION_PATCH);
}

XCOM_API XcomStatus xcom_list_ports(XcomPortInfo* out, uint32_t capacity,
                                    uint32_t* count)
{
    try {
        return xcom::list_ports_impl(out, capacity, count);
    }
    catch (...) {
        return XCOM_ERR_IO;
    }
}

// v1.4 error/occupancy-aware enumeration. Same buffer/count contract as
// xcom_list_ports, plus:
//   * `error` (optional) receives the native enumeration status (0 = success).
//     A missing SERIALCOMM key is "no ports", not an error.
//   * `flags` may include XCOM_LIST_PORTS_PROBE_BUSY to probe each port for
//     exclusive occupancy. Default callers MUST pass 0: the probe opens the
//     port and can disturb an auto-reset target board (see xcom.h).
// Returns XCOM_ERR_IO when the registry enumeration itself failed (out/count
// still carry whatever was found so a partial list can be shown), otherwise
// XCOM_OK / XCOM_ERR_FULL exactly like xcom_list_ports.
XCOM_API XcomStatus xcom_list_ports_ex(XcomPortInfo* out, uint32_t capacity,
                                       uint32_t* count, uint32_t flags,
                                       int32_t* error)
{
    try {
        if (error != nullptr) {
            *error = 0;
        }
        if (count == nullptr || (capacity != 0U && out == nullptr)) {
            return XCOM_ERR_PARAM;
        }
        std::int32_t native_error = 0;
        const bool probe = (flags & XCOM_LIST_PORTS_PROBE_BUSY) != 0U;
        const uint32_t found =
            xcom::enumerate_serial_ports_ex(out, capacity, probe, native_error);
        *count = found;
        if (error != nullptr) {
            *error = native_error;
        }
        if (native_error != 0) {
            return XCOM_ERR_IO;
        }
        return found > capacity ? XCOM_ERR_FULL : XCOM_OK;
    }
    catch (...) {
        // Never throw across the boundary and never claim success.
        if (error != nullptr) {
            *error = 0;
        }
        return XCOM_ERR_IO;
    }
}

XCOM_API XcomHandle xcom_create(const XcomCreateOptions* options)
{
    try {
        if (options != nullptr) {
            if (options->struct_size < sizeof(XcomCreateOptions)) {
                return nullptr;
            }
            if (options->flags != 0U) {
                return nullptr;
            }
        }
        xcom::Handle* h = xcom::xcom_handle_create();
        if (h == nullptr) {
            return nullptr;
        }
        // Boot the runtime (bind AOs, spin-guard the control pool, start the
        // Dispatcher) so the returned handle is fully functional.
        if (xcom::xcom_handle_boot(h) != XCOM_OK) {
            xcom::xcom_handle_destroy(h);
            return nullptr;
        }
        return static_cast<void*>(h);
    }
    catch (...) {
        return nullptr;
    }
}

// Shared prefix of both synchronous and async open: validate the config, check
// the precondition against the AO-published view, snapshot the serial options,
// and queue the SIG_OPEN for the SerialAo on the Dispatcher. The ABI never
// writes port_state: the AO publishes OPENING itself as the first act of the
// transition. last_open_result is parked at XCOM_ERR_BUSY as the "request
// queued, owner has not resolved it yet" sentinel so the caller can tell a
// genuinely-CLOSED port from one whose SIG_OPEN has not been dispatched yet.
// On any failure an XcomStatus is returned and port_state is left alone.
XcomStatus queue_open(CoreCtx* core, const XcomPortConfig* config,
                      std::array<char, 64U>& name) noexcept
{
    const XcomStatus pm = port_name_from_config(config, name);
    if (pm != XCOM_OK) {
        return pm;
    }
    // Parameter range validation (design §6 config contract).
    if (config->baud_rate == 0U) {
        return XCOM_ERR_PARAM;
    }
    if (config->data_bits < 5U || config->data_bits > 8U) {
        return XCOM_ERR_PARAM;
    }
    if (config->stop_bits > 2U) {   // ABI 0=1, 1=1.5, 2=2
        return XCOM_ERR_PARAM;
    }
    if (config->parity > 4U) {      // 0..4 None/Odd/Even/Mark/Space
        return XCOM_ERR_PARAM;
    }
    if (config->flow_control > 2U) {
        return XCOM_ERR_PARAM;
    }
    // dtr_enable / rts_enable are a tri-state (see XcomPortConfig): 0 = drive
    // deasserted, 1 = drive asserted, 2 = leave the line alone. Reject any other
    // value rather than coercing it, so a mistyped 3 cannot silently become
    // "drive low" and pulse a target's NRST/BOOT pin during open.
    if (XCOM_LINE_LEAVE_ALONE < config->dtr_enable ||
        XCOM_LINE_LEAVE_ALONE < config->rts_enable) {
        return XCOM_ERR_PARAM;
    }
    const uint16_t current_state =
        core->port_state.load(std::memory_order_acquire);
    const bool open_pending =
        core->last_open_result.load(std::memory_order_acquire) == XCOM_ERR_BUSY;
    if (current_state == XCOM_PORT_OPEN) {
        return XCOM_ERR_ALREADY_OPEN;
    }
    // An earlier open whose SIG_OPEN has not been dispatched yet would make a
    // second request a double open; refuse it the same way as an OPEN port.
    if (open_pending) {
        return XCOM_ERR_BUSY;
    }
    // Retrying straight from FAULT is now a real transition, not a dead end.
    // The HSM carries Fault --Open--> OPENING, and serial_do_open tears the
    // failed session down through owner_open before configuring the new one, so
    // this is the same work the Close-then-Open pair performed. It used to be
    // rejected with XCOM_ERR_BUSY because the HSM had no edge out of Fault and
    // the request would have waited on an event nothing could consume — the
    // user-visible effect was "clicked Open and nothing happened", since the UI
    // offers Open in FAULT (same as the Lua model's ALLOWED_OPEN).
    if (current_state != XCOM_PORT_CLOSED &&
        current_state != XCOM_PORT_FAULT) {
        return XCOM_ERR_BUSY;
    }

    if (!core->sync_port_name(name.data())) {
        core->errors.push(XCOM_ERR_PARAM, 0U,
                          "serial port name exceeds fixed capacity");
        return XCOM_ERR_PARAM;
    }
    core->virtual_port = is_virtual_port(name.data());
    // Store the serial configuration snapshot for the owner sink
    // (consumed on the Dispatcher).
    core->cfg_baud = config->baud_rate;
    core->cfg_data_bits = config->data_bits;
    core->cfg_stop_bits = config->stop_bits;
    core->cfg_parity = config->parity;
    core->cfg_flow_control = config->flow_control;
    core->cfg_dtr_enable = config->dtr_enable;
    core->cfg_rts_enable = config->rts_enable;
    core->last_open_result.store(XCOM_ERR_BUSY, std::memory_order_release);
    core->cancel_open.store(0U, std::memory_order_release);
    core->errors.push(0, 0, "open requested");

    // SerialAo (owner) performs the open on the Dispatcher; the caller either
    // blocks (synchronous) or polls (async) until it reports OPEN or failed.
    if (!core->submit_control(to_signal(Signal::Open), 0U, false)) {
        // The request never reached the AO, so nothing will resolve the
        // sentinel; port_state is untouched (still CLOSED/FAULT).
        core->last_open_result.store(XCOM_ERR_IO, std::memory_order_release);
        core->errors.push(XCOM_ERR_FULL, 0, "open event rejected");
        return XCOM_ERR_FULL;
    }
    return XCOM_OK;
}

XCOM_API XcomStatus xcom_open(XcomHandle hh, const XcomPortConfig* config)
{
    try {
        xcom::Handle* h = xcom::xcom_handle_valid(hh) ?
                              static_cast<xcom::Handle*>(hh) : nullptr;
        if (h == nullptr) {
            return XCOM_ERR_PARAM;
        }
        xcom::CoreCtx* core = xcom::xcom_handle_core(h);

        std::array<char, 64U> name{};
        const XcomStatus q = queue_open(core, config, name);
        if (q != XCOM_OK) {
            return q;
        }

        for (int i = 0; i < 200; ++i) {   // up to ~2 s
            const int32_t result =
                core->last_open_result.load(std::memory_order_acquire);
            if (result == XCOM_OK) {
                // The owner open succeeded; wait for the AO to publish OPEN so
                // a subsequent xcom_send observes a usable session.
                if (core->port_state.load(std::memory_order_acquire) ==
                    XCOM_PORT_OPEN) {
                    return XCOM_OK;
                }
            }
            else if (result != XCOM_ERR_BUSY) {
                // Definitive owner failure. The recorded result may be a raw
                // Win32 code; open_failure_status maps it onto a 0-or-negative
                // XcomStatus (the raw code stays in the XcomError ring). A
                // failed open publishes CLOSED, not FAULT.
                return open_failure_status(core);
            }
            coact::pal::sleep_ms(10U);
        }
        // The SerialAo can be inside a synchronous native open when this
        // caller deadline expires. Let that owner finish its Win32 call, but
        // make it immediately schedule its legal Open -> Close transition
        // instead of publishing OPEN after the caller already saw a timeout.
        core->cancel_open.store(1U, std::memory_order_release);
        return XCOM_ERR_TIMEOUT;
    }
    catch (...) {
        return XCOM_ERR_IO;
    }
}

XCOM_API XcomStatus xcom_open_async(XcomHandle hh, const XcomPortConfig* config)
{
    try {
        xcom::Handle* h = xcom::xcom_handle_valid(hh) ?
                              static_cast<xcom::Handle*>(hh) : nullptr;
        if (h == nullptr) {
            return XCOM_ERR_PARAM;
        }
        xcom::CoreCtx* core = xcom::xcom_handle_core(h);

        std::array<char, 64U> name{};
        return queue_open(core, config, name);
    }
    catch (...) {
        return XCOM_ERR_IO;
    }
}

XCOM_API XcomStatus xcom_take_open_result(XcomHandle hh)
{
    try {
        xcom::Handle* h = xcom::xcom_handle_valid(hh) ?
                              static_cast<xcom::Handle*>(hh) : nullptr;
        if (h == nullptr) {
            return XCOM_ERR_PARAM;
        }
        xcom::CoreCtx* core = xcom::xcom_handle_core(h);
        const uint16_t st = core->port_state.load(std::memory_order_acquire);
        if (st == XCOM_PORT_OPEN) {
            return XCOM_OK;
        }
        if (st == XCOM_PORT_OPENING) {
            return XCOM_ERR_BUSY;   // still in progress; poll again
        }
        // The ABI no longer publishes OPENING itself, so a SIG_OPEN that the
        // Dispatcher has not picked up yet still reads CLOSED. Report BUSY
        // while the queued request's sentinel is unresolved rather than a
        // spurious failure.
        if (core->last_open_result.load(std::memory_order_acquire) ==
            XCOM_ERR_BUSY) {
            return XCOM_ERR_BUSY;
        }
        // A resolved non-OK, non-BUSY recorded result: the open attempt failed
        // (or was cancelled). Return the recorded cause mapped to an
        // XcomStatus; the detailed Win32 code is also in the error ring.
        return open_failure_status(core);
    }
    catch (...) {
        return XCOM_ERR_IO;
    }
}

XCOM_API XcomStatus xcom_close(XcomHandle hh, uint32_t timeout_ms)
{
    try {
        xcom::Handle* h = xcom::xcom_handle_valid(hh) ?
                              static_cast<xcom::Handle*>(hh) : nullptr;
        if (h == nullptr) {
            return XCOM_ERR_PARAM;
        }
        xcom::CoreCtx* core = xcom::xcom_handle_core(h);
        const uint16_t st = core->port_state.load(std::memory_order_acquire);
        // The ABI no longer publishes OPENING itself, so a close issued while
        // the open's SIG_OPEN is still queued reads CLOSED. Treat that as
        // "open pending" via the sentinel instead of a no-op, otherwise the
        // queued open would complete after xcom_close returned OK.
        const bool open_pending =
            core->last_open_result.load(std::memory_order_acquire) ==
            XCOM_ERR_BUSY;
        if (st == XCOM_PORT_CLOSED && false == open_pending) {
            return XCOM_OK;   // idempotent (includes post-failure CLOSED)
        }
        if (st == XCOM_PORT_OPENING || open_pending) {
            // Tell the SerialAo that any in-flight owner_open must not settle
            // in OPEN: it takes the OPENING --Cancel--> CLOSING edge.
            core->cancel_open.store(1U, std::memory_order_release);
        }
        // The AO owns port_state; the ABI only submits the Close signal and
        // polls the published view. If the signal is rejected the state is left
        // exactly as the AO published it (there is no ABI rollback write).
        if (false == core->submit_control(to_signal(Signal::Close), 0U,
                                          true /*critical*/)) {
            core->errors.push(XCOM_ERR_FULL, 0, "close event rejected");
            return XCOM_ERR_FULL;
        }
        const uint64_t deadline = coact::pal::monotonic_ms() + timeout_ms;
        do {
            if (core->port_state.load(std::memory_order_acquire) ==
                XCOM_PORT_CLOSED) {
                return XCOM_OK;
            }
            const uint64_t now = coact::pal::monotonic_ms();
            if (now >= deadline) {
                break;
            }
            const uint64_t remaining = deadline - now;
            coact::pal::sleep_ms(
                static_cast<uint32_t>(remaining < 20U ? remaining : 20U));
        } while (true);
        // Timeout: the AO still owns the transition. An opening session stays
        // OPENING until its owner observes cancel_open and completes the legal
        // CLOSING -> CLOSED path; there is no ABI-side rollback write.
        return XCOM_ERR_TIMEOUT;
    }
    catch (...) {
        return XCOM_ERR_IO;
    }
}

// v1.1: synchronous-copy + queue-and-return. The core copies data[0:size]
// verbatim into a unique TxBlockPool slot before returning (the caller pointer
// is never retained or re-encoded). The Lua client has already pre-encoded the
// payload (HEX decoded, optional CRLF applied), so neither the HEX flag nor
// CRLF is re-processed here. The function does NOT block for the actual serial
// WriteResult; success/failure is reported asynchronously via snapshot/error.
XCOM_API XcomStatus xcom_send(XcomHandle hh, const uint8_t* data,
                              uint32_t size, XcomSendFlags flags)
{
    (void)flags;
    try {
        xcom::Handle* h = xcom::xcom_handle_valid(hh) ?
                              static_cast<xcom::Handle*>(hh) : nullptr;
        if (h == nullptr || data == nullptr) {
            return XCOM_ERR_PARAM;
        }
        if (size == 0U) {
            return XCOM_OK;   // nothing to send
        }
        if (size > kTxBlockBytes) {
            xcom::CoreCtx* c = xcom::xcom_handle_core(h);
            c->metrics.tx_rejected.fetch_add(1U, std::memory_order_relaxed);
            return XCOM_ERR_FULL;
        }
        xcom::CoreCtx* core = xcom::xcom_handle_core(h);
        if (core->port_state.load(std::memory_order_acquire) != XCOM_PORT_OPEN) {
            return XCOM_ERR_NOT_OPEN;
        }

        // Synchronous copy into TxBlockPool (v1.1 ABI guarantees this before
        // this function returns).
        uint16_t bid = 0U;
        uint8_t* dst = core->tx.try_alloc(bid);
        if (dst == nullptr) {
            core->metrics.tx_rejected.fetch_add(1U, std::memory_order_relaxed);
            return XCOM_ERR_FULL;
        }
        std::memcpy(dst, data, size);

        // v1.2 §6: each accepted Tx gets its OWN typed descriptor in its OWN
        // pooled event. queue-and-return cannot overwrite a still-queued first
        // send (no shared pending_write_word slot).
        const xcom::TxDescriptor desc{
            bid, static_cast<uint16_t>(size),
            core->generation.load(std::memory_order_acquire)};
        const XcomStatus submit_status = core->submit_write(desc);
        if (XCOM_OK != submit_status) {
            core->tx.release(bid);
            core->metrics.tx_rejected.fetch_add(1U, std::memory_order_relaxed);
            if (XCOM_ERR_BUSY == submit_status) {
                // The Send AO's overload Breaker refused this event; the
                // TxBlockPool is not full. Count it apart from capacity pressure
                // so the two causes stay attributable.
                core->metrics.tx_rejected_overload.fetch_add(
                    1U, std::memory_order_relaxed);
            }
            return submit_status;
        }
        return XCOM_OK;   // queue-and-return: no blocking on the WriteResult
    }
    catch (...) {
        return XCOM_ERR_IO;
    }
}

XCOM_API XcomStatus xcom_set_options(XcomHandle hh,
                                     const XcomDisplayOptions* options)
{
    try {
        xcom::Handle* h = xcom::xcom_handle_valid(hh) ?
                              static_cast<xcom::Handle*>(hh) : nullptr;
        if (h == nullptr || options == nullptr) {
            return XCOM_ERR_PARAM;
        }
        if (options->struct_size < sizeof(XcomDisplayOptions)) {
            return XCOM_ERR_PARAM;
        }
        xcom::CoreCtx* core = xcom::xcom_handle_core(h);
        const bool resume_display = core->pause_display.load(
                                        std::memory_order_acquire) != 0U &&
                                    options->pause_display == 0U;
        core->hex_view.store(options->hex_view != 0U ? 1U : 0U,
                             std::memory_order_release);
        core->timestamp.store(options->timestamp != 0U ? 1U : 0U,
                              std::memory_order_release);
        core->pause_display.store(options->pause_display != 0U ? 1U : 0U,
                                  std::memory_order_release);
        if (resume_display && core->kick_gate.try_arm()) {
            core->submit_rx_kick();
        }
        return XCOM_OK;
    }
    catch (...) {
        return XCOM_ERR_IO;
    }
}

// v1.4: live modem-line hot switch. `dtr`/`rts` are 1 = asserted (physical
// pin active), 0 = deasserted, matching XcomPortConfig.dtr_enable/rts_enable.
// Applies immediately while the port is open. Returns XCOM_ERR_NOT_OPEN when
// there is no open physical session (virtual/closed).
//
// Under RTS/CTS flow control the driver owns RTS, so no manual RTS value can be
// applied; that half is reported as XCOM_ERR_UNSUPPORTED and is NEVER reported
// as success (a deassert request is refused symmetrically with an assert one).
// The DTR half is not flow-controlled and is still driven first: on that path
// XCOM_ERR_UNSUPPORTED means "DTR was applied, RTS was not", while a genuine
// DTR failure still surfaces as XCOM_ERR_IO / XCOM_ERR_NOT_OPEN.
XCOM_API XcomStatus xcom_set_lines(XcomHandle hh, uint8_t dtr, uint8_t rts)
{
    try {
        xcom::Handle* h = xcom::xcom_handle_valid(hh) ?
                              static_cast<xcom::Handle*>(hh) : nullptr;
        if (h == nullptr) {
            return XCOM_ERR_PARAM;
        }
        xcom::CoreCtx* core = xcom::xcom_handle_core(h);
        if (core->port_state.load(std::memory_order_acquire) != XCOM_PORT_OPEN) {
            return XCOM_ERR_NOT_OPEN;
        }
        if (core->sink.owner_set_lines == nullptr) {
            return XCOM_ERR_NOT_OPEN;
        }
        // Drive both halves; the sink reports a driver-owned RTS separately from
        // a failed Win32 write. DTR is applied here even when RTS will be
        // refused below, which is the point of driving before the RTS check.
        const XcomStatus applied =
            core->sink.owner_set_lines(core, dtr != 0U, rts != 0U);
        // RTS/CTS owns the RTS pin, so the requested RTS level was not applied.
        // NEVER return OK for it: the rts=0 case used to fall through and report
        // a success that never reached the pin.
        //
        // This is a PARTIAL success, not a total failure: the DTR half was
        // already driven above. The code is readable per half - a DTR hard
        // failure (device removed / closed) has its own code and outranks the
        // routine RTS refusal - so XCOM_ERR_UNSUPPORTED here uniquely means
        // "DTR was applied, RTS was not". Callers MUST treat it that way rather
        // than as "nothing was applied" (see window.lua's DTR/RTS hot switch).
        // A virtual session has no backend to observe the handshake, so its
        // NOT_OPEN is upgraded to the same deterministic refusal instead.
        if (core->cfg_flow_control == 1U) {
            if (!core->virtual_port &&
                (applied == XCOM_ERR_IO || applied == XCOM_ERR_NOT_OPEN)) {
                return applied;
            }
            return XCOM_ERR_UNSUPPORTED;
        }
        return applied;
    }
    catch (...) {
        return XCOM_ERR_IO;
    }
}

// v1.1: configure the auto-send template. data is pre-encoded raw bytes; the
// core copies it into a dedicated template slot before returning. interval_ms
// == 0 disables auto-send. flags uses XCOM_SEND_TEXT (HEX/CRLF are pre-applied
// by the Lua client). Coalesced ticks increment auto_tick_coalesced.
XCOM_API XcomStatus xcom_set_auto_template(XcomHandle hh, const uint8_t* data,
                                           uint32_t size, uint32_t interval_ms,
                                           XcomSendFlags flags)
{
    (void)flags;
    try {
        xcom::Handle* h = xcom::xcom_handle_valid(hh) ?
                              static_cast<xcom::Handle*>(hh) : nullptr;
        if (h == nullptr) {
            return XCOM_ERR_PARAM;
        }
        if (interval_ms != 0U && data == nullptr) {
            return XCOM_ERR_PARAM;
        }
        if (size > kTxBlockBytes) {
            xcom::CoreCtx* c = xcom::xcom_handle_core(h);
            c->metrics.tx_rejected.fetch_add(1U, std::memory_order_relaxed);
            return XCOM_ERR_FULL;
        }
        xcom::CoreCtx* core = xcom::xcom_handle_core(h);
        xcom::AutoTemplateDescriptor descriptor{};
        descriptor.interval_ms = interval_ms;
        if (interval_ms != 0U) {
            uint16_t block_id = 0U;
            uint8_t* const destination = core->tx.try_alloc(block_id);
            if (destination == nullptr) {
                core->metrics.tx_rejected.fetch_add(1U,
                                                    std::memory_order_relaxed);
                return XCOM_ERR_FULL;
            }
            std::memcpy(destination, data, size);
            descriptor.block = block_id;
            descriptor.length = static_cast<std::uint16_t>(size);
        }
        if (!core->submit_autosend_config(descriptor)) {
            if (interval_ms != 0U) {
                core->tx.release(descriptor.block);
            }
            core->metrics.tx_rejected.fetch_add(1U, std::memory_order_relaxed);
            return XCOM_ERR_FULL;
        }
        return XCOM_OK;
    }
    catch (...) {
        return XCOM_ERR_IO;
    }
}

// NOTE (v1.1): there is deliberately NO exported xcom_wait_display. The DLL
// keeps its own internal display wake event; the Lua UI thread drives display
// visibility with a 10 ms poll of xcom_drain_display.

XCOM_API XcomStatus xcom_drain_display(XcomHandle hh, char* output,
                                       uint32_t capacity, uint32_t* written)
{
    try {
        xcom::Handle* h = xcom::xcom_handle_valid(hh) ?
                              static_cast<xcom::Handle*>(hh) : nullptr;
        if (h == nullptr || output == nullptr || written == nullptr) {
            return XCOM_ERR_PARAM;
        }
        *written = 0U;
        xcom::CoreCtx* core = xcom::xcom_handle_core(h);
        bool completed = false;
        uint32_t ingress_ignored = 0U;
        if (!core->display.drain_into(
                output, capacity,
                core->generation.load(std::memory_order_acquire), *written,
                completed, ingress_ignored)) {
            return XCOM_OK;   // nothing buffered
        }
        if (completed) {
            core->metrics.display_pending.fetch_sub(
                1U, std::memory_order_relaxed);
        }
        // Releasing a display buffer may unblock a deferred RxDesc. Retrigger
        // it through coact instead of spinning the Dispatcher while the UI is
        // slow.
        if (completed && core->kick_gate.try_arm()) {
            core->submit_rx_kick();
        }
        return XCOM_OK;
    }
    catch (...) {
        return XCOM_ERR_IO;
    }
}

// Timestamp-aware display drain (design §3): same batch semantics as
// xcom_drain_display, but the byte count is the return value and the batch's
// EARLIEST ingress time (monotonic ms) is written through out_ingress_ms.  A
// zero-byte batch leaves *out_ingress_ms unchanged so the caller's wall-clock
// anchor is never advanced by an empty poll.
XCOM_API uint32_t xcom_drain_display_ts(XcomHandle hh, uint8_t* out,
                                        uint32_t capacity,
                                        uint32_t* out_ingress_ms)
{
    if (hh == nullptr || out == nullptr || out_ingress_ms == nullptr) {
        return 0U;
    }
    xcom::Handle* h = xcom::xcom_handle_valid(hh) ?
                          static_cast<xcom::Handle*>(hh) : nullptr;
    if (h == nullptr) {
        return 0U;
    }
    try {
        xcom::CoreCtx* core = xcom::xcom_handle_core(h);
        uint32_t written = 0U;
        bool completed = false;
        uint32_t ingress = 0U;
        if (!core->display.drain_into(
                reinterpret_cast<char*>(out), capacity,
                core->generation.load(std::memory_order_acquire), written,
                completed, ingress)) {
            return 0U;   // nothing buffered; *out_ingress_ms untouched
        }
        if (written > 0U) {
            *out_ingress_ms = ingress;
        }
        if (completed) {
            core->metrics.display_pending.fetch_sub(
                1U, std::memory_order_relaxed);
        }
        // Releasing a display buffer may unblock a deferred RxDesc; retrigger
        // through coact rather than spinning the Dispatcher.
        if (completed && core->kick_gate.try_arm()) {
            core->submit_rx_kick();
        }
        return written;
    }
    catch (...) {
        return 0U;
    }
}

XCOM_API XcomStatus xcom_get_snapshot(XcomHandle hh, XcomSnapshot* output)
{
    try {
        xcom::Handle* h = xcom::xcom_handle_valid(hh) ?
                              static_cast<xcom::Handle*>(hh) : nullptr;
        if (h == nullptr || output == nullptr) {
            return XCOM_ERR_PARAM;
        }
        if (output->struct_size < sizeof(XcomSnapshot)) {
            return XCOM_ERR_PARAM;
        }
        xcom::CoreCtx* core = xcom::xcom_handle_core(h);
        // This ABI is the existing 250 ms UI status poll (design §4.2 item 3):
        // sample the three monitored threads here rather than adding a timer.
        // It only pushes ErrorRing entries on an episode edge; the returned
        // snapshot below is unchanged.
        xcom::check_thread_health(core);
        output->struct_size = sizeof(XcomSnapshot);
        output->rx_bytes = core->metrics.rx_bytes.load(std::memory_order_relaxed);
        output->tx_bytes = core->metrics.tx_bytes.load(std::memory_order_relaxed);
        output->rx_pool_exhausted_bytes =
            core->metrics.rx_pool_exhausted_bytes.load(std::memory_order_relaxed);
        output->tx_rejected =
            core->metrics.tx_rejected.load(std::memory_order_relaxed);
        output->auto_tick_coalesced =
            core->metrics.auto_tick_coalesced.load(std::memory_order_relaxed);
        output->ui_trimmed_bytes =
            core->metrics.ui_trimmed_bytes.load(std::memory_order_relaxed);
        output->save_rejected_bytes =
            core->metrics.save_rejected_bytes.load(std::memory_order_relaxed);
        output->display_paused_bytes =
            core->metrics.display_paused_bytes.load(std::memory_order_relaxed);
        output->callback_count =
            core->metrics.callback_count.load(std::memory_order_relaxed);
        output->generation = core->generation.load(std::memory_order_relaxed);
        output->display_pending =
            core->metrics.display_pending.load(std::memory_order_acquire);
        output->port_state = core->port_state.load(std::memory_order_relaxed);
        output->_pad[0] = 0U;
        output->_pad[1] = 0U;
        // v1.5 line-error counters (appended fields; see XcomSnapshot).
        output->framing_errors =
            core->metrics.framing_errors.load(std::memory_order_relaxed);
        output->parity_errors =
            core->metrics.parity_errors.load(std::memory_order_relaxed);
        output->overrun_errors =
            core->metrics.overrun_errors.load(std::memory_order_relaxed);
        output->break_events =
            core->metrics.break_events.load(std::memory_order_relaxed);
        // v1.5 loss observability (appended fields; see XcomSnapshot).
        output->rx_sequence =
            core->metrics.rx_seq.load(std::memory_order_relaxed);
        output->rx_loss_offset =
            core->metrics.rx_loss_offset.load(std::memory_order_relaxed);
        output->rx_backpressure_events =
            core->metrics.rx_backpressure_events.load(std::memory_order_relaxed);
        // v1.6 flow-control stall counter (appended field; see XcomSnapshot).
        output->flow_hold_events =
            core->metrics.flow_hold_events.load(std::memory_order_relaxed);
        return XCOM_OK;
    }
    catch (...) {
        return XCOM_ERR_IO;
    }
}

XCOM_API XcomStatus xcom_take_error(XcomHandle hh, XcomError* output)
{
    try {
        xcom::Handle* h = xcom::xcom_handle_valid(hh) ?
                              static_cast<xcom::Handle*>(hh) : nullptr;
        if (h == nullptr || output == nullptr) {
            return XCOM_ERR_PARAM;
        }
        if (output->struct_size < sizeof(XcomError)) {
            return XCOM_ERR_PARAM;
        }
        xcom::CoreCtx* core = xcom::xcom_handle_core(h);
        // Error query via std::optional: nullopt is the empty-ring case.
        const std::optional<xcom::ErrorEntry> entry = core->errors.take();
        if (!entry.has_value()) {
            output->code = 0;
            output->source = 0;
            output->_pad = 0;
            output->message[0] = '\0';
            return XCOM_OK;   // no error
        }
        output->code = entry->code;
        output->source = entry->source;
        output->_pad = 0;
        foundation::copy_text(entry->message.data(), output->message,
                              sizeof(output->message));
        return XCOM_OK;
    }
    catch (...) {
        return XCOM_ERR_IO;
    }
}

XCOM_API XcomStatus xcom_log_open(XcomHandle hh, const char* utf8_path,
                                  uint8_t append)
{
    try {
        xcom::Handle* h = xcom::xcom_handle_valid(hh) ?
                              static_cast<xcom::Handle*>(hh) : nullptr;
        return h != nullptr ? xcom::xcom_handle_core(h)->log_open(
                                utf8_path, append != 0U)
                            : XCOM_ERR_PARAM;
    } catch (...) { return XCOM_ERR_IO; }
}

XCOM_API XcomStatus xcom_log_append(XcomHandle hh, const uint8_t* data,
                                    uint32_t size)
{
    try {
        xcom::Handle* h = xcom::xcom_handle_valid(hh) ?
                              static_cast<xcom::Handle*>(hh) : nullptr;
        return h != nullptr ? xcom::xcom_handle_core(h)->log_append(data, size)
                            : XCOM_ERR_PARAM;
    } catch (...) { return XCOM_ERR_IO; }
}

XCOM_API XcomStatus xcom_log_flush(XcomHandle hh, uint32_t timeout_ms)
{
    try {
        xcom::Handle* h = xcom::xcom_handle_valid(hh) ?
                              static_cast<xcom::Handle*>(hh) : nullptr;
        return h != nullptr ? xcom::xcom_handle_core(h)->log_flush(timeout_ms)
                            : XCOM_ERR_PARAM;
    } catch (...) { return XCOM_ERR_IO; }
}

XCOM_API XcomStatus xcom_log_close(XcomHandle hh, uint32_t timeout_ms)
{
    try {
        xcom::Handle* h = xcom::xcom_handle_valid(hh) ?
                              static_cast<xcom::Handle*>(hh) : nullptr;
        return h != nullptr ? xcom::xcom_handle_core(h)->log_close(timeout_ms)
                            : XCOM_ERR_PARAM;
    } catch (...) { return XCOM_ERR_IO; }
}

XCOM_API XcomStatus xcom_file_submit_atomic(XcomHandle hh,
                                             const char* utf8_path,
                                             const uint8_t* data,
                                             uint32_t size,
                                             uint64_t request_id)
{
    try {
        xcom::Handle* h = xcom::xcom_handle_valid(hh) ?
                              static_cast<xcom::Handle*>(hh) : nullptr;
        return h != nullptr ? xcom::xcom_handle_core(h)->file_submit_atomic(
                                utf8_path, data, size, request_id)
                            : XCOM_ERR_PARAM;
    } catch (...) { return XCOM_ERR_IO; }
}

XCOM_API XcomStatus xcom_file_submit_atomic_borrowed(
    XcomHandle hh, const char* utf8_path, const uint8_t* data,
    uint32_t size, uint64_t request_id)
{
    try {
        xcom::Handle* h = xcom::xcom_handle_valid(hh) ?
                              static_cast<xcom::Handle*>(hh) : nullptr;
        return h != nullptr ? xcom::xcom_handle_core(h)->file_submit_atomic_borrowed(
                                utf8_path, data, size, request_id)
                            : XCOM_ERR_PARAM;
    } catch (...) { return XCOM_ERR_IO; }
}

XCOM_API XcomStatus xcom_file_stream_begin(XcomHandle hh,
                                           const char* utf8_path,
                                           uint64_t stream_id,
                                           uint64_t request_id)
{
    try {
        xcom::Handle* h = xcom::xcom_handle_valid(hh) ?
                              static_cast<xcom::Handle*>(hh) : nullptr;
        return h != nullptr ? xcom::xcom_handle_core(h)->file_stream_begin(
                                utf8_path, stream_id, request_id)
                            : XCOM_ERR_PARAM;
    } catch (...) { return XCOM_ERR_IO; }
}

XCOM_API XcomStatus xcom_file_stream_append_borrowed(
    XcomHandle hh, uint64_t stream_id, const uint8_t* data, uint32_t size,
    uint64_t request_id)
{
    try {
        xcom::Handle* h = xcom::xcom_handle_valid(hh) ?
                              static_cast<xcom::Handle*>(hh) : nullptr;
        return h != nullptr ? xcom::xcom_handle_core(h)->file_stream_append_borrowed(
                                stream_id, data, size, request_id)
                            : XCOM_ERR_PARAM;
    } catch (...) { return XCOM_ERR_IO; }
}

XCOM_API XcomStatus xcom_file_stream_commit(XcomHandle hh,
                                            uint64_t stream_id,
                                            uint64_t request_id)
{
    try {
        xcom::Handle* h = xcom::xcom_handle_valid(hh) ?
                              static_cast<xcom::Handle*>(hh) : nullptr;
        return h != nullptr ? xcom::xcom_handle_core(h)->file_stream_commit(
                                stream_id, request_id)
                            : XCOM_ERR_PARAM;
    } catch (...) { return XCOM_ERR_IO; }
}

XCOM_API XcomStatus xcom_file_stream_abort(XcomHandle hh,
                                           uint64_t stream_id,
                                           uint64_t request_id)
{
    try {
        xcom::Handle* h = xcom::xcom_handle_valid(hh) ?
                              static_cast<xcom::Handle*>(hh) : nullptr;
        return h != nullptr ? xcom::xcom_handle_core(h)->file_stream_abort(
                                stream_id, request_id)
                            : XCOM_ERR_PARAM;
    } catch (...) { return XCOM_ERR_IO; }
}

XCOM_API XcomStatus xcom_file_take_completion(XcomHandle hh,
                                               uint64_t* request_id,
                                               XcomStatus* status)
{
    try {
        xcom::Handle* h = xcom::xcom_handle_valid(hh) ?
                              static_cast<xcom::Handle*>(hh) : nullptr;
        return h != nullptr ? xcom::xcom_handle_core(h)->file_take_completion(
                                request_id, status)
                            : XCOM_ERR_PARAM;
    } catch (...) { return XCOM_ERR_IO; }
}

XCOM_API XcomStatus xcom_test_inject_rx(XcomHandle hh, const uint8_t* data,
                                        uint32_t size)
{
    try {
        xcom::Handle* h = xcom::xcom_handle_valid(hh) ?
                              static_cast<xcom::Handle*>(hh) : nullptr;
        if (h == nullptr || data == nullptr) {
            return XCOM_ERR_PARAM;
        }
        xcom::CoreCtx* core = xcom::xcom_handle_core(h);
        if (core->port_state.load(std::memory_order_acquire) != XCOM_PORT_OPEN) {
            return XCOM_ERR_NOT_OPEN;
        }
        return xcom::rx_ingress(core, data, size) ==
                       xcom::RxIngressResult::kAllAccepted
                   ? XCOM_OK
                   : XCOM_ERR_IO;
    }
    catch (...) {
        return XCOM_ERR_IO;
    }
}

XCOM_API XcomStatus xcom_test_inject_line_errors(XcomHandle hh, uint32_t framing,
                                                 uint32_t parity, uint32_t overrun,
                                                 uint32_t break_events)
{
    try {
        xcom::Handle* h = xcom::xcom_handle_valid(hh) ?
                              static_cast<xcom::Handle*>(hh) : nullptr;
        if (h == nullptr) {
            return XCOM_ERR_PARAM;
        }
        xcom::CoreCtx* core = xcom::xcom_handle_core(h);
        if (core->port_state.load(std::memory_order_acquire) != XCOM_PORT_OPEN) {
            return XCOM_ERR_NOT_OPEN;
        }
        // Routed through the same ingress the serial read callback uses, so the
        // accumulation/milestone-diag semantics under test are the production
        // ones. hold_events is left to the real ClearCommError path (a hold is
        // sampled from COMSTAT, not something the test seam can fabricate).
        xcom::line_status_ingress(core, framing, parity, overrun, break_events,
                                  0U);
        return XCOM_OK;
    }
    catch (...) {
        return XCOM_ERR_IO;
    }
}

XCOM_API void xcom_destroy(XcomHandle hh)
{
    try {
        xcom::Handle* h = xcom::xcom_handle_valid(hh) ?
                              static_cast<xcom::Handle*>(hh) : nullptr;
        if (h != nullptr) {
            xcom::xcom_handle_destroy(h);
        }
    }
    catch (...) {
        // no exceptions cross the boundary
    }
}

}  // extern "C"
