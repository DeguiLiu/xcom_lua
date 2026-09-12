/* xcom.h - versioned C ABI contract for xcom_core.dll.
 *
 * THE authoritative cross-language contract between the C++17 core and the
 * LuaJIT client (xcom_lua/core/xcom_ffi.lua via LuaJIT FFI).
 *
 * All functions never throw across the boundary; every exported function
 * wraps its body and returns XcomStatus / safe values.  Struct layouts are
 * fixed (no hidden padding: explicit _pad fields), MSVC x64 natural
 * alignment (/Zp8 default), so the FFI mirrors MUST match exactly; the Lua
 * binding pins every sizeof at load time.
 *
 * Concurrency: only ONE caller thread (the Lua UI thread) may call into this
 * ABI at a time.  Inside the core all work is serialized onto the coact
 * Dispatcher.  No exported function blocks the caller thread waiting on a
 * Win32 HANDLE; the client drives visibility with a 10 ms poll of
 * xcom_drain_display (there is deliberately no exported xcom_wait_display).
 *
 * v1.1 (2026-08-31):
 *  - xcom_send: synchronous-copy semantics (DLL copies data[0:size] into
 *    TxBlockPool before returning, or returns rejected/error; never retains
 *    the caller pointer).  It does NOT block waiting for the WriteResult;
 *    that result is returned asynchronously via snapshot/error.
 *  - Removed public xcom_wait_display.
 *  - Replaced xcom_set_autosend(const XcomAutoSendConfig*) with
 *    xcom_set_auto_template(h, data, size, interval_ms, flags); the struct is
 *    gone and the client must pre-encode (HEX decoded in Lua).
 *
 * v1.3 (2026-09-01):
 *  - Added xcom_open_async + xcom_take_open_result so the LuaJIT client can
 *    move the ~2 s blocking open off its single message-loop thread.  The
 *    synchronous xcom_open remains byte-for-byte compatible.
 *
 * v1.4 (2026-09-13):
 *  - Added xcom_set_lines for live DTR/RTS hot switching (1 = asserted).
 *    open() now pins the requested levels with EscapeCommFunction instead of
 *    trusting the driver-dependent DCB DISABLE value.
 *
 * v1.5 (2026-09-13):
 *  - Read-loop line-error monitoring: ClearCommError is now called after each
 *    completed read, surfacing driver receive faults (CE_FRAME/CE_RXPARITY/
 *    CE_RXOVER|CE_OVERRUN/CE_BREAK) that were previously discarded silently.
 *    XcomSnapshot gains four monotonic counters appended AFTER the v1.4 fields
 *    (existing offsets unchanged; struct_size drives compatibility). Added the
 *    TEST-ONLY xcom_test_inject_line_errors seam so the counting contract is
 *    verifiable without serial hardware.
 *  - Receive-loss observability: XcomSnapshot gains rx_sequence, rx_loss_offset
 *    and rx_backpressure_events (appended after the line-error counters) so the
 *    client can show WHERE in the accepted stream a loss occurred and warn
 *    before the driver FIFO overruns.
 */
#ifndef XCOM_H_
#define XCOM_H_

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#ifdef _WIN32
#  if defined(XCOM_CORE_BUILD)
#    define XCOM_API __declspec(dllexport)
#  else
#    define XCOM_API __declspec(dllimport)
#  endif
#else
#  define XCOM_API
#endif

#define XCOM_VERSION_MAJOR 1
#define XCOM_VERSION_MINOR 5
#define XCOM_VERSION_PATCH 0

/* ---------------------------------------------------------------------------
 * Result codes (must match xcom_client/services/core_wrapper.py)
 * ------------------------------------------------------------------------- */
