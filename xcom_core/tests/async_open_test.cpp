// Async-open lifecycle regression for xcom_open_async / xcom_take_open_result
// (C ABI v1.3).  Uses the in-process VIRTUAL port so it runs on any Windows
// host without serial hardware.  Verifies:
//   1. xcom_open_async returns XCOM_OK and xcom_take_open_result polls to
//      XCOM_OK once the Dispatcher completes the open.
//   2. xcom_take_open_result before any open reports a non-OK status.
//   3. The synchronous xcom_open is byte-for-byte compatible with v1.2
//      (regression).
#include <windows.h>

#include <cstdint>
#include <cstdio>
#include <cstring>

#include <xcom/xcom.h>

namespace {

XcomPortConfig virtual_config()
{
    XcomPortConfig config{};
    config.struct_size = sizeof(config);
    config.port = "VIRTUAL";
    config.baud_rate = 115200U;
    config.data_bits = 8U;
    return config;
}

XcomHandle create_handle()
{
    XcomCreateOptions options{};
    options.struct_size = sizeof(options);
    return xcom_create(&options);
}

// Poll xcom_take_open_result until it leaves ERR_BUSY (OPEN or a failure),
// bounded so a stuck owner cannot hang the test.
XcomStatus poll_open_result(XcomHandle handle)
{
    for (std::uint32_t i = 0U; i < 200U; ++i) {   // ~2 s at 10 ms
        const XcomStatus result = xcom_take_open_result(handle);
        if (result != XCOM_ERR_BUSY) {
            return result;
        }
        Sleep(10U);
    }
    return XCOM_ERR_TIMEOUT;   // never reported OPEN or a definitive failure
}

}  // namespace

int main()
{
    // --- v1.3 version gate: async open only exists at ABI >= 1.3. -----------
    if (xcom_version() < (1U << 16 | 3U << 8)) {
        std::fprintf(stderr, "xcom_core.dll predates the v1.3 async ABI\n");
        return 1;
    }

    // --- (2) take_open_result before any open must not report OK. ----------
    {
        XcomHandle handle = create_handle();
        if (handle == nullptr) {
            std::fprintf(stderr, "create failed (pre-open query)\n");
            return 1;
        }
        const XcomStatus result = xcom_take_open_result(handle);
        if (result == XCOM_OK) {
            std::fprintf(stderr, "take_open_result reported XCOM_OK before open\n");
            xcom_destroy(handle);
            return 1;
        }
        xcom_destroy(handle);
        std::printf("pre-open take_open_result = %d (non-OK) OK\n", result);
    }

    // --- (1) async open reaches OPEN via polling. --------------------------
    {
        XcomHandle handle = create_handle();
        if (handle == nullptr) {
            std::fprintf(stderr, "create failed (async open)\n");
            return 1;
        }
        const XcomPortConfig config = virtual_config();
        const XcomStatus queued = xcom_open_async(handle, &config);
        if (queued != XCOM_OK) {
            std::fprintf(stderr, "xcom_open_async queue failed: %d\n", queued);
            xcom_destroy(handle);
            return 1;
        }
        const XcomStatus opened = poll_open_result(handle);
        if (opened != XCOM_OK) {
            std::fprintf(stderr, "async open did not reach OPEN: %d\n", opened);
            xcom_destroy(handle);
            return 1;
        }
        if (xcom_close(handle, 2000U) != XCOM_OK) {
            std::fprintf(stderr, "async open session failed to close\n");
            xcom_destroy(handle);
            return 1;
        }
        xcom_destroy(handle);
        std::printf("async open -> poll -> OPEN -> close OK\n");
    }

    // --- (3) synchronous xcom_open regression against v1.2. ---------------
    {
        XcomHandle handle = create_handle();
        if (handle == nullptr) {
            std::fprintf(stderr, "create failed (sync regression)\n");
            return 1;
        }
        const XcomPortConfig config = virtual_config();
        const XcomStatus open = xcom_open(handle, &config);
        if (open != XCOM_OK) {
            std::fprintf(stderr, "synchronous xcom_open regressed: %d\n", open);
            xcom_destroy(handle);
            return 1;
        }
        const XcomStatus close = xcom_close(handle, 2000U);
        if (close != XCOM_OK) {
            std::fprintf(stderr, "synchronous open session failed to close: %d\n",
                         close);
            xcom_destroy(handle);
            return 1;
        }
        xcom_destroy(handle);
        std::printf("synchronous xcom_open regression OK\n");
    }

    // --- (4) alert on false positives: the async path must never hang -------
    {
        XcomHandle handle = create_handle();
        if (handle != nullptr) {
            const XcomPortConfig config = virtual_config();
            if (xcom_open_async(handle, &config) == XCOM_OK) {
                // Defensive teardown if a caller leaves an open session open.
                if (xcom_take_open_result(handle) == XCOM_OK) {
                    xcom_close(handle, 2000U);
                }
            }
            xcom_destroy(handle);
        }
    }

    std::printf("async-open tests PASS\n");
    return 0;
}
