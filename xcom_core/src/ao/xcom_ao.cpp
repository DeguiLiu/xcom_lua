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
#include "coact/pal_windows.hpp"   // coact::pal::monotonic_ms (dispatcher beat)

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

// Compile-time dispatch over the receive-vs-text payload formatter. The hot
// byte loop only ever runs one branch per block; an `if constexpr` keeps the
// per-iteration hex/text decision at compile time (coact-style profile
// dispatch) while the caller picks the concrete instantiation from the runtime
// `hex_view` bit exactly once per block.
// `strip_state` is the Dispatcher-owned ANSI machine carried across blocks so a
// sequence split over two receive blocks still resolves. It is unused by the hex
// instantiation (byte-faithful path), which is why it is a reference parameter
// rather than a member of the free function.
template <bool Hex>
uint32_t format_payload(uint8_t* out, uint32_t budget,
                        const uint8_t* bytes, uint32_t len,
                        std::uint8_t& strip_state, CoreCtx* core) noexcept
{
    if constexpr (Hex) {
        (void)strip_state;
        (void)core;
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
        //
        // Two normalisations for the ImGui log viewport:
        //  1. CRLF -> LF (a lone CR too): ImGui only treats '\n' as a line
        //     break; a raw '\r' renders as a control glyph and corrupts the
        //     row metric.
        //  2. ANSI escape sequences (CSI/OSC/SGR...) and stray C0 control
        //     bytes are stripped: many devices (RT-Thread msh etc.) emit
        //     colour codes, and the ImGui log has no colour semantics —
        //     unstripped they painted the whole viewport dark.  The hex view
        //     is the byte-faithful path for debugging exactly such output.
        //
        // No timestamp is injected here (design §4 item 2): the Lua stage is
        // the single owner of stamping (⑥).  It anchors the batch's ingress_ms
        // to the wall clock once, so a stamp reflects ARRIVAL time rather than
        // format/drain time, and this buffer stays pure data for the script
        // stage.  core->timestamp remains in the ABI but is accepted-and-
        // ignored.  display_at_line_start is still maintained across blocks
        // (part of the display state contract) but no longer drives output.
        (void)core;  // core owns display_at_line_start / strip_state
        const uint32_t n = (len < budget) ? len : budget;
        uint32_t written = 0U;
        bool at_line_start = core->display_at_line_start;
        bool pending_cr = core->rx_pending_cr;
        for (uint32_t i = 0U; i < n; ++i) {
            const uint8_t b = bytes[i];
            // Cross-block CRLF: a CR that was the LAST byte of the previous
            // block set pending_cr. Swallow a leading LF here so the split pair
            // renders one line break, not two. Any other byte ends the carry
            // (matching the in-block rule, which only pairs an adjacent LF).
            if (pending_cr) {
                pending_cr = false;
                if (b == static_cast<uint8_t>('\n') && strip_state == 0U) {
                    continue;
                }
            }
            if (strip_state != 0U) {
                // Inside an escape sequence.
                if (strip_state == 1U) {
                    // Saw ESC: expect '[' (CSI) or ']' (OSC) else terminate.
                    if (b == static_cast<uint8_t>('[')) {
                        strip_state = 2U;
                    } else if (b == static_cast<uint8_t>(']')) {
                        strip_state = 3U;
                    } else if (b >= 0x40U && b <= 0x5FU) {
                        strip_state = 0U;  // two-char escape, done
                    } else {
                        strip_state = 0U;  // lone ESC, swallow
                    }
                } else if (strip_state == 3U) {
                    // OSC: terminated by BEL (0x07) or ST (ESC \).
                    if (b == 0x07U) strip_state = 0U;
                    else if (b == 0x1BU) strip_state = 4U;
                } else if (strip_state == 4U) {
                    strip_state = 0U;  // char after OSC's ESC: done
                } else {
                    // CSI: 0x30..0x3F params, 0x20..0x2F intermediates,
                    // final byte 0x40..0x7E ends the sequence.
                    if (b >= 0x40U && b <= 0x7EU) strip_state = 0U;
                }
                continue;
            }
            if (b == 0x1BU) {  // ESC enters a sequence (consumed)
                strip_state = 1U;
                continue;
            }
            // Classify the byte.  Visible bytes: LF (line break), TAB, or any
            // printable ASCII / UTF-8 continuation.  Everything else (BEL, BS,
            // VT, FF, SO, SI, etc.) is dropped silently.
            const bool is_cr = b == static_cast<uint8_t>('\r');
            const bool is_lf = b == static_cast<uint8_t>('\n');
            const bool is_tab = b == static_cast<uint8_t>('\t');
            const bool is_printable = b >= 0x20U;
            if (!is_cr && !is_lf && !is_tab && !is_printable) {
                continue;
            }
            // Determine what byte to write and whether this is a line boundary.
            uint8_t out_byte = b;
            bool break_line = is_cr || is_lf;
            if (is_cr) {
                out_byte = static_cast<uint8_t>('\n');
                // CRLF -> single LF; consume the paired LF if it follows in
                // THIS block, otherwise carry the CR so the next block can
                // swallow a leading LF (a pair split across the boundary).
                if (i + 1U < n && bytes[i + 1U] == static_cast<uint8_t>('\n')) {
                    ++i;
                }
                else {
                    pending_cr = true;
                }
            }
            if (written >= budget) {
                // No room for the byte; subsequent bytes must be dropped too.
                // Persist the state and stop — the block boundary will resume
                // the line in the next batch.
                core->display_at_line_start = !break_line;
                break;
            }
            out[written++] = out_byte;
            at_line_start = break_line;
        }
        core->display_at_line_start = at_line_start;
        core->rx_pending_cr = pending_cr;
        return written;
    }
}

}  // namespace