typedef int32_t XcomStatus;
enum {
  XCOM_OK = 0,
  XCOM_ERR_PARAM = -1,          /* bad argument / bad struct_size / bad hex */
  XCOM_ERR_NOT_OPEN = -2,       /* operation requires an open port */
  XCOM_ERR_ALREADY_OPEN = -3,
  XCOM_ERR_BUSY = -4,           /* open in progress / closing */
  XCOM_ERR_FULL = -5,           /* queue / TxBlockPool full (tx_rejected++) */
  XCOM_ERR_IO = -6,             /* serial / Win32 error (see XcomError) */
  XCOM_ERR_TIMEOUT = -7,        /* close/send timed out */
  XCOM_ERR_DRAIN_INCOMPLETE = -8,
  XCOM_ERR_UNSUPPORTED = -9,
};

/* ---------------------------------------------------------------------------
 * Opaque handle
 * ------------------------------------------------------------------------- */
typedef void* XcomHandle;

/* ---------------------------------------------------------------------------
 * Create options
 * ------------------------------------------------------------------------- */
typedef struct XcomCreateOptions {
  uint32_t struct_size;   /* sizeof(XcomCreateOptions) */
  uint32_t flags;         /* reserved, must be 0 */
} XcomCreateOptions;

/* ---------------------------------------------------------------------------
 * Port configuration
 * ------------------------------------------------------------------------- */
typedef struct XcomPortConfig {
  uint32_t struct_size;   /* sizeof(XcomPortConfig) */
  const char* port;       /* e.g. "COM3"; UTF-8, NUL-terminated, borrowed for call */
  uint32_t baud_rate;     /* 9600 .. 115200 .. 921600 .. 1500000 */
  uint8_t  data_bits;     /* 5..8 */
  uint8_t  stop_bits;     /* 0 = 1, 1 = 1.5, 2 = 2 */
  uint8_t  parity;        /* 0 = none, 1 = odd, 2 = even, 3 = mark, 4 = space */
  uint8_t  flow_control;  /* 0 = none, 1 = hw(RTS/CTS), 2 = sw(XON/XOFF) */
  uint8_t  dtr_enable;    /* 0/1 */
  uint8_t  rts_enable;    /* 0/1 */
  uint8_t  _pad[2];
} XcomPortConfig;

/* ---------------------------------------------------------------------------
 * Send flags
 *
 * NOTE (v1.1): the client pre-encodes the payload once before calling
 * xcom_send / xcom_set_auto_template.  HEX input is decoded in Lua; the core
 * does NOT parse hex itself.  The data is therefore always already-encoded
 * raw bytes.
 * ------------------------------------------------------------------------- */
typedef uint32_t XcomSendFlags;
enum {
  XCOM_SEND_TEXT = 0,     /* data is already-encoded raw bytes (default) */
  /* XCOM_SEND_HEX is retained ONLY for source compatibility / optional use.
   * The client has already pre-encoded the payload (HEX decoded in Lua), so
   * the core does not parse hex; this flag is accepted but treated as opaque
   * and does not trigger any core-side re-encoding. */
  XCOM_SEND_HEX  = 1,
  XCOM_SEND_CRLF = 2,     /* append CR LF after the payload
                           * (optional; the client may already have appended it) */
};

/* ---------------------------------------------------------------------------
 * Display / receive formatting options
 * ------------------------------------------------------------------------- */
typedef struct XcomDisplayOptions {
  uint32_t struct_size;   /* sizeof(XcomDisplayOptions) */
  uint8_t  hex_view;      /* 0 = text, 1 = hex */
  uint8_t  timestamp;     /* 0 = off, 1 = prefix [HH:MM:SS.mmm] */
  uint8_t  pause_display; /* 0 = off, 1 = freeze view; retained Rx applies backpressure */
  uint8_t  _pad0;
  uint32_t auto_clear_bytes;   /* 0 = off; else trim threshold on the widget */
  uint32_t max_display_bytes;  /* default 2 MiB */
} XcomDisplayOptions;

/* NOTE: the v1.0 XcomAutoSendConfig struct / xcom_set_autosend have been
 * removed.  Auto-send is configured via xcom_set_auto_template(h, data,
 * size, interval_ms, flags).  No binding for XcomAutoSendConfig exists any
 * more. */

