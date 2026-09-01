// SessionWriter lifecycle regression: VIRTUAL opens start the write thread.
#include <windows.h>

#include <cstdint>
#include <cstdio>
#include <cstring>

#include <xcom/xcom.h>

namespace {

std::uint32_t handle_count()
{
    DWORD count = 0U;
    return GetProcessHandleCount(GetCurrentProcess(), &count) ? count : 0U;
}

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

}  // namespace

int main()
{
    constexpr std::uint32_t kWarmupCycles = 64U;
    constexpr std::uint32_t kMeasuredCycles = 64U;
    const std::uint32_t baseline_before = handle_count();

    // Establish the cost of the CoreState runtime itself.
    for (std::uint32_t cycle = 0U; cycle < kWarmupCycles; ++cycle) {
        XcomHandle handle = create_handle();
        if (handle == nullptr) {
            std::fprintf(stderr, "create-only failed at %d\n", cycle);
            return 1;
        }
        xcom_destroy(handle);
    }
    const std::uint32_t baseline_after = handle_count();
    std::printf("baseline handle counts: %u -> %u\n", baseline_before,
                baseline_after);

    const XcomPortConfig config = virtual_config();
    for (std::uint32_t cycle = 0U; cycle < kWarmupCycles; ++cycle) {
        XcomHandle handle = create_handle();
        const XcomStatus open = handle != nullptr
                                    ? xcom_open(handle, &config)
                                    : XCOM_ERR_IO;
        const XcomStatus close = (handle != nullptr && open == XCOM_OK)
                                     ? xcom_close(handle, 2000U)
                                     : XCOM_ERR_IO;
        if (handle == nullptr || open != XCOM_OK || close != XCOM_OK) {
            std::fprintf(stderr,
                         "VIRTUAL lifecycle failed at %d: handle=%p open=%d close=%d handles=%u\n",
                         static_cast<unsigned>(cycle), handle, open, close,
                         handle_count());
            if (handle != nullptr) {
                xcom_destroy(handle);
            }
            return 1;
        }
        xcom_destroy(handle);
    }
    const std::uint32_t session_baseline = handle_count();

    for (std::uint32_t cycle = 0U; cycle < kMeasuredCycles; ++cycle) {
        XcomHandle handle = create_handle();
        const XcomStatus open = handle != nullptr
                                    ? xcom_open(handle, &config)
                                    : XCOM_ERR_IO;
        const XcomStatus close = (handle != nullptr && open == XCOM_OK)
                                     ? xcom_close(handle, 2000U)
                                     : XCOM_ERR_IO;
        if (handle == nullptr || open != XCOM_OK || close != XCOM_OK) {
            std::fprintf(stderr,
                         "measured lifecycle failed at %u: handle=%p open=%d close=%d\n",
                         static_cast<unsigned>(cycle), handle, open, close);
            if (handle != nullptr) {
                xcom_destroy(handle);
            }
            return 1;
        }
        xcom_destroy(handle);
    }
    const std::uint32_t sessions_after = handle_count();
    std::printf("handle counts: base %u -> %u, warm %u -> measured %u\n",
                baseline_before, baseline_after, session_baseline,
                sessions_after);
    if (sessions_after > session_baseline + 2U) {
        std::fprintf(stderr, "session handle count grew after warmup: %u -> %u\n",
                     session_baseline, sessions_after);
        return 1;
    }
    return 0;
}
