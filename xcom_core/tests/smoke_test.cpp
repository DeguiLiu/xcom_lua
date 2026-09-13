// smoke_test.cpp - xcom_core DLL smoke test (no serial hardware required).
//
// Flow: xcom_create -> xcom_list_ports -> xcom_open("VIRTUAL") ->
// xcom_test_inject_rx -> xcom_wait_display / xcom_drain_display (assert the
// batch round-trips) -> xcom_get_snapshot (assert rx_bytes / display_pending)
// -> xcom_close -> xcom_destroy.
//
// Returns 0 on success, non-zero (and a message on stderr) on failure.
//
// SPDX-License-Identifier: MIT
#include <windows.h>

#include <array>
#include <cstdio>
#include <cstring>
#include <string>

#include <xcom/xcom.h>

#include "foundation/fixed_vector.hpp"

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

int main()
{
    XcomHandle h;

    XcomCreateOptions copts;
    std::memset(&copts, 0, sizeof(copts));
    copts.struct_size = sizeof(copts);
    h = xcom_create(&copts);
    CHECK(h != nullptr, "xcom_create");
    if (h == nullptr) {
        return 1;
    }
    CHECK(xcom_create(&copts) == nullptr,
          "xcom_create enforces the process-wide single handle");

    // Enumerate ports (may be zero on machines without hardware; must not
    // fail the call).
    uint32_t required_count = 0U;
    const XcomStatus count_query = xcom_list_ports(nullptr, 0U, &required_count);
    CHECK(count_query == XCOM_OK || count_query == XCOM_ERR_FULL,
          "xcom_list_ports supports a size query");
    std::array<XcomPortInfo, 32U> ports{};
    uint32_t count = 0;
    const XcomStatus lp = xcom_list_ports(
        ports.data(), static_cast<uint32_t>(ports.size()), &count);
    CHECK(lp == XCOM_OK || lp == XCOM_ERR_FULL, "xcom_list_ports");
    std::printf("  enumerated %u port(s)\n", count);

    // Version sanity.
    const uint32_t ver = xcom_version();
    CHECK((ver >> 16U) == XCOM_VERSION_MAJOR, "xcom_version major");

    // Open the virtual (no-hardware) test session.
    XcomPortConfig cfg;
    std::memset(&cfg, 0, sizeof(cfg));
    cfg.struct_size = sizeof(cfg);
    cfg.port = "VIRTUAL";
    cfg.baud_rate = 115200;
    cfg.data_bits = 8;
    cfg.stop_bits = 0;
    cfg.parity = 0;
    cfg.flow_control = 0;
    cfg.dtr_enable = 0;
    cfg.rts_enable = 0;
    CHECK(xcom_open(h, &cfg) == XCOM_OK, "xcom_open(VIRTUAL)");

    const char* tx_first = "ABC";
    const char* tx_second = "12345";
    CHECK(xcom_send(h, reinterpret_cast<const uint8_t*>(tx_first),
                    static_cast<uint32_t>(std::strlen(tx_first)),
                    XCOM_SEND_TEXT) == XCOM_OK,
          "first xcom_send queues independently");
    CHECK(xcom_send(h, reinterpret_cast<const uint8_t*>(tx_second),
                    static_cast<uint32_t>(std::strlen(tx_second)),
                    XCOM_SEND_TEXT) == XCOM_OK,
          "second xcom_send queues independently");

    const uint32_t expected_tx = static_cast<uint32_t>(
        std::strlen(tx_first) + std::strlen(tx_second));
    XcomSnapshot tx_snapshot;
    std::memset(&tx_snapshot, 0, sizeof(tx_snapshot));
    tx_snapshot.struct_size = sizeof(tx_snapshot);
    XcomStatus tx_status = XCOM_OK;
    for (int i = 0; i < 400; ++i) {
        tx_status = xcom_get_snapshot(h, &tx_snapshot);
        if (tx_status != XCOM_OK) {
            break;
        }
        if (tx_snapshot.tx_bytes == expected_tx) {
            break;
        }
        Sleep(5);
    }
    CHECK(tx_status == XCOM_OK, "xcom_get_snapshot for queued sends");
    CHECK(tx_snapshot.tx_bytes == expected_tx,
          "queued sends preserve distinct descriptor lengths");

    std::array<char, MAX_PATH> temp_dir{};
    CHECK(GetTempPathA(static_cast<DWORD>(temp_dir.size()), temp_dir.data()) !=
              0U,
          "GetTempPathA");
    const std::string log_path =
        std::string(temp_dir.data()) + "xcom_smoke_log.bin";
    const std::string settings_path =
        std::string(temp_dir.data()) + "xcom_smoke_settings.toml";
    const std::string stream_path =
        std::string(temp_dir.data()) + "xcom_smoke_stream.log";
    DeleteFileA(log_path.c_str());
    DeleteFileA(settings_path.c_str());
    DeleteFileA(stream_path.c_str());
    const char* log_bytes = "ordered-log";
    CHECK(xcom_log_open(h, log_path.c_str(), 0U) == XCOM_OK,
          "xcom_log_open dedicated writer");
    CHECK(xcom_log_append(h, reinterpret_cast<const uint8_t*>(log_bytes),
                          static_cast<uint32_t>(std::strlen(log_bytes))) == XCOM_OK,
          "xcom_log_append queues copied bytes");
    CHECK(xcom_log_flush(h, 2000U) == XCOM_OK, "xcom_log_flush drains writer");
    CHECK(xcom_log_close(h, 2000U) == XCOM_OK, "xcom_log_close drains writer");

    const char* settings_bytes = "theme = 'siemens-blue'\n";
    CHECK(xcom_file_submit_atomic(
              h, settings_path.c_str(),
              reinterpret_cast<const uint8_t*>(settings_bytes),
              static_cast<uint32_t>(std::strlen(settings_bytes)), 77U) == XCOM_OK,
          "xcom_file_submit_atomic queues copied settings");
    uint64_t completed_id = 0U;
    XcomStatus completed_status = XCOM_OK;
    for (int i = 0; i < 400 && completed_id == 0U; ++i) {
        CHECK(xcom_file_take_completion(h, &completed_id, &completed_status) ==
                  XCOM_OK,
              "xcom_file_take_completion");
        if (completed_id == 0U) {
            Sleep(5U);
        }
    }
    CHECK(completed_id == 77U && completed_status == XCOM_OK,
          "atomic settings completion reports success");

    const auto wait_file_completion = [h](uint64_t expected_id) {
        uint64_t request_id = 0U;
        XcomStatus status = XCOM_OK;
        for (int i = 0; i < 400 && request_id == 0U; ++i) {
            if (xcom_file_take_completion(h, &request_id, &status) != XCOM_OK) {
                return false;
            }
            if (request_id == 0U) {
                Sleep(5U);
            }
        }
        return request_id == expected_id && status == XCOM_OK;
    };
    constexpr uint64_t kStreamId = 88U;
    CHECK(xcom_file_stream_begin(h, stream_path.c_str(), kStreamId, 81U) ==
              XCOM_OK,
          "xcom_file_stream_begin queues temporary replacement");
    CHECK(wait_file_completion(81U), "stream begin completion reports success");
    const char* stream_first = "first ";
    const char* stream_second = "second";
    CHECK(xcom_file_stream_append_borrowed(
              h, kStreamId, reinterpret_cast<const uint8_t*>(stream_first),
              static_cast<uint32_t>(std::strlen(stream_first)), 82U) == XCOM_OK,
          "xcom_file_stream_append_borrowed first chunk");
    CHECK(wait_file_completion(82U), "stream first append completion");
    CHECK(xcom_file_stream_append_borrowed(
              h, kStreamId, reinterpret_cast<const uint8_t*>(stream_second),
              static_cast<uint32_t>(std::strlen(stream_second)), 83U) == XCOM_OK,
          "xcom_file_stream_append_borrowed second chunk");
    CHECK(wait_file_completion(83U), "stream second append completion");
    CHECK(xcom_file_stream_commit(h, kStreamId, 84U) == XCOM_OK,
          "xcom_file_stream_commit queues replacement");
    CHECK(wait_file_completion(84U), "stream commit completion reports success");
    CHECK(xcom_file_stream_abort(h, kStreamId, 85U) == XCOM_OK,
          "completed stream abort is idempotent");
    CHECK(wait_file_completion(85U),
          "idempotent stream abort completion reports success");
    HANDLE stream_file = CreateFileA(stream_path.c_str(), GENERIC_READ,
                                     FILE_SHARE_READ, nullptr, OPEN_EXISTING,
                                     FILE_ATTRIBUTE_NORMAL, nullptr);
    std::array<char, 32> stream_contents{};
    unsigned long stream_read = 0U;
    CHECK(stream_file != INVALID_HANDLE_VALUE &&
              ReadFile(stream_file, stream_contents.data(),
                       static_cast<unsigned long>(stream_contents.size()),
                       &stream_read, nullptr) &&
              std::string(stream_contents.data(), stream_read) == "first second",
          "streamed replacement preserves ordered UTF-8 bytes");
    if (stream_file != INVALID_HANDLE_VALUE) {
        CloseHandle(stream_file);
    }
    DeleteFileA(log_path.c_str());
    DeleteFileA(settings_path.c_str());
    DeleteFileA(stream_path.c_str());

    // Inject test bytes through the real receive pipeline (P0 wake bridge).
    const char* text = "Hello, XCOM!";
    CHECK(xcom_test_inject_rx(h, reinterpret_cast<const uint8_t*>(text),
                              static_cast<uint32_t>(std::strlen(text))) ==
              XCOM_OK,
          "xcom_test_inject_rx");

    // Wait for + drain the formatted display batch via the v1.1 poll contract
    // (no exported xcom_wait_display; the client polls xcom_drain_display).
    // xcom_drain_display supports a prefix when the caller buffer is smaller;
    // this buffer uses the full maximum batch size for the smoke assertion.
    constexpr uint32_t kDrainBufBytes = 65536U;
    std::array<char, kDrainBufBytes> buf{};
    uint32_t written = 0;
    bool drained = false;
    for (int i = 0; i < 400 && !drained; ++i) {   // bounded ~2 s poll
        const XcomStatus dd = xcom_drain_display(
            h, buf.data(), static_cast<uint32_t>(buf.size()), &written);
        if (dd == XCOM_OK && written > 0U) {
            drained = true;
            break;
        }
        Sleep(5);
    }
    CHECK(drained, "drain got a batch");
    if (drained) {
        std::printf("  drained %u bytes: '%.*s'\n", written,
                    static_cast<int>(written), buf.data());
        CHECK(written == std::strlen(text), "drain length matches injected");
        CHECK(std::strncmp(buf.data(), text, std::strlen(text)) == 0,
              "drain content matches injected");
    }

    // Snapshot: rx_bytes should reflect the injected payload; display_pending
    // should be 0 after a successful drain.
    XcomSnapshot snap;
    std::memset(&snap, 0, sizeof(snap));
    snap.struct_size = sizeof(snap);
    CHECK(xcom_get_snapshot(h, &snap) == XCOM_OK, "xcom_get_snapshot");
    std::printf("  snapshot: rx_bytes=%u tx_bytes=%u port_state=%u gen=%u "
                "display_pending=%u\n",
                snap.rx_bytes, snap.tx_bytes, snap.port_state, snap.generation,
                snap.display_pending);
    CHECK(snap.rx_bytes == static_cast<uint32_t>(std::strlen(text)),
          "snapshot rx_bytes");
    CHECK(snap.display_pending == 0U, "snapshot display_pending after drain");

    XcomDisplayOptions paused_options{};
    paused_options.struct_size = sizeof(paused_options);
    paused_options.pause_display = 1U;
    CHECK(xcom_set_options(h, &paused_options) == XCOM_OK,
          "pause display retains receive blocks");
    const char* paused_text = "retained-while-paused";
    CHECK(xcom_test_inject_rx(h,
                              reinterpret_cast<const uint8_t*>(paused_text),
                              static_cast<uint32_t>(std::strlen(paused_text))) ==
              XCOM_OK,
          "inject while display paused");
    Sleep(20U);
    written = 0U;
    CHECK(xcom_drain_display(h, buf.data(), static_cast<uint32_t>(buf.size()),
                             &written) == XCOM_OK &&
              written == 0U,
          "paused display does not consume retained bytes");
    CHECK(xcom_get_snapshot(h, &snap) == XCOM_OK &&
              snap.display_paused_bytes >= std::strlen(paused_text),
          "paused bytes are observable, not discarded");

    paused_options.pause_display = 0U;
    CHECK(xcom_set_options(h, &paused_options) == XCOM_OK,
          "resume display re-arms retained RxKick");
    drained = false;
    for (int i = 0; i < 400 && !drained; ++i) {
        written = 0U;
        const XcomStatus dd = xcom_drain_display(
            h, buf.data(), static_cast<uint32_t>(buf.size()), &written);
        if (dd == XCOM_OK && written > 0U) {
            drained = true;
            break;
        }
        Sleep(5U);
    }
    CHECK(drained && written == std::strlen(paused_text) &&
               std::strncmp(buf.data(), paused_text, written) == 0,
          "resume display drains every retained byte in order");

    constexpr uint32_t kTestRxBlockBytes = 4096U;
    xcom::foundation::FixedVector<uint8_t, kTestRxBlockBytes * 5U>
        multi_block;
    bool fixed_buffer_complete = true;
    for (uint32_t index = 0U; index < multi_block.capacity(); ++index) {
        fixed_buffer_complete = multi_block.try_push_back(
            static_cast<uint8_t>('R')) && fixed_buffer_complete;
    }
    CHECK(fixed_buffer_complete, "fixed test buffer capacity");
    CHECK(xcom_test_inject_rx(h, multi_block.data(),
                              static_cast<uint32_t>(multi_block.size())) == XCOM_OK,
          "five-block inject queues one static RxKick");

    uint32_t multi_block_drained = 0U;
    for (int i = 0; i < 400 && multi_block_drained < multi_block.size(); ++i) {
        written = 0U;
        const XcomStatus dd = xcom_drain_display(
            h, buf.data(), static_cast<uint32_t>(buf.size()), &written);
        if (dd != XCOM_OK) {
            break;
        }
        multi_block_drained += written;
        if (written == 0U) {
            Sleep(5);
        }
    }
    CHECK(multi_block_drained == multi_block.size(),
          "RxKick requeues static event after four-block drain");
    CHECK(xcom_get_snapshot(h, &snap) == XCOM_OK,
          "xcom_get_snapshot after static RxKick requeue");
    CHECK(snap.rx_bytes == std::strlen(text) + std::strlen(paused_text) +
              multi_block.size(),
          "static RxKick requeue preserves every receive byte");
    CHECK(snap.display_pending == 0U,
          "static RxKick requeue leaves display lane drained");

    // F3 regression: a timed-out close must not leave port_state stuck in
    // CLOSING. After the timeout the state rolls back (OPEN here) so a retry
    // close succeeds and a subsequent reopen is not blocked with BUSY.
    CHECK(xcom_close(h, 0U) == XCOM_ERR_TIMEOUT, "close(h,0) returns timeout");
    CHECK(xcom_close(h, 1000U) == XCOM_OK, "retry close succeeds (not stuck)");
    CHECK(xcom_open(h, &cfg) == XCOM_OK, "reopen after close-timeout succeeds");
    CHECK(xcom_close(h, 1000U) == XCOM_OK, "final close after F3 regression");

    // Close (idempotent) and destroy.
    CHECK(xcom_close(h, 1000U) == XCOM_OK, "xcom_close");
    CHECK(xcom_close(h, 1000U) == XCOM_OK, "xcom_close idempotent");
    xcom_destroy(h);
    std::printf("xcom_destroy ok\n");

    // Opaque ABI handles must be rejected by address comparison rather than
    // dereferenced while validating an arbitrary caller-provided pointer.
    const XcomHandle invalid_handle = reinterpret_cast<XcomHandle>(
        static_cast<uintptr_t>(1U));
    CHECK(xcom_close(invalid_handle, 0U) == XCOM_ERR_PARAM,
          "invalid opaque handle is rejected without dereference");
    xcom_destroy(invalid_handle);

    if (g_failures == 0) {
        std::printf("SMOKE TEST PASSED\n");
        return 0;
    }
    std::fprintf(stderr, "SMOKE TEST FAILED (%d failures)\n", g_failures);
    return 1;
}