/* ---------------------------------------------------------------------------
 * Snapshot (diagnostics + status bar).  All counters are monotonic.
 * ------------------------------------------------------------------------- */
typedef struct XcomSnapshot {
  uint32_t struct_size;        /* sizeof(XcomSnapshot) */
  uint32_t rx_bytes;           /* bytes read from the port, always counted */
  uint32_t tx_bytes;           /* bytes written to the port */
  uint32_t rx_pool_exhausted_bytes;
  uint32_t tx_rejected;
  uint32_t auto_tick_coalesced;
  uint32_t ui_trimmed_bytes;
  uint32_t save_rejected_bytes;
  uint32_t display_paused_bytes;   /* bytes retained at the paused display boundary */
  uint32_t callback_count;
  uint32_t generation;             /* session generation (increments per open) */
  uint32_t display_pending;        /* >0: more display batches are buffered */
  uint16_t port_state;             /* XCOM_PORT_* */
  uint8_t  _pad[2];
  /* v1.5 line-error counters (ClearCommError), appended AFTER every v1.0..v1.4
   * field so their offsets are unchanged. Monotonic across sessions, like the
   * other counters. ClearCommError returns a latched bitmask rather than
   * counts, so each completed read contributes at most 1 per category. */
  uint32_t framing_errors;         /* CE_FRAME: stop-bit / framing fault */
  uint32_t parity_errors;          /* CE_RXPARITY: parity mismatch */
  uint32_t overrun_errors;         /* CE_RXOVER | CE_OVERRUN: driver RX overflow */
  uint32_t break_events;           /* CE_BREAK: break condition on the line */
  /* v1.5 loss-observability counters (appended AFTER the line-error block so
   * every previous offset is unchanged; struct_size drives compatibility).
   * rx_sequence is the monotonic count of committed Rx blocks; rx_loss_offset
   * is the accepted-byte offset at which the most recent receive loss (pool
   * drop or driver overrun) was observed, so a gap can be located in the
   * received stream. rx_backpressure_events counts episodes where the live
   * read callback found every Rx block in use and withheld reads: no bytes are
   * lost on that path, but a rising count is the host-side early warning that
   * the driver FIFO is what fills next (and then overruns, overrun_errors). */
  uint32_t rx_sequence;
  uint32_t rx_loss_offset;
  uint32_t rx_backpressure_events;
} XcomSnapshot;

enum {
  XCOM_PORT_CLOSED = 0,
  XCOM_PORT_OPENING = 1,
  XCOM_PORT_OPEN = 2,
  XCOM_PORT_CLOSING = 3,
  XCOM_PORT_FAULT = 4,
};

/* ---------------------------------------------------------------------------
 * Error record (128-entry ring; xcom_take_error pops one)
 * ------------------------------------------------------------------------- */
typedef struct XcomError {
  uint32_t struct_size;   /* sizeof(XcomError) */
  int32_t  code;          /* XcomStatus or native Win32 serial error code */
  uint16_t source;        /* 0 = core, 1 = serial backend, 2 = Win32 */
  uint16_t _pad;
  char     message[256];
} XcomError;

/* ---------------------------------------------------------------------------
 * Port enumeration
 * ------------------------------------------------------------------------- */
typedef struct XcomPortInfo {
  char     name[64];          /* "COM3" */
  char     description[256];  /* friendly name if available */
  uint8_t  busy;              /* 1 = currently open by another handle.
                               * Only ever set when xcom_list_ports_ex is called
                               * with XCOM_LIST_PORTS_PROBE_BUSY; the legacy
                               * xcom_list_ports leaves it 0. */
  uint8_t  _pad[3];
} XcomPortInfo;

