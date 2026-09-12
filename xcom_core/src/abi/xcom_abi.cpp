// xcom_abi.cpp - the versioned C ABI surface of xcom_core.dll.
//
// All exported functions are no-throw across the boundary: every body is
// wrapped so a C++ exception cannot escape (returns an XcomStatus error).
// Only ONE caller thread (the CoreWorker QThread) may call into this ABI at a
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
#include "xcom_core.hpp"
// enumerate_serial_ports_ex: the ABI-level error/occupancy-aware port lister.
// Only the function declaration is needed; no Win32 registry type leaks here
// (xcom_core.hpp already pulls windows.h for the core context).
#include "serial_backend_win.hpp"
#include "foundation/text.hpp"
#include "pal_windows.hpp"

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

// Translate a failed open (FAULT/CLOSED) into the caller-visible status. The
// detailed native serial/Win32 code was pushed to the error ring by the owner;
// the boundary contract keeps open failures as XCOM_ERR_IO.
XcomStatus port_state_2_status(CoreCtx* core) noexcept
{
    (void)core;
    return XCOM_ERR_IO;
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
// the HSM precondition (CLOSED only), snapshot the serial options, and queue the
// SIG_OPEN for the SerialAo on the Dispatcher.  On any failure the port_state is
// untouched or rolled back to CLOSED and an XcomStatus is returned.  On success
// XCOM_OK is returned and the open proceeds asynchronously on the owner; the
// caller observes completion via port_state (see xcom_open / xcom_take_open_result).
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
    const uint16_t current_state =
        core->port_state.load(std::memory_order_acquire);
    if (current_state == XCOM_PORT_OPEN) {
        return XCOM_ERR_ALREADY_OPEN;
    }
    // Retrying straight from FAULT is now a real transition, not a dead end.
    // The HSM carries Fault --Open--> Open, and serial_do_open tears the failed
    // session down through owner_open before configuring the new one, so this
    // is the same work the Close-then-Open pair performed. It used to be
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
    core->cfg_dtr_enable = config->dtr_enable != 0U ? 1U : 0U;
    core->cfg_rts_enable = config->rts_enable != 0U ? 1U : 0U;
    core->last_open_result.store(XCOM_ERR_IO, std::memory_order_release);
    core->cancel_open.store(0U, std::memory_order_release);
    core->port_state.store(XCOM_PORT_OPENING, std::memory_order_release);
    core->errors.push(0, 0, "open requested");

    // SerialAo (owner) performs the open on the Dispatcher; the caller either
    // blocks (synchronous) or polls (async) until it reports OPEN or failed.
    if (!core->submit_control(to_signal(Signal::Open), 0U, false)) {
        core->port_state.store(XCOM_PORT_CLOSED, std::memory_order_release);
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
            const uint16_t st = core->port_state.load(std::memory_order_acquire);
            if (st == XCOM_PORT_OPEN) {
                return XCOM_OK;
            }
            if (st == XCOM_PORT_FAULT || st == XCOM_PORT_CLOSED) {
                return port_state_2_status(core);
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
        // FAULT or CLOSED: the open failed (or was cancelled). Detailed error
        // is in the error ring, matching the synchronous xcom_open contract.
        return port_state_2_status(core);
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
        if (st == XCOM_PORT_CLOSED) {
            return XCOM_OK;   // idempotent
        }
        if (st == XCOM_PORT_OPENING) {
            core->cancel_open.store(1U, std::memory_order_release);
        }
        // If the close cannot be delivered or drains too slowly, roll the
        // published state back to a value the HSM can legally act on next.
        // OPENING (the SerialAo HSM is still Closed) must become CLOSED and
        // advance the session generation so any still-in-flight open event is
        // invalidated; OPEN and FAULT simply return to themselves so a retry
        // close (or explicit reopen) is not blocked by a stuck CLOSING.
        auto rollback_state = [](std::uint16_t prev) noexcept -> std::uint16_t {
            return prev == XCOM_PORT_OPENING ? XCOM_PORT_OPENING : prev;
        };
        core->port_state.store(XCOM_PORT_CLOSING, std::memory_order_release);
        if (!core->submit_control(to_signal(Signal::Close), 0U, true /*critical*/)) {
            core->port_state.store(rollback_state(st), std::memory_order_release);
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
        // Timeout: never leave port_state stuck in CLOSING. Roll back to the
        // pre-close state. An opening session remains OPENING until its owner
        // observes cancel_open and completes the legal HSM close transition.
        core->port_state.store(rollback_state(st), std::memory_order_release);
        return XCOM_ERR_TIMEOUT;
    }
    catch (...) {
        return XCOM_ERR_IO;
    }
}

// v1.1: synchronous-copy + queue-and-return. The core copies data[0:size]
// verbatim into a unique TxBlockPool slot before returning (the caller pointer
// is never retained or re-encoded). Python has already pre-encoded the payload
// (HEX via bytes.fromhex, optional CRLF applied), so neither the HEX flag nor
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
        if (!core->submit_write(desc)) {
            core->tx.release(bid);
            core->metrics.tx_rejected.fetch_add(1U, std::memory_order_relaxed);
            return XCOM_ERR_FULL;
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
// Applies immediately while the port is open; returns XCOM_ERR_NOT_OPEN when
// there is no open physical session, and XCOM_ERR_UNSUPPORTED when RTS/CTS
// flow control owns the RTS pin (the request is silently ignored rather than
// fighting the driver).
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
        // Refuse the RTS half up front under RTS/CTS so the caller gets a
        // deterministic UNSUPPORTED rather than a driver-dependent silence.
        if (rts != 0U && core->cfg_flow_control == 1U) {
            return XCOM_ERR_UNSUPPORTED;
        }
        if (core->sink.owner_set_lines == nullptr ||
            !core->sink.owner_set_lines(core, dtr != 0U, rts != 0U)) {
            return XCOM_ERR_NOT_OPEN;   // virtual session: no physical pin
        }
        return XCOM_OK;
    }
    catch (...) {
        return XCOM_ERR_IO;
    }
}

// v1.1: configure the auto-send template. data is pre-encoded raw bytes; the
// core copies it into a dedicated template slot before returning. interval_ms
// == 0 disables auto-send. flags uses XCOM_SEND_TEXT (HEX/CRLF are pre-applied
// by Python). Coalesced ticks increment auto_tick_coalesced.
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
// keeps its own internal display wake event; the Python CoreWorker drives
// display visibility with a 10 ms poll of xcom_drain_display.

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
        if (!core->display.drain_into(output, capacity, *written, completed)) {
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
