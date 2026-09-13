// line_control_test.cpp - hardware-free regression for xcom_set_lines (v1.4).
//
// The physical pin behaviour needs a real USB-UART adapter, but the ABI
// contract is exercisable on the reserved VIRTUAL port:
//   1. xcom_set_lines before open            -> XCOM_ERR_NOT_OPEN
//   2. xcom_set_lines(null, ...)             -> XCOM_ERR_PARAM
//   3. open VIRTUAL, set DTR/RTS             -> XCOM_ERR_NOT_OPEN (the virtual
//      session owns no physical pin, reported honestly)
//   4. RTS assert while flow_control == 1    -> XCOM_ERR_UNSUPPORTED
//      (decided from the flow-control config, so it is deterministic; DTR is
//      still driven first, so UNSUPPORTED there means "DTR applied, RTS not")
//   4b. RTS DEASSERT while flow_control == 1 -> XCOM_ERR_UNSUPPORTED too; the
//      old code only refused rts=1, so rts=0 fell through and reported OK for a
//      pin the driver owns and never moved (a false success)
//   4c. DTR change while flow_control == 1   -> XCOM_ERR_UNSUPPORTED (the RTS
//      half cannot be honoured, so the call must not claim success even though
//      DTR itself was driven)
//   5. xcom_set_lines after close            -> XCOM_ERR_NOT_OPEN
//
// It also pins the v1.6 ABI layout (appended fields only; old offsets fixed)
// so a struct change that forgot xcom_ffi.lua's SIZEOF pins or the version bump
// is caught here at compile/runtime on the Windows host:
//   * XcomPortInfo: 324 -> 420, hardware_id at offset 324 (busy/pad unchanged)
//   * XcomSnapshot: 80 -> 84, flow_hold_events at offset 80
//   * xcom_version() reports 1.6.0
//
// SPDX-License-Identifier: MIT
#include <windows.h>

#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <cstring>

#include <xcom/xcom.h>

#include "serial_backend_win.hpp"   // copy_first_multi_sz (header-inline)

// Compile-time pins. A mismatch is a compiler error even under -fsyntax-only.
static_assert(sizeof(XcomPortInfo) == 420U,
              "XcomPortInfo must be 420 bytes in v1.6 (append hardware_id[96])");
static_assert(offsetof(XcomPortInfo, hardware_id) == 324U,
              "hardware_id must be appended at offset 324");
static_assert(sizeof(((XcomPortInfo*)0)->hardware_id) == 96U,
              "hardware_id must be char[96]");
static_assert(offsetof(XcomPortInfo, name) == 0U, "name offset moved");
static_assert(offsetof(XcomPortInfo, description) == 64U,
              "description offset moved");
static_assert(offsetof(XcomPortInfo, busy) == 320U, "busy offset moved");
static_assert(sizeof(XcomSnapshot) == 84U,
              "XcomSnapshot must be 84 bytes in v1.6 (append flow_hold_events)");
static_assert(offsetof(XcomSnapshot, flow_hold_events) == 80U,
              "flow_hold_events must be appended at offset 80");
static_assert(offsetof(XcomSnapshot, rx_backpressure_events) == 76U,
              "v1.5 counter offsets moved");

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

static XcomPortConfig virtual_config(uint8_t flow_control)
{
    XcomPortConfig config{};
    config.struct_size = sizeof(config);
    config.port = "VIRTUAL";
    config.baud_rate = 115200U;
    config.data_bits = 8U;
    config.flow_control = flow_control;
    return config;
}