/* Flags for xcom_list_ports_ex. */
enum {
  /* Probe each port for exclusive occupancy: CreateFileW with share mode 0 is
   * attempted and the handle immediately closed, without SetCommState /
   * EscapeCommFunction / any I/O, so no DCB is programmed and no DTR/RTS IOCTL
   * is issued. A port that fails with ERROR_ACCESS_DENIED is reported busy.
   * NOTE: a plain open still delivers an open IRP, and a few USB-UART drivers
   * assert DTR on open; leave this flag off on boards with an auto-reset circuit
   * that must not be disturbed during enumeration. */
  XCOM_LIST_PORTS_PROBE_BUSY = 0x1u,
};

/* ---------------------------------------------------------------------------
 * ABI functions
 * ------------------------------------------------------------------------- */

/* Returns (major << 16) | (minor << 8) | patch. */
XCOM_API uint32_t xcom_version(void);

/* Enumerate available serial ports into out[0..capacity). `count` always
 * receives the total discovered. A nullptr `out` with capacity == 0 is a valid
 * size query; insufficient capacity returns XCOM_ERR_FULL without writing past
 * the supplied buffer. */
XCOM_API XcomStatus xcom_list_ports(XcomPortInfo* out, uint32_t capacity,
                                    uint32_t* count);

/* Create the process-wide core instance. Only one XcomHandle may be active at
 * a time; returns nullptr for invalid options, initialization failure, or when
 * another active handle already owns the fixed runtime resources. */
XCOM_API XcomHandle xcom_create(const XcomCreateOptions* options);

/* Open + configure the port. Blocks the caller for at most about 2 s until the
 * open completes or fails. A timeout requests owner-side cancellation; a
 * subsequent xcom_close may return BUSY/TIMEOUT until that cancellation drains.
 * On success the session generation increments and rx counting starts. */
XCOM_API XcomStatus xcom_open(XcomHandle h, const XcomPortConfig* config);

/* v1.3 async open.  Queue the open request without blocking; the SerialAo
 * performs it on the Dispatcher.  Returns XCOM_OK when the request was queued
 * (NOT that the port is open), or an immediate error (XCOM_ERR_PARAM /
 * XCOM_ERR_BUSY / XCOM_ERR_ALREADY_OPEN / XCOM_ERR_FULL) that a caller of the
 * synchronous xcom_open would otherwise have returned before blocking.
 * Poll the result with xcom_take_open_result. */
XCOM_API XcomStatus xcom_open_async(XcomHandle h, const XcomPortConfig* config);

/* v1.3 non-blocking open-result query.  XCOM_OK means the port is OPEN.
 * XCOM_ERR_BUSY means the open is still in progress (poll again). Any other
 * status means the open failed; the detailed error is in the error ring
 * (xcom_take_error), matching the synchronous xcom_open failure contract. */
XCOM_API XcomStatus xcom_take_open_result(XcomHandle h);

/* Graceful close.  timeout_ms bounds the whole drain+close.  Idempotent. */
XCOM_API XcomStatus xcom_close(XcomHandle h, uint32_t timeout_ms);

/* Manual / quick send.  SYNCHRONOUS-COPY semantics (v1.1): the DLL copies
 * data[0:size] verbatim into a unique TxBlockPool slot before returning, OR
 * returns rejected/error.  The caller pointer is never retained.  The client
 * has already pre-encoded the payload (HEX decoded in Lua, optional CRLF
 * applied), so the core does not re-encode or parse HEX.  The function does
 * NOT block for the actual serial WriteResult: it returns as soon as the
 * payload is queued (hence "queue-and-return"); the eventual write success or
 * failure is reported asynchronously via xcom_get_snapshot / xcom_take_error.
 * The caller may freely release/reuse its buffer after return. */
XCOM_API XcomStatus xcom_send(XcomHandle h, const uint8_t* data,
                              uint32_t size, XcomSendFlags flags);

/* Configure receive display options (hex/timestamp/pause/trim).  Applies to
 * subsequent blocks only; never reformats history. */
