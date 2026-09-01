// log_writer.hpp - dedicated, ordered Win32 file writer for xcom_core.
#pragma once
#ifndef XCOM_LOG_WRITER_HPP_
#define XCOM_LOG_WRITER_HPP_

#include <cstdint>

#include <xcom/xcom.h>

namespace xcom {

struct CoreCtx;

class LogWriter {
public:
    struct Impl;

    LogWriter() noexcept;
    ~LogWriter();
    LogWriter(const LogWriter&) = delete;
    LogWriter& operator=(const LogWriter&) = delete;

    bool start(CoreCtx* core) noexcept;
    void shutdown(uint32_t timeout_ms) noexcept;

    XcomStatus open(const char* utf8_path, bool append) noexcept;
    XcomStatus append(const uint8_t* data, uint32_t size) noexcept;
    XcomStatus flush(uint32_t timeout_ms) noexcept;
    XcomStatus close(uint32_t timeout_ms) noexcept;

    XcomStatus submit_atomic(const char* utf8_path, const uint8_t* data,
                             uint32_t size, uint64_t request_id) noexcept;
    XcomStatus submit_atomic_borrowed(const char* utf8_path,
                                      const uint8_t* data, uint32_t size,
                                      uint64_t request_id) noexcept;
    XcomStatus stream_begin(const char* utf8_path, uint64_t stream_id,
                            uint64_t request_id) noexcept;
    XcomStatus stream_append_borrowed(std::uint64_t stream_id,
                                      const std::uint8_t* data,
                                      std::uint32_t size,
                                      std::uint64_t request_id) noexcept;
    XcomStatus stream_commit(std::uint64_t stream_id,
                             std::uint64_t request_id) noexcept;
    XcomStatus stream_abort(std::uint64_t stream_id,
                            std::uint64_t request_id) noexcept;
    XcomStatus take_completion(uint64_t& request_id,
                               XcomStatus& status) noexcept;

private:
    // Non-owning observer: Impl storage is owned by Impl::slot(), a fixed
    // process-local placement slot. It is never heap allocated.
    Impl* impl_ = nullptr;
};

}  // namespace xcom

#endif /* XCOM_LOG_WRITER_HPP_ */
