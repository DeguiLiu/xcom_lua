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

    // True while a log file is open and the writer's thread accepts raw RX
    // references. The serial read thread reads this (relaxed) to decide whether
    // to hand its ref-counted RX block to the file lane.
    [[nodiscard]] bool accepting() const noexcept;
    // Raw-RX producer admission. The serial read thread takes a lease before it
    // hands a block to the file lane and releases it once the block is on the
    // raw ring. close() closes admission and waits for every in-flight lease to
    // drain BEFORE it flushes the raw ring and resets the file, so no raw
    // reference can be published after the final drain. A lease is refused once
    // close has begun (the caller then treats the segment as having no file
    // owner). Shares the append admission counter: both are file-lane producers.
    [[nodiscard]] bool acquire_lease() noexcept;
    void release_lease() noexcept;
    // Wake the dedicated writer thread after the read thread pushed a raw RX
    // reference. Non-blocking.
    void wake_rx() noexcept;

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