int main()
{
    // v1.6 ABI identity. A forgotten version bump or a stale DLL is a hard fail.
    CHECK(xcom_version() == ((1U << 16U) | (6U << 8U) | 0U),
          "xcom_version reports 1.6.0");

    // v1.6 hardware_id parse: SPDRP_HARDWAREID is a REG_MULTI_SZ and the FIRST
    // string is the stable id. copy_first_multi_sz is pure, so this is hardware-
    // free; SetupAPI reading the property is not (see the report's limits).
    {
        const char first[] = "USB\\VID_1A86&PID_7523&REV_0254";
        const char second[] = "USB\\VID_1A86&PID_7523";
        std::uint8_t multi_sz[128] = {};
        std::memcpy(multi_sz, first, sizeof(first));   // includes its NUL
        std::memcpy(multi_sz + sizeof(first), second, sizeof(second));

        char out[96] = {};
        xcom::copy_first_multi_sz(multi_sz,
                                  static_cast<std::uint32_t>(sizeof(multi_sz)),
                                  out, sizeof(out));
        CHECK(std::strcmp(out, "USB\\VID_1A86&PID_7523&REV_0254") == 0,
              "hardware_id takes the first MULTI_SZ string");

        // Missing property (all-zero buffer) must degrade to empty, not garbage.
        std::uint8_t empty[8] = {};
        char empty_out[96] = { 'x' };
        xcom::copy_first_multi_sz(empty, static_cast<std::uint32_t>(sizeof(empty)),
                                  empty_out, sizeof(empty_out));
        CHECK(empty_out[0] == '\0', "absent hardware_id parses as empty");

        // Bounded: a small destination is truncated and NUL-terminated.
        char small[8] = {};
        xcom::copy_first_multi_sz(multi_sz,
                                  static_cast<std::uint32_t>(sizeof(multi_sz)),
                                  small, sizeof(small));
        CHECK(std::strcmp(small, "USB\\VID") == 0,
              "hardware_id truncation stays NUL-terminated");
        xcom::copy_first_multi_sz(nullptr, 0U, small, sizeof(small));
        CHECK(small[0] == '\0', "null property parses safely to empty");
    }

    XcomHandle handle = create_handle();
    if (handle == nullptr) {
        std::fprintf(stderr, "xcom_create failed\n");
        return 1;
    }

    // v1.6 snapshot: flow_hold_events exists, is exported, and starts at 0.
    {
        XcomSnapshot snapshot{};
        snapshot.struct_size = sizeof(snapshot);
        CHECK(xcom_get_snapshot(handle, &snapshot) == XCOM_OK,
              "get_snapshot before open is OK");
        CHECK(snapshot.struct_size == sizeof(XcomSnapshot),
              "snapshot struct_size reports v1.6 size");
        CHECK(snapshot.flow_hold_events == 0U,
              "flow_hold_events starts at 0");
    }

    // (1) closed session rejects line changes.
    CHECK(xcom_set_lines(handle, 1U, 0U) == XCOM_ERR_NOT_OPEN,
          "set_lines before open is NOT_OPEN");

    // (2) null handle is a parameter error.
    CHECK(xcom_set_lines(nullptr, 1U, 0U) == XCOM_ERR_PARAM,
          "set_lines(null) is PARAM");

    // (3) the virtual session owns no physical pin, so the call is refused
    // with NOT_OPEN rather than silently succeeding.
    {
        XcomPortConfig config = virtual_config(0U);
        CHECK(xcom_open(handle, &config) == XCOM_OK, "virtual open");
        CHECK(xcom_set_lines(handle, 1U, 0U) == XCOM_ERR_NOT_OPEN,
              "set_lines on virtual session is NOT_OPEN");
        CHECK(xcom_close(handle, 2000U) == XCOM_OK, "virtual close");
    }

    // (4) RTS assert under RTS/CTS flow control is refused, not fought.
    {
        XcomPortConfig config = virtual_config(1U);
        CHECK(xcom_open(handle, &config) == XCOM_OK,
              "virtual open with RTS/CTS");
        CHECK(xcom_set_lines(handle, 0U, 1U) == XCOM_ERR_UNSUPPORTED,
              "RTS assert under flow control is UNSUPPORTED");
        // (4b) Deassert is refused symmetrically. This is the rts=0 hole: the
        // driver owns RTS, so neither level can be applied and neither may be
        // reported as success.
        CHECK(xcom_set_lines(handle, 0U, 0U) == XCOM_ERR_UNSUPPORTED,
              "RTS deassert under flow control is UNSUPPORTED, not OK");
        // (4c) A DTR change rides in the same call. DTR is not flow-controlled,
        // but the overall call still carries an unapplied RTS half, so it must
        // not be reported as success.
        CHECK(xcom_set_lines(handle, 1U, 0U) == XCOM_ERR_UNSUPPORTED,
              "DTR change with RTS under flow control is UNSUPPORTED");
        CHECK(xcom_close(handle, 2000U) == XCOM_OK,
              "virtual close after flow-control case");
    }

    // (5) closed session rejects line changes again.
    CHECK(xcom_set_lines(handle, 1U, 1U) == XCOM_ERR_NOT_OPEN,
          "set_lines after close is NOT_OPEN");

    xcom_destroy(handle);
    if (g_failures != 0) {
        std::fprintf(stderr, "line-control tests FAILED (%d)\n", g_failures);
        return 1;
    }
    std::printf("line-control tests PASS\n");
    return 0;
}
