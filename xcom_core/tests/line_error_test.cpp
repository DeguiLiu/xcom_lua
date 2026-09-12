// line_error_test.cpp - hardware-free regression for v1.5 line-error reporting.
//
// A real CE_FRAME/CE_RXPARITY/CE_RXOVER/CE_BREAK only appears with a physical
// adapter and a deliberately damaged line, so the classification in the Win32
// read loop cannot be exercised here.  What IS verifiable without hardware is
// the contract the read loop depends on:
//   1. version + struct layout of the appended XcomSnapshot fields;
//   2. xcom_get_snapshot returns those counters (zero on a clean virtual session);
//   3. the same ingress path used by the read callback accumulates each category;
//   4. counts are monotonic and survive close/reopen (the metrics are
//      process-lifetime, like rx_bytes/tx_bytes — not per-session);
//   5. the seam refuses injection when no session is open.
//
// SPDX-License-Identifier: MIT
#include <windows.h>

#include <cstddef>
#include <cstdio>

#include <xcom/xcom.h>

static int g_failures = 0;

#define CHECK(cond, msg)                                               \
    do {                                                               \
        if (!(cond)) {                                                 \
            std::fprintf(stderr, "FAIL: %s (%s:%d)\n", msg, __FILE__, \
                         __LINE__);                                    \
            ++g_failures;                                              \
        }                                                              \
        else {                                                         \
            std::printf("ok: %s\n", msg);                               \
        }                                                              \
        std::fflush(stdout);                                           \
    } while (0)

static XcomHandle create_handle()
{
    XcomCreateOptions options{};
    options.struct_size = sizeof(options);
    return xcom_create(&options);
}

static XcomPortConfig virtual_config()
{
    XcomPortConfig config{};
    config.struct_size = sizeof(config);
    config.port = "VIRTUAL";
    config.baud_rate = 115200U;
    config.data_bits = 8U;
    return config;
}

// Fetch the snapshot or fail the run outright (a broken snapshot ABI makes the
// remaining assertions meaningless).
static XcomSnapshot snapshot(XcomHandle handle)
{
    XcomSnapshot snap{};
    snap.struct_size = sizeof(snap);
    if (xcom_get_snapshot(handle, &snap) != XCOM_OK) {
        std::fprintf(stderr, "FATAL: xcom_get_snapshot failed\n");
        ++g_failures;
    }
    return snap;
}

int main()
{
    // (1) version + appended-field layout. The fields must sit AFTER every
    // v1.0..v1.4 field so old offsets are unchanged; the pre-v1.5 struct was
    // 52 bytes. v1.5 also appends the loss-observability counters at 68..79.
    CHECK(xcom_version() == 0x010500U, "version is 1.5.0");
    CHECK(sizeof(XcomSnapshot) == 80U, "snapshot grew by 12 bytes");
    CHECK(offsetof(XcomSnapshot, port_state) == 48U,
          "port_state offset unchanged");
    CHECK(offsetof(XcomSnapshot, framing_errors) == 52U,
          "framing_errors appended at 52");
    CHECK(offsetof(XcomSnapshot, parity_errors) == 56U,
          "parity_errors at 56");
    CHECK(offsetof(XcomSnapshot, overrun_errors) == 60U,
          "overrun_errors at 60");
    CHECK(offsetof(XcomSnapshot, break_events) == 64U,
          "break_events at 64");
    CHECK(offsetof(XcomSnapshot, rx_sequence) == 68U,
          "rx_sequence appended at 68");
    CHECK(offsetof(XcomSnapshot, rx_loss_offset) == 72U,
          "rx_loss_offset at 72");
    CHECK(offsetof(XcomSnapshot, rx_backpressure_events) == 76U,
          "rx_backpressure_events at 76");

    XcomHandle handle = create_handle();
    if (handle == nullptr) {
        std::fprintf(stderr, "xcom_create failed\n");
        return 1;
    }

    // (2) a closed session reports zeros and the seam refuses.
    {
        const XcomSnapshot snap = snapshot(handle);
        CHECK(snap.framing_errors == 0U && snap.parity_errors == 0U &&
                  snap.overrun_errors == 0U && snap.break_events == 0U,
              "clean snapshot has zero line errors");
        CHECK(xcom_test_inject_line_errors(handle, 1U, 0U, 0U, 0U) ==
                  XCOM_ERR_NOT_OPEN,
              "inject before open is NOT_OPEN");
        CHECK(xcom_test_inject_line_errors(nullptr, 1U, 0U, 0U, 0U) ==
                  XCOM_ERR_PARAM,
              "inject(null) is PARAM");
    }

    const XcomPortConfig config = virtual_config();
    CHECK(xcom_open(handle, &config) == XCOM_OK, "virtual open");

    // (3) a clean session still reports zeros (no false positives).
    {
        const XcomSnapshot snap = snapshot(handle);
        CHECK(snap.framing_errors == 0U && snap.parity_errors == 0U &&
                  snap.overrun_errors == 0U && snap.break_events == 0U,
              "virtual session reports no line errors");
    }

    // (4) each category lands in its own counter.
    CHECK(xcom_test_inject_line_errors(handle, 1U, 0U, 0U, 0U) == XCOM_OK,
          "inject one framing error");
    CHECK(xcom_test_inject_line_errors(handle, 0U, 2U, 0U, 0U) == XCOM_OK,
          "inject two parity errors");
    CHECK(xcom_test_inject_line_errors(handle, 0U, 0U, 3U, 0U) == XCOM_OK,
          "inject three overrun errors");
    CHECK(xcom_test_inject_line_errors(handle, 0U, 0U, 0U, 4U) == XCOM_OK,
          "inject four break events");
    {
        const XcomSnapshot snap = snapshot(handle);
        CHECK(snap.framing_errors == 1U, "framing counted");
        CHECK(snap.parity_errors == 2U, "parity counted");
        CHECK(snap.overrun_errors == 3U, "overrun counted");
        CHECK(snap.break_events == 4U, "break counted");
    }

    // (5) monotonic accumulation across further injections.
    CHECK(xcom_test_inject_line_errors(handle, 1U, 1U, 1U, 1U) == XCOM_OK,
          "inject one of each again");
    {
        const XcomSnapshot snap = snapshot(handle);
        CHECK(snap.framing_errors == 2U && snap.parity_errors == 3U &&
                  snap.overrun_errors == 4U && snap.break_events == 5U,
              "counters accumulate monotonically");
    }

    // (6) metrics are process-lifetime (like rx_bytes), so a close/reopen keeps
    // the totals; this documents the reset-free semantics the UI relies on.
    CHECK(xcom_close(handle, 2000U) == XCOM_OK, "virtual close");
    CHECK(xcom_open(handle, &config) == XCOM_OK, "virtual reopen");
    {
        const XcomSnapshot snap = snapshot(handle);
        CHECK(snap.framing_errors == 2U && snap.parity_errors == 3U &&
                  snap.overrun_errors == 4U && snap.break_events == 5U,
              "line-error totals survive close/reopen");
    }
    CHECK(xcom_close(handle, 2000U) == XCOM_OK, "final close");

    xcom_destroy(handle);
    if (g_failures != 0) {
        std::fprintf(stderr, "line-error tests FAILED (%d)\n", g_failures);
        return 1;
    }
    std::printf("line-error tests PASS\n");
    return 0;
}