XCOM_API XcomStatus xcom_set_options(XcomHandle h,
                                     const XcomDisplayOptions* options);

/* v1.4 live modem-line control.  dtr/rts are 1 = asserted (physical pin
 * active), 0 = deasserted; the same sense as XcomPortConfig.dtr_enable /
 * rts_enable.  Applied immediately with EscapeCommFunction on an open port so
 * the pin level is deterministic, unlike the driver-dependent DCB DISABLE
 * value.  Returns XCOM_ERR_NOT_OPEN when no physical session is open, and
 * XCOM_ERR_UNSUPPORTED when RTS/CTS flow control is active (the driver owns
 * RTS and the request is ignored, not fought). */
XCOM_API XcomStatus xcom_set_lines(XcomHandle h, uint8_t dtr, uint8_t rts);

/* Configure auto-send template.  data is the pre-encoded payload (same
 * synchronous-copy / queue-and-return contract as xcom_send; the core copies
 * into a dedicated template TxBlockSlot before returning).  interval_ms==0
 * disables auto-send.  flags uses XCOM_SEND_TEXT (the client encodes HEX/CRLF).
 * A subsequent uncommitted re-configuration replaces the template descriptor
 * atomically on the Dispatcher; coalesced ticks increment
 * auto_tick_coalesced. */
XCOM_API XcomStatus xcom_set_auto_template(XcomHandle h, const uint8_t* data,
                                           uint32_t size, uint32_t interval_ms,
                                           XcomSendFlags flags);

/* Copy up to `capacity` bytes of the next formatted display batch into
 * output.  On success *written is the byte count (0 = none).  The bytes are
 * UTF-8 text: in text view the raw bytes (optionally timestamp-prefixed), in
 * hex view "AA BB CC " sequences.  May be called repeatedly until
 * snapshot.display_pending == 0.  The client polls this with a 10 ms luv
 * timer on its UI thread. */
XCOM_API XcomStatus xcom_drain_display(XcomHandle h, char* output,
                                       uint32_t capacity, uint32_t* written);

/* Cheap non-blocking snapshot for the status bar. */
XCOM_API XcomStatus xcom_get_snapshot(XcomHandle h, XcomSnapshot* output);

/* Pop one error record from the ring; returns XCOM_OK and fills output, or
 * XCOM_ERR_PARAM / no-error (XCOM_OK with code 0). */
XCOM_API XcomStatus xcom_take_error(XcomHandle h, XcomError* output);

/* ---------------------------------------------------------------------------
 * Dedicated file writer
 *
 * All file I/O runs on the core-owned writer thread, never in a coact handler
 * or the UI caller. `append` and `submit_atomic` synchronously
 * copy their input before returning. A full writer queue returns XCOM_ERR_FULL
 * without accepting or dropping bytes; callers retry after draining/errors.
 * ------------------------------------------------------------------------- */

/* Open the ordered receive-log destination. `utf8_path` is borrowed only for
 * this call. `append != 0` preserves existing contents, otherwise truncates.
 * The call waits (at most 2 s) for the dedicated writer to open the file. */
XCOM_API XcomStatus xcom_log_open(XcomHandle h, const char* utf8_path,
                                  uint8_t append);

/* Queue raw bytes after all previous log appends. No caller pointer is kept. */
XCOM_API XcomStatus xcom_log_append(XcomHandle h, const uint8_t* data,
                                    uint32_t size);

/* Drain ordered log appends and FlushFileBuffers on the writer thread. */
XCOM_API XcomStatus xcom_log_flush(XcomHandle h, uint32_t timeout_ms);

/* Drain, flush, and close the log destination on the writer thread. */
XCOM_API XcomStatus xcom_log_close(XcomHandle h, uint32_t timeout_ms);

/* Queue an atomic UTF-8-path replacement for settings/config data. The core
 * writes a temporary sibling, flushes it, then MoveFileEx(REPLACE_EXISTING |
 * WRITE_THROUGH). Completion is polled by request_id; the input is copied. */