// ---------------------------------------------------------------------------
// ReceiveAo - formats Rx blocks into display batches on the Dispatcher.
// ---------------------------------------------------------------------------

bool rx_format_block(RxCtx* self, const uint8_t* bytes, uint32_t len,
                     uint32_t ingress_ms)
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
    // The C++ formatter normalises bytes only (③): CR/CRLF -> LF and ANSI/C0
    // stripping.  It injects NO timestamp — the Lua stage (⑥) is the sole
    // owner of stamping (design §4 item 2), so the batch carries pure data
    // into the script stage.  display_at_line_start is still maintained as
    // display state (reset on open/close, updated here) so the contract is
    // unchanged, but it no longer drives any textual output.
    const bool hex = core->hex_view.load(std::memory_order_acquire) != 0U;
    if (hex) {
        // Hex view is the byte-faithful path: "AA BB CC " with no separator
        // and no prefix.  The former per-block separator/prefix existed only
        // to host the C++ timestamp and went with it.
        const uint32_t payload_written =
            format_payload<true>(out, kDisplayBatchBytes, bytes, len,
                                 core->rx_strip_state, core);
        written = payload_written;
        if (payload_written > 0U) {
            const uint8_t last = out[written - 1U];
            core->display_at_line_start =
                last == static_cast<uint8_t>('\n') ||
                last == static_cast<uint8_t>('\r');
        }
    }
    else {
        // Text view: format_payload<false> owns display_at_line_start state.
        const uint32_t payload_written =
            format_payload<false>(out, kDisplayBatchBytes, bytes, len,
                                  core->rx_strip_state, core);
        written = payload_written;
    }

    if (written == 0U) {
        core->display.release_buf(bid);
        return true;
    }

    // ingress_ms (monotonic, sampled at arrival) rides the display descriptor
    // so the Lua drain can order batches by real arrival time even when the
    // UI formats them seconds later under backlog.
    if (!core->display.push_ready(
            bid, written, ingress_ms, core->generation.load(std::memory_order_acquire))) {
        core->display.release_buf(bid);
        return false;
    }
    core->metrics.display_pending.fetch_add(1U, std::memory_order_relaxed);
    return true;
}

// Dispatcher liveness (design §4.2 item 3): running any dispatched action means
// the coact Dispatcher returned to its loop. Beating here covers a sustained
// event stream (which may never park between batches); the PAL wrapper beats
// after each blocking wait to cover the idle case. These are the two places a
// dispatcher-thread beat can originate without touching coact.
void beat_dispatcher(CoreCtx* core) noexcept
{
    if (core != nullptr) {
        core->heartbeats.dispatcher_ms.store(
            static_cast<std::uint32_t>(coact::pal::monotonic_ms()),
            std::memory_order_relaxed);
    }
}

