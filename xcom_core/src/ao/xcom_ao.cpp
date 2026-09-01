// xcom_ao.cpp - XCOM Active Object action implementations, moved out of the
// header for compilation isolation.
//
// xcom_ao.hpp now carries only the context structs, the HSM state enums, the
// coact AO Traits and the declarations of the action callbacks the HSM
// transition tables reference (built in xcom_core.cpp). The bodies of every
// action (rx_format_block / rx_kick_action / send_* / diag_* / serial_do_*)
// live in this single TU so editing them does not drag in coact/hsm.hpp's
// inline machinery across every include of xcom_ao.hpp. Behaviours, the action
// signatures and their noexcept annotations are unchanged from the inline
// copies they replace.
//
// SPDX-License-Identifier: MIT
#include "xcom_ao.hpp"

#include "xcom_core.hpp"
#include "diagnostic.hpp"

#include "coact/event.hpp"

#include <cstdio>
#include <array>
#include <algorithm>
#include <cstring>
#include <string_view>

namespace xcom {

namespace {

using HexPair = std::array<char, 2U>;
using HexPairTable = std::array<HexPair, 256U>;

constexpr HexPairTable make_hex_pair_table() noexcept
{
    constexpr std::string_view digits{"0123456789ABCDEF"};
    HexPairTable table{};
    for (uint16_t value = 0U; value < 256U; ++value) {
        table[value][0] = digits[(value >> 4U) & 0x0FU];
        table[value][1] = digits[value & 0x0FU];
    }
    return table;
}

alignas(64) constexpr HexPairTable kHexPairs = make_hex_pair_table();

constexpr std::uint32_t kTimestampPrefixBytes = 15U;

struct TimestampPrefixCache final {
    std::uint32_t second_of_day = 86400U;
    std::array<std::uint8_t, kTimestampPrefixBytes> bytes{};
};

void write_two_digits(std::uint8_t* out, std::uint16_t value) noexcept
{
    out[0] = static_cast<std::uint8_t>('0' + ((value / 10U) % 10U));
    out[1] = static_cast<std::uint8_t>('0' + (value % 10U));
}

void write_three_digits(std::uint8_t* out, std::uint16_t value) noexcept
{
    out[0] = static_cast<std::uint8_t>('0' + ((value / 100U) % 10U));
    out[1] = static_cast<std::uint8_t>('0' + ((value / 10U) % 10U));
    out[2] = static_cast<std::uint8_t>('0' + (value % 10U));
}

// Compile-time dispatch over the receive-vs-text payload formatter. The hot
// byte loop only ever runs one branch per block; an `if constexpr` keeps the
// per-iteration hex/text decision at compile time (coact-style profile
// dispatch) while the caller picks the concrete instantiation from the runtime
// `hex_view` bit exactly once per block.
template <bool Hex>
uint32_t format_payload(uint8_t* out, uint32_t budget,
                        const uint8_t* bytes, uint32_t len) noexcept
{
    if constexpr (Hex) {
        // Each input byte expands to "AA BB " (3 chars). cap_hex reproduces the
        // exact stopping point of the pre-refactor bound
        // ((budget-4)/3 groups, then the trailing space is dropped), so the
        // hex output is byte-for-byte identical.
        const uint32_t cap_hex =
            (budget > 4U) ? ((budget - 4U) / 3U + 1U) : 0U;
        const uint32_t n = (len < cap_hex) ? len : cap_hex;
        uint32_t written = 0U;
        for (uint32_t i = 0U; i < n; ++i) {
            const uint32_t v = bytes[i];
            const HexPair& pair = kHexPairs[v];
            out[written++] = static_cast<uint8_t>(pair[0]);
            out[written++] = static_cast<uint8_t>(pair[1]);
            out[written++] = static_cast<uint8_t>(' ');
        }
        if (n > 0U) {
            --written;  // drop trailing space
        }
        return written;
    }
    else {
        // Text view transfers the borrowed payload into its owned display slot.
        const uint32_t n = (len < budget) ? len : budget;
        if (n > 0U) {
            std::memcpy(out, bytes, n);
        }
        return n;
    }
}

}  // namespace

// ---------------------------------------------------------------------------
// ReceiveAo - formats Rx blocks into display batches on the Dispatcher.
// ---------------------------------------------------------------------------

uint32_t rx_timestamp_prefix(const CoreCtx* core, uint8_t* out) noexcept
{
    if (core == nullptr || out == nullptr ||
        core->timestamp.load(std::memory_order_acquire) == 0U) {
        return 0U;
    }
    SYSTEMTIME st{};
    GetLocalTime(&st);
    const std::uint32_t second_of_day =
        static_cast<std::uint32_t>(st.wHour) * 3600U +
        static_cast<std::uint32_t>(st.wMinute) * 60U + st.wSecond;
    thread_local TimestampPrefixCache cache{};
    if (cache.second_of_day != second_of_day) {
        cache.second_of_day = second_of_day;
        cache.bytes[0] = static_cast<std::uint8_t>('[');
        write_two_digits(cache.bytes.data() + 1U, st.wHour);
        cache.bytes[3] = static_cast<std::uint8_t>(':');
        write_two_digits(cache.bytes.data() + 4U, st.wMinute);
        cache.bytes[6] = static_cast<std::uint8_t>(':');
        write_two_digits(cache.bytes.data() + 7U, st.wSecond);
        cache.bytes[9] = static_cast<std::uint8_t>('.');
        cache.bytes[13] = static_cast<std::uint8_t>(']');
        cache.bytes[14] = static_cast<std::uint8_t>(' ');
    }
    write_three_digits(cache.bytes.data() + 10U, st.wMilliseconds);
    std::memcpy(out, cache.bytes.data(), cache.bytes.size());
    return kTimestampPrefixBytes;
}

bool rx_format_block(RxCtx* self, const uint8_t* bytes, uint32_t len)
{
    CoreCtx* core = self->core;

    if (core->pause_display.load(std::memory_order_acquire) != 0U) {
        // Pause freezes presentation, not acquisition. Keep this RxBlock in
        // ReceiveAo's deferred slot; resuming display submits a new RxKick and
        // processing continues from this exact block. Capacity exhaustion then
        // propagates through the serial RTS/wait backpressure path instead of
        // silently discarding bytes received while the view was paused.
        core->metrics.display_paused_bytes.fetch_add(
            len, std::memory_order_relaxed);
        return false;
    }

    uint16_t bid = 0U;
    uint8_t* out = nullptr;
    if (!core->display.try_acquire(bid, out)) {
        return false;
    }

    uint32_t written = 0U;
    // Reserve room for the timestamp prefix up front; the payload branches
    // budget against the remaining capacity (kDisplayBatchBytes - ts).
    const uint32_t ts = rx_timestamp_prefix(core, out);
    written += ts;
    const uint32_t budget = kDisplayBatchBytes - ts;
    // Compile-time specialize the hex vs text formatter on the runtime view
    // bit; the branch is resolved once per block, not per input byte.
    written += (core->hex_view.load(std::memory_order_acquire) != 0U)
                   ? format_payload<true>(out + written, budget, bytes, len)
                   : format_payload<false>(out + written, budget, bytes, len);

    if (written == 0U) {
        core->display.release_buf(bid);
        return true;
    }

    const uint32_t seq = core->metrics.display_seq.fetch_add(
        1U, std::memory_order_relaxed);
    if (!core->display.push_ready(bid, written, seq)) {
        core->display.release_buf(bid);
        return false;
    }
    core->metrics.display_pending.fetch_add(1U, std::memory_order_relaxed);
    return true;
}

void rx_kick_action(RxCtx& ctx, const coact::Event&) noexcept
{
    CoreCtx* core = ctx.core;
    if (core == nullptr) {
        return;
    }
    for (int n = 0; n < 4; ++n) {
        RxDesc d;
        if (ctx.has_deferred) {
            d = ctx.deferred;
            ctx.has_deferred = false;
        }
        else if (!core->rx.pop_ready(d)) {
            break;
        }
        if (d.len > kRxBlockBytes) {
            d.len = kRxBlockBytes;
        }
        if (rx_format_block(&ctx, core->rx.block(d.block), d.len)) {
            core->rx.release_block(d.block);
            if (core->rx_backpressured.exchange(
                    0U, std::memory_order_acq_rel) != 0U) {
                core->resume_rx();
            }
        }
        else {
            ctx.deferred = d;
            ctx.has_deferred = true;
            break;
        }
    }

    // Close-drain race protocol.
    core->kick_gate.disarm();
    if (!ctx.has_deferred && !core->rx.ready_empty() && core->kick_gate.try_arm()) {
        core->submit_rx_kick();
    }
}

// ---------------------------------------------------------------------------
// SendAo - auto-send coalescing (last-value-wins) + manual-send routing.
// ---------------------------------------------------------------------------

void autosend_config_action(SendCtx& ctx, const coact::Event& evt) noexcept
{
    CoreCtx* const core = ctx.core;
    const AutoTemplateLayout* const layout =
        reinterpret_cast<const AutoTemplateLayout*>(&evt);
    const AutoTemplateDescriptor* const descriptor =
        reinterpret_cast<const AutoTemplateDescriptor*>(layout->payload);
    if (core == nullptr) {
        return;
    }

    const bool enable = descriptor->interval_ms != 0U;
    const bool valid = !enable ||
        (descriptor->block != 0xFFFFU && descriptor->length != 0U &&
         descriptor->length <= kTxBlockBytes);
    if (!valid) {
        if (enable && descriptor->block != 0xFFFFU) {
            core->tx.release(descriptor->block);
        }
        core->errors.push(XCOM_ERR_PARAM, 0U, "invalid auto-send template");
        return;
    }

    // This AO is the only template reader and runs on the Dispatcher. Stop
    // timer callbacks before replacing its owned TxBlock; no mutex or shared
    // buffer is needed.
    if (core->sink.autosend_set != nullptr) {
        core->sink.autosend_set(core, 0U);
    }
    if (ctx.autosend_block != 0xFFFFU) {
        core->tx.release(ctx.autosend_block);
    }
    ctx.autosend_block = 0xFFFFU;
    ctx.autosend_length = 0U;
    ctx.autosend_interval_ms = 0U;
    core->autosend_armed.store(0U, std::memory_order_release);

    if (!enable) {
        return;
    }
    ctx.autosend_block = descriptor->block;
    ctx.autosend_length = descriptor->length;
    ctx.autosend_interval_ms = descriptor->interval_ms;
    if (core->sink.autosend_set != nullptr) {
        core->sink.autosend_set(core, ctx.autosend_interval_ms);
    }
}

void send_autosend_action(SendCtx& ctx, const coact::Event&) noexcept
{
    CoreCtx* core = ctx.core;
    if (core == nullptr) {
        return;
    }
    if (core->port_state.load(std::memory_order_acquire) != XCOM_PORT_OPEN) {
        core->autosend_armed.store(0U, std::memory_order_release);
        return;
    }
    const uint32_t size = ctx.autosend_length;
    if (ctx.autosend_block == 0xFFFFU || size == 0U) {
        core->autosend_armed.store(0U, std::memory_order_release);
        return;
    }
    uint16_t bid = 0U;
    uint8_t* dst = core->tx.try_alloc(bid);
    if (dst == nullptr) {
        core->metrics.tx_rejected.fetch_add(1U, std::memory_order_relaxed);
        core->autosend_armed.store(0U, std::memory_order_release);
        return;
    }
    std::memcpy(dst, core->tx.block(ctx.autosend_block), size);
    const TxDescriptor desc{
        bid, static_cast<uint16_t>(size),
        core->generation.load(std::memory_order_acquire)};
    const bool ok = core->enqueue_write(bid, static_cast<uint16_t>(size),
                                        desc.generation, true);
    if (!ok) {
        core->tx.release(bid);
        core->metrics.tx_rejected.fetch_add(1U, std::memory_order_relaxed);
        core->autosend_armed.store(0U, std::memory_order_release);
    }
    // The gate stays armed until SessionWriter consumes this automatic job.
    // That bounds a slow serial peer to one queued-or-in-flight auto packet.
}

void send_user_action(SendCtx& ctx, const coact::Event& evt) noexcept
{
    CoreCtx* core = ctx.core;
    if (core == nullptr) {
        return;
    }
    const TxWriteLayout* lay = reinterpret_cast<const TxWriteLayout*>(&evt);
    const TxDescriptor* desc =
        reinterpret_cast<const TxDescriptor*>(lay->payload);
    const bool stale = (desc->generation !=
                        core->generation.load(std::memory_order_acquire)) ||
                       (core->port_state.load(std::memory_order_acquire) !=
                        XCOM_PORT_OPEN);
    if (stale) {
        core->tx.release(desc->block);
        return;
    }
    if (!core->enqueue_write(desc->block, desc->length, desc->generation,
                             false)) {
        core->tx.release(desc->block);
        core->metrics.tx_rejected.fetch_add(1U, std::memory_order_relaxed);
        core->errors.push(XCOM_ERR_FULL, 0, "serial write queue full");
    }
}

// ---------------------------------------------------------------------------
// DiagnosticAo - periodic snapshot / heartbeat accounting.
// ---------------------------------------------------------------------------

void diag_tick_action(DiagCtx& ctx, const coact::Event& evt) noexcept
{
    CoreCtx* core = ctx.core;
    (void)evt;
    if (core == nullptr) {
        return;
    }
    core->diag_emit(
        0U, static_cast<uint16_t>(DiagEvent::kDiagTick),
        core->metrics.rx_bytes.load(std::memory_order_relaxed),
        core->metrics.tx_rejected.load(std::memory_order_relaxed),
        core->metrics.rx_pool_exhausted_bytes.load(std::memory_order_relaxed),
        core->port_state.load(std::memory_order_relaxed));
}

// ---------------------------------------------------------------------------
// SerialAo - the single owner of the port. HSM: Closed/Open/Fault. All
// Native serial-backend open/close/write/configure calls run on this AO's single
// execution context (the coact Dispatcher).
// ---------------------------------------------------------------------------

void serial_do_open(SerialCtx& ctx, const coact::Event&) noexcept
{
    CoreCtx* core = ctx.core;
    if (core == nullptr) {
        return;
    }
    if (core->sink.owner_open != nullptr) {
        core->sink.owner_open(core);
    }
    if (core->port_state.load(std::memory_order_acquire) == XCOM_PORT_FAULT) {
        core->diag_emit(0U, static_cast<uint16_t>(DiagEvent::kOpenFail),
                        core->last_open_result.load(std::memory_order_relaxed),
                        core->generation.load(std::memory_order_relaxed),
                        0U, 0U);
        return;
    }
    if (core->cancel_open.exchange(0U, std::memory_order_acq_rel) != 0U) {
        // The C ABI caller timed out or asked to close while owner_open was
        // executing. This action is completing the Closed -> Open transition,
        // so post Close for the subsequent Open state instead of allowing a
        // stale OPEN publication or an ignored Close in Closed.
        core->port_state.store(XCOM_PORT_CLOSING, std::memory_order_release);
        if (!core->submit_control(to_signal(Signal::Close), 0U, true)) {
            // The critical reserve should make this exceptional. Close the
            // physical resources directly as a safe fallback, leave a visible
            // fault, and require the normal close/reset path before reopen.
            if (core->sink.owner_close != nullptr) {
                core->sink.owner_close(core);
            }
            core->port_state.store(XCOM_PORT_FAULT, std::memory_order_release);
            core->errors.push(XCOM_ERR_FULL, 0U,
                              "open cancellation close event rejected");
        }
        return;
    }
    core->open_generation.fetch_add(1U, std::memory_order_relaxed);
    core->generation.store(core->open_generation.load(std::memory_order_relaxed),
                           std::memory_order_release);
    core->port_state.store(XCOM_PORT_OPEN, std::memory_order_release);
    core->diag_emit(0U, static_cast<uint16_t>(DiagEvent::kOpenOk),
                    core->cfg_baud, core->generation.load(
                        std::memory_order_relaxed), 0U, 0U);
}

void serial_do_close(SerialCtx& ctx, const coact::Event&) noexcept
{
    CoreCtx* core = ctx.core;
    if (core == nullptr) {
        return;
    }
    if (core->sink.owner_close != nullptr) {
        core->sink.owner_close(core);
    }
    core->generation.fetch_add(1U, std::memory_order_relaxed);
    core->port_state.store(XCOM_PORT_CLOSED, std::memory_order_release);
    core->diag_emit(0U, static_cast<uint16_t>(DiagEvent::kCloseOk),
                    core->generation.load(std::memory_order_relaxed),
                    0U, 0U, 0U);
}

void serial_do_fault(SerialCtx& ctx, const coact::Event&) noexcept
{
    CoreCtx* core = ctx.core;
    if (core == nullptr) {
        return;
    }
    core->port_state.store(XCOM_PORT_FAULT, std::memory_order_release);
    core->errors.push(XCOM_ERR_IO, 0,
                      "serial device removed / port fault; close then reopen");
    core->diag_emit(0U, static_cast<uint16_t>(DiagEvent::kFault),
                    static_cast<uint32_t>(XCOM_ERR_IO), core->generation.load(
                        std::memory_order_relaxed), 0U, 0U);
}

}  // namespace xcom