XCOM_API XcomStatus xcom_file_submit_atomic(XcomHandle h,
                                            const char* utf8_path,
                                            const uint8_t* data,
                                            uint32_t size,
                                            uint64_t request_id);

/* Queue an atomic replacement without copying `data` into the C++ file pool.
 * `data` is borrowed and MUST remain valid until `xcom_file_take_completion`
 * returns this request_id. This is intended for FFI owners that keep a counted
 * reference to an immutable buffer until completion. Reusing a request_id
 * before its completion is invalid. */
XCOM_API XcomStatus xcom_file_submit_atomic_borrowed(XcomHandle h,
                                                     const char* utf8_path,
                                                     const uint8_t* data,
                                                     uint32_t size,
                                                     uint64_t request_id);

/* Incrementally build an atomic UTF-8-path replacement on the core-owned
 * writer thread. `stream_id` identifies one active replacement. Begin,
 * every append, commit, and abort each publish their own `request_id`
 * completion. `data` in append is borrowed until that append completion is
 * polled. A failed append or commit automatically removes the temporary
 * sibling; abort is idempotent cleanup for a still-active stream. */
XCOM_API XcomStatus xcom_file_stream_begin(XcomHandle h,
                                           const char* utf8_path,
                                           uint64_t stream_id,
                                           uint64_t request_id);
XCOM_API XcomStatus xcom_file_stream_append_borrowed(XcomHandle h,
                                                     uint64_t stream_id,
                                                     const uint8_t* data,
                                                     uint32_t size,
                                                     uint64_t request_id);
XCOM_API XcomStatus xcom_file_stream_commit(XcomHandle h,
                                            uint64_t stream_id,
                                            uint64_t request_id);
XCOM_API XcomStatus xcom_file_stream_abort(XcomHandle h,
                                           uint64_t stream_id,
                                           uint64_t request_id);

/* Pop one completed atomic-write result. An empty completion queue returns
 * XCOM_OK with *request_id == 0 and *status == XCOM_OK. */
XCOM_API XcomStatus xcom_file_take_completion(XcomHandle h,
                                               uint64_t* request_id,
                                               XcomStatus* status);

/* Destroy the handle.  Only valid after CLOSED (xcom_close succeeded or the
 * port never opened); performs a bounded background cleanup otherwise. */
XCOM_API void xcom_destroy(XcomHandle h);

/* ---------------------------------------------------------------------------
 * TEST-ONLY seam (guarded; not a product serial channel)
 * Inject bytes exactly as a native serial-backend read callback would: copies into
 * RxBlockPool and pushes an RxDescriptor through the same ready ring + wake
 * path as real reception.  Enables automated receive-path E2E on machines
 * without serial hardware.  Returns XCOM_ERR_NOT_OPEN when no session. */
XCOM_API XcomStatus xcom_test_inject_rx(XcomHandle h, const uint8_t* data,
                                        uint32_t size);

/* v1.5 TEST-ONLY seam: add classified serial line-error counts exactly as the
 * Win32 read loop's ClearCommError path would, so the accounting and snapshot
 * contract can be regression-tested without serial hardware.  The four values
 * are increments, not totals.  Returns XCOM_ERR_NOT_OPEN when no session is
 * open (line errors only exist on a live receive path). */
XCOM_API XcomStatus xcom_test_inject_line_errors(XcomHandle h, uint32_t framing,
                                                 uint32_t parity, uint32_t overrun,
                                                 uint32_t break_events);

/* NOTE (v1.1 ABI removal): there is deliberately NO exported xcom_wait_display.
 * The client must NOT wait on a Win32 HANDLE.  It polls xcom_drain_display on
 * a 10 ms timer; the DLL keeps its own internal display
 * wake event for the Dispatcher but that event is NOT exported. */

#ifdef __cplusplus
}
#endif

#endif /* XCOM_H_ */
