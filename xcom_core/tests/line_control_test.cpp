// line_control_test.cpp - hardware-free regression for xcom_set_lines (v1.4).
//
// The physical pin behaviour needs a real USB-UART adapter, but the ABI
// contract is exercisable on the reserved VIRTUAL port:
//   1. xcom_set_lines before open            -> XCOM_ERR_NOT_OPEN
//   2. xcom_set_lines(null, ...)             -> XCOM_ERR_PARAM
//   3. open VIRTUAL, set DTR/RTS             -> XCOM_ERR_NOT_OPEN (the virtual
//      session owns no physical pin, reported honestly)
//   4. RTS assert while flow_control == 1    -> XCOM_ERR_UNSUPPORTED
//      (checked before the pin dispatch, so it is deterministic)
//   5. xcom_set_lines after close            -> XCOM_ERR_NOT_OPEN
//
// SPDX-License-Identifier: MIT
#include <windows.h>

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
    XcomHandle handle = create_handle();
    if (handle == nullptr) {
        std::fprintf(stderr, "xcom_create failed\n");
        return 1;
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