void rx_kick_action(RxCtx& ctx, const coact::Event&) noexcept
{
    CoreCtx* core = ctx.core;
    if (core == nullptr) {
        return;
    }
    beat_dispatcher(core);
    for (int n = 0; n < 4; ++n) {
        RxDesc d;
        if (ctx.has_deferred) {
            d = ctx.deferred;
            ctx.has_deferred = false;
        }
        else if (!core->rx.pop_display(d)) {
            break;
        }
        if (d.len > kRxBlockBytes) {
            d.len = kRxBlockBytes;
        }
        // The popped descriptor owns exactly one reference to the RX block.
        // On success ReceiveAo consumed it (formatting copied the bytes); on
        // failure the deferred slot keeps owning it until a later kick or
        // teardown. An over-release here would abort inside event_gc.
        if (rx_format_block(&ctx, core->rx.payload(d.event), d.len,
                            d.ingress_ms)) {
            core->rx.release(d.event);
            core->resume_rx();
        }
        else {
            ctx.deferred = d;
            ctx.has_deferred = true;
            break;
        }
    }

    // Close-drain race protocol.
    core->kick_gate.disarm();
    if (!ctx.has_deferred && !core->rx.display_ready_empty() &&
        core->kick_gate.try_arm()) {
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
    beat_dispatcher(core);

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
    beat_dispatcher(core);
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
    beat_dispatcher(core);
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
// DiagnosticAo - the periodic diag-tick sink. See the note in xcom_ao.hpp:
// nothing submits Signal::Diag, so this action is currently unreachable. The
// heartbeat it also beats is driven by the other AO actions in this file.
// ---------------------------------------------------------------------------

void diag_tick_action(DiagCtx& ctx, const coact::Event& evt) noexcept
{
    CoreCtx* core = ctx.core;
    (void)evt;
    if (core == nullptr) {
        return;
    }
    beat_dispatcher(core);
    core->diag_emit(
        0U, static_cast<uint16_t>(DiagEvent::kDiagTick),
        core->metrics.rx_bytes.load(std::memory_order_relaxed),
        core->metrics.tx_rejected.load(std::memory_order_relaxed),
        core->metrics.rx_pool_exhausted_bytes.load(std::memory_order_relaxed),
        core->port_state.load(std::memory_order_relaxed));
}

// ---------------------------------------------------------------------------
// SerialAo - the single owner of the port and the sole author of port_state.
// All native serial-backend open/close/write/configure calls run on this AO's
// single execution context (the coact Dispatcher). The lifecycle is the design
// §2.2 table driven through serial_transition(); no other code path reads
// port_state as a guard or writes it.
// ---------------------------------------------------------------------------

namespace {

enum class SerialAction : uint8_t {
    kNone = 0,
    kOwnerOpen,     // run sink.owner_open (the blocking native open)
    kOwnerClose,    // run sink.owner_close (idempotent release)
    kCancelClose,   // hand the cancelled open off as a Close signal
    kOpenCommit,    // claim the open generation, publish OPEN
    kOpenFail,      // diag kOpenFail; target state CLOSED (no session exists)
    kCloseCommit    // advance the generation, publish CLOSED
};

// Guard for the OPENING --OpenDone--> OPEN edge. Reads the owner-set result,
// never port_state.
bool serial_open_succeeded(const SerialCtx& ctx) noexcept
{
    return ctx.core->last_open_result.load(std::memory_order_acquire) == XCOM_OK;
}

// Transition table, design §2.2. Rows are scanned in order; the first row whose
// (from, event) matches and whose guard passes wins, so the trailing
// guard-less row for an event is its fallback. publish_first publishes the
// target before running the action - required for the intermediate states so
// OPENING is visible while the synchronous owner_open blocks, and so
// CLOSING/FAULT are reflected before teardown runs.
struct SerialEdge {
    SerialState from;
    SerialEvent event;
    bool (*guard)(const SerialCtx&);   // nullptr = unconditional
    SerialState to;
    SerialAction action;
    bool publish_first;
};

constexpr std::array<SerialEdge, 12U> kSerialEdges{{
    // CLOSED/FAULT --Open--> OPENING. FAULT --Open--> OPENING is the explicit
    // edge whose absence was the historical lesion (reopen straight from a
    // fault was silently dropped, so the port stayed dead until an explicit
    // Close).
    {S_CLOSED,  SerialEvent::kOpen,     nullptr,               S_OPENING, SerialAction::kOwnerOpen,   true},
    {S_FAULT,   SerialEvent::kOpen,     nullptr,               S_OPENING, SerialAction::kOwnerOpen,   true},
    // OPENING --OpenDone--> OPEN on success, CLOSED on failure. Failure must be
    // judged by the owner result, not by a stale published state. A failed open
    // never established a session, so it publishes CLOSED (the truth: no port
    // is open) rather than FAULT. FAULT is reserved for a LIVE session that
    // faulted and for the fault-recovery path; overloading it here made the Lua
    // mirror read "a live session faulted" and enter its 8 s reconnect loop.
    // The failure reason is carried by last_open_result, not by the state.
    {S_OPENING, SerialEvent::kOpenDone, &serial_open_succeeded, S_OPEN,    SerialAction::kOpenCommit, false},
    {S_OPENING, SerialEvent::kOpenDone, nullptr,               S_CLOSED,   SerialAction::kOpenFail,   false},
    // OPENING --Cancel--> CLOSING: the ABI timed out or asked to close while
    // the owner_open was still executing. This is an edge, not a side write.
    {S_OPENING, SerialEvent::kCancel,   nullptr,               S_CLOSING,  SerialAction::kCancelClose, true},
    // Any close request from a state that owns (or is tearing down) a session
    // enters CLOSING first, then CloseDone -> CLOSED.
    {S_OPEN,    SerialEvent::kClose,    nullptr,               S_CLOSING,  SerialAction::kOwnerClose,  true},
    {S_FAULT,   SerialEvent::kClose,    nullptr,               S_CLOSING,  SerialAction::kOwnerClose,  true},
    {S_CLOSING, SerialEvent::kClose,    nullptr,               S_CLOSING,  SerialAction::kOwnerClose,  true},
    {S_CLOSING, SerialEvent::kCloseDone, nullptr,              S_CLOSED,   SerialAction::kCloseCommit, false},
    // Fault edges. Only a state with a live session has one: OPENING/OPEN
    // release the handle and land in FAULT, where the reconnect path can
    // recover them. There is deliberately NO CLOSED --Fault--> FAULT edge:
    // publishing FAULT with no session would tell the Lua mirror "a live
    // session faulted" and arm its 8 s reconnect window - the same FAULT
    // overload that F1 removed from a failed open. A late fault report on a
    // CLOSED port is still recorded by serial_do_fault (error ring + diag),
    // it just must not move the state.
    // CLOSING --Fault--> CLOSED: the close is already in flight, so the device
    // disappearing during it means the close succeeded. The handle is released
    // by kOwnerClose (idempotent) and the close intent is satisfied; landing in
    // FAULT instead would strand xcom_close's CLOSED poll until its timeout and
    // report a failure for a close that actually completed (the display/actual
    // mismatch this matrix exists to prevent).
    {S_OPENING, SerialEvent::kFault,    nullptr,               S_FAULT,    SerialAction::kOwnerClose,  true},
    {S_OPEN,    SerialEvent::kFault,    nullptr,               S_FAULT,    SerialAction::kOwnerClose,  true},
    {S_CLOSING, SerialEvent::kFault,    nullptr,               S_CLOSED,   SerialAction::kOwnerClose,  true},
}};

const SerialEdge* serial_find_edge(const SerialCtx& ctx,
                                   SerialEvent event) noexcept
{
    const SerialEdge* found = nullptr;
    for (const SerialEdge& edge : kSerialEdges) {
        if (edge.from == ctx.state && edge.event == event &&
            (edge.guard == nullptr || edge.guard(ctx))) {
            found = &edge;
            break;
        }
    }
    return found;
}

// The only writer of port_state. Called exactly once per entered state.
void serial_publish(SerialCtx& ctx, SerialState state) noexcept
{
    ctx.state = state;
    ctx.core->port_state.store(static_cast<uint16_t>(state),
                               std::memory_order_release);
}

// Session boundary for the display lane: release every undrained batch back to
// the pool and retire the matching display_pending count. Called on the
// Dispatcher from both commit paths so a close cannot strand the ring's 32 ids
// and a reopen cannot drain the previous session's bytes. See
// DisplayLane::reset for why this cannot run concurrently with drain_into.
void reset_display_at_commit(CoreCtx* core) noexcept
{
    const uint32_t drained = core->display.reset();
    if (drained != 0U) {
        core->metrics.display_pending.fetch_sub(drained,
                                                std::memory_order_relaxed);
    }
}

SerialState serial_run_action(SerialCtx& ctx, SerialAction action,
                              SerialState target) noexcept
{
    CoreCtx* const core = ctx.core;
    SerialState outcome = target;
    switch (action) {
    case SerialAction::kOwnerOpen:
        if (core->sink.owner_open != nullptr) {
            core->sink.owner_open(core);
        }
        break;
    case SerialAction::kOwnerClose:
        if (core->sink.owner_close != nullptr) {
            core->sink.owner_close(core);
        }
        break;
    case SerialAction::kCancelClose:
        if (false == core->submit_control(to_signal(Signal::Close), 0U, true)) {
            // The critical reserve should make this exceptional. Close the
            // physical resources directly as the deliberate last resort, leave
            // a visible fault, and require the normal close/reset path before
            // reopen.
            if (core->sink.owner_close != nullptr) {
                core->sink.owner_close(core);
            }
            core->errors.push(XCOM_ERR_FULL, 0U,
                              "open cancellation close event rejected");
            outcome = S_FAULT;
        }
        break;
    case SerialAction::kOpenCommit:
        core->open_generation.fetch_add(1U, std::memory_order_relaxed);
        core->generation.store(
            core->open_generation.load(std::memory_order_relaxed),
            std::memory_order_release);
        core->display_at_line_start = true;
        core->rx_strip_state = 0U;
        core->rx_pending_cr = false;
        reset_display_at_commit(core);
        core->diag_emit(0U, static_cast<uint16_t>(DiagEvent::kOpenOk),
                        core->cfg_baud,
                        core->generation.load(std::memory_order_relaxed), 0U, 0U);
        break;
    case SerialAction::kOpenFail:
        core->diag_emit(0U, static_cast<uint16_t>(DiagEvent::kOpenFail),
                        core->last_open_result.load(std::memory_order_relaxed),
                        core->generation.load(std::memory_order_relaxed), 0U, 0U);
        break;
    case SerialAction::kCloseCommit:
        core->generation.fetch_add(1U, std::memory_order_relaxed);
        core->display_at_line_start = true;
        core->rx_strip_state = 0U;
        core->rx_pending_cr = false;
        reset_display_at_commit(core);
        core->diag_emit(0U, static_cast<uint16_t>(DiagEvent::kCloseOk),
                        core->generation.load(std::memory_order_relaxed),
                        0U, 0U, 0U);
        break;
    case SerialAction::kNone:
    default:
        break;
    }
    return outcome;
}

// Reconcile an off-Dispatcher fault latch into the HSM. serial_fault_callback /
// sink_owner_write run on the backend read / writer thread and cannot mutate the
// Dispatcher-owned SerialCtx::state; when their critical Fault signal is
// rejected (control pool exhausted) they publish port_state=FAULT directly (I1
// exception) and set CoreCtx::fault_pending. Adopt that publish here, on the
// Dispatcher, by running the real Fault edge: its kOwnerClose releases the stale
// COM handle (and joins the writer) - which the reporter could not do without
// self-joining its own thread - and the local state becomes S_FAULT so a
// following Open finds the FAULT --Open--> OPENING edge instead of timing out.
// Only the Dispatcher calls this; it is the design-exception-matrix rule 6
// reconciliation.
void serial_reconcile_pending_fault(SerialCtx& ctx) noexcept
{
    CoreCtx* const core = ctx.core;
    if (core != nullptr &&
        core->fault_pending.exchange(0U, std::memory_order_acq_rel) != 0U) {
        serial_transition(ctx, SerialEvent::kFault);
    }
}

}  // namespace

void serial_transition(SerialCtx& ctx, SerialEvent event) noexcept
{
    CoreCtx* const core = ctx.core;
    if (core != nullptr) {
        const SerialEdge* const edge = serial_find_edge(ctx, event);
        if (edge != nullptr) {
            if (edge->publish_first) {
                serial_publish(ctx, edge->to);
                const SerialState outcome =
                    serial_run_action(ctx, edge->action, edge->to);
                if (outcome != edge->to) {
                    // Cancel handoff fallback: the Close signal was rejected,
                    // so the edge lands in FAULT instead of CLOSING.
                    serial_publish(ctx, outcome);
                }
            }
            else {
                const SerialState outcome =
                    serial_run_action(ctx, edge->action, edge->to);
                serial_publish(ctx, outcome);
            }
        }
    }
}

void serial_do_open(SerialCtx& ctx, const coact::Event&) noexcept
{
    CoreCtx* const core = ctx.core;
    if (core != nullptr) {
        // Liveness: a serial lifecycle action still proves the Dispatcher ran;
        // the observer suspends evaluation while a port is OPENING/CLOSING so a
        // long legitimate owner_open/close is not read as a wedge.
        beat_dispatcher(core);
        // A rejected off-Dispatcher fault (see serial_reconcile_pending_fault)
        // may have left port_state=FAULT while the local state is still OPEN.
        // Run the Fault edge now so owner_close releases the stale handle before
        // owner_open tries to CreateFile it (a still-held handle fails with
        // ACCESS_DENIED) and the Open edge below is found.
        serial_reconcile_pending_fault(ctx);
        // CLOSED/FAULT -> OPENING (published before the blocking owner_open).
        serial_transition(ctx, SerialEvent::kOpen);
        if (core->last_open_result.load(std::memory_order_acquire) != XCOM_OK) {
            // Owner open failed: OPENING -> CLOSED (no session was ever
            // established, so there is nothing to recover). Checked before
            // Cancel so a
            // combined failure + timeout still reports the failure.
            serial_transition(ctx, SerialEvent::kOpenDone);
        }
        else if (core->cancel_open.exchange(0U, std::memory_order_acq_rel) != 0U) {
            // ABI timed out or asked to close while owner_open was executing:
            // OPENING -> CLOSING through the table.
            serial_transition(ctx, SerialEvent::kCancel);
        }
        else {
            // OPENING -> OPEN.
            serial_transition(ctx, SerialEvent::kOpenDone);
        }
    }
}

void serial_do_close(SerialCtx& ctx, const coact::Event&) noexcept
{
    CoreCtx* const core = ctx.core;
    if (core != nullptr) {
        beat_dispatcher(core);
        // OPEN/FAULT/CLOSING -> CLOSING (published on entry), then the
        // in-function completion -> CLOSED.
        serial_transition(ctx, SerialEvent::kClose);
        serial_transition(ctx, SerialEvent::kCloseDone);
        // A latched off-Dispatcher fault is satisfied by this close (kClose and
        // kCloseDone run owner_close, releasing the handle); drop it so it
        // cannot re-trigger a Fault edge on a later lifecycle event.
        core->fault_pending.store(0U, std::memory_order_release);
    }
}

void serial_do_fault(SerialCtx& ctx, const coact::Event&) noexcept
{
    CoreCtx* const core = ctx.core;
    // A Fault while already FAULT was a dropped event before (no HSM self-edge)
    // and must stay one: re-running owner_close and re-pushing the error entry
    // would duplicate the visible fault for every repeated read-thread report.
    if (core != nullptr && ctx.state != S_FAULT) {
        beat_dispatcher(core);
        // The fault is being processed here; any off-Dispatcher latch for the
        // same fault is satisfied (the reconcile path would otherwise re-run
        // this edge on the next Open).
        core->fault_pending.store(0U, std::memory_order_release);
        // Publish FAULT and release the physical session. Leaving the COM
        // handle, read/write events and SessionWriter thread alive until the
        // user clicks Close is the root cause of "replugging the same COM port
        // fails with ACCESS_DENIED": the stale handle still owns the device, so
        // a fresh CreateFile cannot succeed. The read thread has already
        // returned (report_fault is its last act before exiting read_loop) when
        // this runs on the Dispatcher, so the owner_close join cannot deadlock.
        // owner_close is idempotent with the later CLOSING teardown.
        serial_transition(ctx, SerialEvent::kFault);
        core->errors.push(XCOM_ERR_IO, 0,
                          "serial device removed / port fault; close then reopen");
        core->diag_emit(0U, static_cast<uint16_t>(DiagEvent::kFault),
                        static_cast<uint32_t>(XCOM_ERR_IO),
                        core->generation.load(std::memory_order_relaxed), 0U, 0U);
    }
}

}  // namespace xcom
