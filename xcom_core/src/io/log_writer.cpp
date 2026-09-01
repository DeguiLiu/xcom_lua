// log_writer.cpp - bounded, ordered file I/O implementation.
#include "log_writer.hpp"

#include "foundation/fixed_pool.hpp"
#include "foundation/static_object_slot.hpp"
#include "foundation/unique_handle.hpp"
#include "xcom_core.hpp"

#include "coact/spsc_ring.hpp"
#include "pal_windows.hpp"

#include <windows.h>

#include <array>
#include <atomic>
#include <cstdint>
#include <cstring>
#include <cwchar>
#include <new>
#include <optional>
#include <thread>
#include <utility>

namespace xcom {
namespace {

constexpr std::uint32_t kFileBlockBytes = 64U * 1024U;
constexpr std::uint16_t kFileBlockCount = 256U;
constexpr std::uint16_t kFileJobCapacity = 256U;
constexpr std::uint16_t kCompletionCapacity = 1024U;
constexpr std::uint16_t kCompletionPoolCapacity = 32U;
constexpr std::size_t kPathChars = 520U;
constexpr std::size_t kTemporaryPathChars = kPathChars + 48U;
constexpr std::uint16_t kInvalidBlockId = 0xFFFFU;

// Neutral aliases for Win32's INFINITE / MAXDWORD (both 0xFFFFFFFF) so the
// file-writer body never spells Win32 timeout constants.
constexpr std::uint32_t kInfiniteTimeout = 0xFFFFFFFFU;
constexpr std::uint32_t kMaxTimeoutMs = 0xFFFFFFFFU;

template <std::size_t Capacity>
[[nodiscard]] bool utf8_to_wide(const char* source,
                                std::array<wchar_t, Capacity>& destination) noexcept
{
    if (source == nullptr || *source == '\0') {
        return false;
    }
    const int required = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS,
                                              source, -1, nullptr, 0);
    if (required <= 1 || static_cast<std::size_t>(required) > Capacity) {
        return false;
    }
    return MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, source, -1,
                               destination.data(), required) == required;
}

}  // namespace

struct LogWriter::Impl {
    enum class Kind : std::uint8_t {
        Open,
        Append,
        Flush,
        Close,
        AtomicWrite,
        StreamBegin,
        StreamAppend,
        StreamCommit,
        StreamAbort,
    };

    struct Completion {
        std::atomic<std::int32_t> ref_count{1};
        std::atomic<std::int32_t> status{XCOM_ERR_IO};
        coact::pal::WakeEvent done_event;

        Completion() = default;

        [[nodiscard]] bool valid() const noexcept
        {
            return done_event.valid();
        }

        void acquire() noexcept
        {
            ref_count.fetch_add(1, std::memory_order_relaxed);
        }

        [[nodiscard]] bool release() noexcept
        {
            return ref_count.fetch_sub(1, std::memory_order_acq_rel) == 1;
        }
    };

    struct FileJob {
        Kind kind = Kind::Append;
        std::uint16_t block_id = kInvalidBlockId;
        std::uint32_t size = 0U;
        std::uint32_t offset = 0U;
        std::uint64_t request_id = 0U;
        std::uint64_t stream_id = 0U;
        const std::uint8_t* borrowed_data = nullptr;
        bool borrowed = false;
        bool append = false;
        Completion* completion = nullptr;
        std::array<wchar_t, kPathChars> path{};
    };

    struct AtomicCompletion {
        std::uint64_t request_id = 0U;
        XcomStatus status = XCOM_ERR_IO;
    };

    struct AtomicStream {
        std::uint64_t id = 0U;
        bool active = false;
        std::array<wchar_t, kPathChars> destination{};
        std::array<wchar_t, kTemporaryPathChars> temporary{};
        foundation::UniqueHandle file;

        AtomicStream(std::uint64_t stream_id,
                     std::array<wchar_t, kPathChars>&& target,
                     std::array<wchar_t, kTemporaryPathChars>&& temp,
                     foundation::UniqueHandle&& handle) noexcept
            : id(stream_id), active(true), destination(std::move(target)),
              temporary(std::move(temp)), file(std::move(handle)) {}

        AtomicStream(const AtomicStream&) = delete;
        AtomicStream& operator=(const AtomicStream&) = delete;

        AtomicStream(AtomicStream&& other) noexcept
            : id(std::exchange(other.id, 0U)),
              active(std::exchange(other.active, false)),
              destination(std::move(other.destination)),
              temporary(std::move(other.temporary)), file(std::move(other.file)) {}

        AtomicStream& operator=(AtomicStream&& other) noexcept
        {
            if (this != &other) {
                abort();
                id = std::exchange(other.id, 0U);
                active = std::exchange(other.active, false);
                destination = std::move(other.destination);
                temporary = std::move(other.temporary);
                file = std::move(other.file);
            }
            return *this;
        }

        ~AtomicStream() { abort(); }

        void abort() noexcept
        {
            file.reset();
            if (std::exchange(active, false) && temporary[0] != L'\0') {
                static_cast<void>(DeleteFileW(temporary.data()));
            }
        }

        [[nodiscard]] XcomStatus commit() noexcept
        {
            const bool flushed = file.valid() && FlushFileBuffers(file.get());
            file.reset();
            if (!flushed || !MoveFileExW(temporary.data(), destination.data(),
                                         MOVEFILE_REPLACE_EXISTING |
                                             MOVEFILE_WRITE_THROUGH)) {
                return XCOM_ERR_IO;
            }
            active = false;
            return XCOM_OK;
        }
    };

    using FilePool = foundation::FixedPool<kFileBlockBytes, kFileBlockCount>;
    // The public ABI serializes every call through one CoreWorker, while this
    // dedicated writer thread is the sole consumer.  Keep this path SPSC so
    // high-rate log append avoids the MPSC per-cell probe and ticket scan.
    using JobQueue = coact::SpscRing<FileJob, kFileJobCapacity>;
    using CompletionQueue = coact::SpscRing<AtomicCompletion,
                                            kCompletionCapacity>;
    using CompletionPool = foundation::FixedPool<sizeof(Completion),
                                                 kCompletionPoolCapacity>;

    FilePool data_pool;
    JobQueue jobs;
    CompletionQueue completions;
    CompletionPool completion_pool;
    std::thread thread;
    coact::pal::WakeEvent wake_event;
    std::atomic<std::uint32_t> pending_completions{0U};
    std::atomic<bool> running{false};
    std::atomic<bool> stopping{false};
    std::atomic<bool> accepting_log{false};
    std::atomic<std::uint32_t> appenders_in_flight{0U};
    coact::pal::WakeEvent appenders_drained_event;
    CoreCtx* core = nullptr;
    foundation::UniqueHandle log_file;
    std::optional<AtomicStream> atomic_stream;

    static foundation::StaticObjectSlot<Impl>& slot() noexcept
    {
        static foundation::StaticObjectSlot<Impl> storage;
        return storage;
    }

    ~Impl() = default;

    [[nodiscard]] Completion* acquire_completion() noexcept
    {
        void* const storage = completion_pool.allocate();
        if (storage == nullptr) {
            return nullptr;
        }
        Completion* const completion = ::new (storage) Completion{};
        if (!completion->valid()) {
            completion->~Completion();
            completion_pool.release(completion);
            return nullptr;
        }
        return completion;
    }

    void release_completion(Completion& completion) noexcept
    {
        if (completion.release()) {
            completion.~Completion();
            completion_pool.release(&completion);
        }
    }

    [[nodiscard]] bool reserve_completion() noexcept
    {
        std::uint32_t pending = pending_completions.load(std::memory_order_relaxed);
        while (pending < kCompletionCapacity) {
            if (pending_completions.compare_exchange_weak(
                    pending, pending + 1U, std::memory_order_acq_rel,
                    std::memory_order_relaxed)) {
                return true;
            }
        }
        return false;
    }

    void release_completion_reservation() noexcept
    {
        pending_completions.fetch_sub(1U, std::memory_order_acq_rel);
    }

    [[nodiscard]] bool acquire_append_lease() noexcept
    {
        for (;;) {
            if (!accepting_log.load(std::memory_order_acquire)) {
                return false;
            }
            appenders_in_flight.fetch_add(1U, std::memory_order_acq_rel);
            if (accepting_log.load(std::memory_order_acquire)) {
                return true;
            }
            release_append_lease();
        }
    }

    void release_append_lease() noexcept
    {
        if (appenders_in_flight.fetch_sub(1U, std::memory_order_acq_rel) ==
            1U) {
            appenders_drained_event.signal();
        }
    }

    [[nodiscard]] bool close_append_admission(
        std::uint32_t timeout_ms) noexcept
    {
        accepting_log.store(false, std::memory_order_release);
        const std::uint64_t deadline =
            timeout_ms == kInfiniteTimeout
                ? 0U
                : coact::pal::monotonic_ms() + timeout_ms;
        for (;;) {
            const std::uint32_t active = appenders_in_flight.load(
                std::memory_order_acquire);
            if (active == 0U) {
                return true;
            }
            if (!appenders_drained_event.valid()) {
                return false;
            }
            std::uint32_t wait_ms = kInfiniteTimeout;
            if (timeout_ms != kInfiniteTimeout) {
                const std::uint64_t now = coact::pal::monotonic_ms();
                if (now >= deadline) {
                    return false;
                }
                const std::uint64_t remaining = deadline - now;
                wait_ms = static_cast<std::uint32_t>(
                    remaining > kMaxTimeoutMs ? kMaxTimeoutMs : remaining);
            }
            static_cast<void>(appenders_drained_event.wait(wait_ms));
        }
    }

    [[nodiscard]] std::uint8_t* block_data(std::uint16_t block_id) noexcept
    {
        COACT_ASSERT(block_id < kFileBlockCount);
        return static_cast<std::uint8_t*>(data_pool.block_ptr(block_id));
    }

    void release_block(std::uint16_t block_id) noexcept
    {
        if (block_id != kInvalidBlockId) {
            data_pool.release(data_pool.block_ptr(block_id));
        }
    }

    [[nodiscard]] bool enqueue(FileJob&& job) noexcept
    {
        if (!running.load(std::memory_order_acquire) ||
            stopping.load(std::memory_order_acquire) ||
            !jobs.try_push(std::move(job))) {
            return false;
        }
        wake_event.signal();
        return true;
    }

    void publish_atomic_completion(std::uint64_t request_id,
                                   XcomStatus status) noexcept
    {
        AtomicCompletion completion{request_id, status};
        const bool pushed = completions.try_push(std::move(completion));
        COACT_ASSERT(pushed);
    }

    void complete_sync(Completion* completion, XcomStatus status) noexcept
    {
        if (completion == nullptr) {
            return;
        }
        completion->status.store(status, std::memory_order_release);
        completion->done_event.signal();
        release_completion(*completion);  // queued-job reference
    }

    void finish(FileJob& job, XcomStatus status) noexcept
    {
        if (job.kind == Kind::AtomicWrite || job.kind == Kind::StreamBegin ||
            job.kind == Kind::StreamAppend || job.kind == Kind::StreamCommit ||
            job.kind == Kind::StreamAbort) {
            publish_atomic_completion(job.request_id, status);
        }
        if (status != XCOM_OK && core != nullptr) {
            core->errors.push(status, 2U, "dedicated file writer failed");
        }
        release_block(job.block_id);
        complete_sync(job.completion, status);
    }

    [[nodiscard]] const std::uint8_t* job_data(const FileJob& job) noexcept
    {
        return job.borrowed ? job.borrowed_data : block_data(job.block_id);
    }

    [[nodiscard]] XcomStatus write_all(FileJob& job,
                                       foundation::UniqueHandle& file) noexcept
    {
        while (job.offset < job.size) {
            // `unsigned long` is the exact native Win32 counter type WriteFile
            // expects; using it directly keeps the boundary cast-free.
            unsigned long written = 0U;
            const unsigned long remaining =
                static_cast<unsigned long>(job.size - job.offset);
            if (!WriteFile(file.get(), job_data(job) + job.offset,
                           remaining, &written, nullptr) ||
                written == 0U) {
                return XCOM_ERR_IO;
            }
            job.offset += static_cast<std::uint32_t>(written);
        }
        return XCOM_OK;
    }

    [[nodiscard]] XcomStatus process_atomic(FileJob& job) noexcept
    {
        std::array<wchar_t, kTemporaryPathChars> temporary{};
        if (std::swprintf(temporary.data(), temporary.size(), L"%ls.xcom.%llu.tmp",
                          job.path.data(),
                          static_cast<unsigned long long>(job.request_id)) < 0) {
            return XCOM_ERR_PARAM;
        }
        foundation::UniqueHandle file(
            CreateFileW(temporary.data(), GENERIC_WRITE, 0, nullptr,
                        CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr));
        if (!file.valid()) {
            return XCOM_ERR_IO;
        }
        const XcomStatus write_status = write_all(job, file);
        const bool flushed = write_status == XCOM_OK &&
                             FlushFileBuffers(file.get());
        file.reset();
        if (!flushed || !MoveFileExW(temporary.data(), job.path.data(),
                                     MOVEFILE_REPLACE_EXISTING |
                                         MOVEFILE_WRITE_THROUGH)) {
            DeleteFileW(temporary.data());
            return XCOM_ERR_IO;
        }
        return XCOM_OK;
    }

    [[nodiscard]] XcomStatus process_stream_begin(FileJob& job) noexcept
    {
        if (atomic_stream.has_value()) {
            return XCOM_ERR_BUSY;
        }
        std::array<wchar_t, kTemporaryPathChars> temporary{};
        if (std::swprintf(temporary.data(), temporary.size(),
                          L"%ls.xcom.%llu.tmp", job.path.data(),
                          static_cast<unsigned long long>(job.stream_id)) < 0) {
            return XCOM_ERR_PARAM;
        }
        foundation::UniqueHandle file(
            CreateFileW(temporary.data(), GENERIC_WRITE, 0, nullptr,
                        CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr));
        if (!file.valid()) {
            return XCOM_ERR_IO;
        }
        atomic_stream.emplace(job.stream_id, std::move(job.path),
                              std::move(temporary), std::move(file));
        return XCOM_OK;
    }

    [[nodiscard]] XcomStatus process_stream_append(FileJob& job) noexcept
    {
        if (!atomic_stream.has_value() || atomic_stream->id != job.stream_id) {
            return XCOM_ERR_NOT_OPEN;
        }
        const XcomStatus status = write_all(job, atomic_stream->file);
        if (status != XCOM_OK) {
            atomic_stream.reset();
        }
        return status;
    }

    [[nodiscard]] XcomStatus process_stream_commit(FileJob& job) noexcept
    {
        if (!atomic_stream.has_value() || atomic_stream->id != job.stream_id) {
            return XCOM_ERR_NOT_OPEN;
        }
        std::optional<AtomicStream> stream = std::exchange(atomic_stream,
                                                             std::nullopt);
        return stream->commit();
    }

    [[nodiscard]] XcomStatus process_stream_abort(FileJob& job) noexcept
    {
        if (!atomic_stream.has_value()) {
            // Abort is cleanup: a prior failed append/commit, an earlier
            // abort, or shutdown may already have removed the temporary file.
            return XCOM_OK;
        }
        if (atomic_stream->id != job.stream_id) {
            return XCOM_ERR_NOT_OPEN;
        }
        atomic_stream.reset();
        return XCOM_OK;
    }

    void process(FileJob& job) noexcept
    {
        XcomStatus status = XCOM_OK;
        switch (job.kind) {
        case Kind::Open: {
            if (log_file.valid()) {
                status = XCOM_ERR_BUSY;
                break;
            }
            const unsigned long disposition =
                job.append ? OPEN_ALWAYS : CREATE_ALWAYS;
            log_file.reset(
                CreateFileW(job.path.data(), GENERIC_WRITE, FILE_SHARE_READ,
                            nullptr, disposition, FILE_ATTRIBUTE_NORMAL,
                            nullptr));
            if (!log_file.valid()) {
                status = XCOM_ERR_IO;
            } else if (job.append) {
                LARGE_INTEGER zero{};
                static_cast<void>(SetFilePointerEx(log_file.get(), zero,
                                                   nullptr, FILE_END));
            }
            accepting_log.store(status == XCOM_OK, std::memory_order_release);
            break;
        }
        case Kind::Append:
            if (!log_file.valid()) {
                status = XCOM_ERR_NOT_OPEN;
                break;
            }
            // Accepted log data remains in its owned block until every byte is
            // written. A temporary disk failure never converts to a drop.
            do {
                status = write_all(job, log_file);
                if (status != XCOM_OK &&
                    !stopping.load(std::memory_order_acquire)) {
                    coact::pal::sleep_ms(50U);
                }
            } while (status != XCOM_OK &&
                     !stopping.load(std::memory_order_acquire));
            break;
        case Kind::Flush:
            if (!log_file.valid() || !FlushFileBuffers(log_file.get())) {
                status = XCOM_ERR_IO;
            }
            break;
        case Kind::Close:
            accepting_log.store(false, std::memory_order_release);
            if (log_file.valid()) {
                if (!FlushFileBuffers(log_file.get())) {
                    status = XCOM_ERR_IO;
                }
                log_file.reset();
            }
            break;
        case Kind::AtomicWrite:
            status = process_atomic(job);
            break;
        case Kind::StreamBegin:
            status = process_stream_begin(job);
            break;
        case Kind::StreamAppend:
            status = process_stream_append(job);
            break;
        case Kind::StreamCommit:
            status = process_stream_commit(job);
            break;
        case Kind::StreamAbort:
            status = process_stream_abort(job);
            break;
        }
        finish(job, status);
    }

    void cancel_pending() noexcept
    {
        FileJob pending{};
        while (jobs.try_pop(pending)) {
            finish(pending, XCOM_ERR_TIMEOUT);
        }
    }
};

LogWriter::LogWriter() noexcept : impl_(Impl::slot().try_emplace()) {}

LogWriter::~LogWriter()
{
    shutdown(2000U);
    if (impl_ != nullptr) {
        Impl::slot().destroy(*impl_);
        impl_ = nullptr;
    }
}

bool LogWriter::start(CoreCtx* core) noexcept
{
    if (impl_ == nullptr || core == nullptr) {
        return false;
    }
    if (impl_->running.load(std::memory_order_acquire)) {
        return true;
    }
    impl_->core = core;
    impl_->stopping.store(false, std::memory_order_release);
    if (!impl_->wake_event.valid()) {
        return false;
    }
    impl_->running.store(true, std::memory_order_release);
    try {
        impl_->thread = std::thread([this] {
            // Disk I/O must never preempt the high-priority receive path.
            // Normal priority still drains retained log batches under pressure.
            static_cast<void>(SetThreadPriority(GetCurrentThread(),
                                                THREAD_PRIORITY_NORMAL));
            for (;;) {
                // Shutdown takes precedence over queued work. In particular,
                // a permanently failing Append retries until `stopping` is
                // set; processing the queued Close before setting that flag
                // would otherwise make destruction wait forever.
                if (impl_->stopping.load(std::memory_order_acquire)) {
                    impl_->cancel_pending();
                    break;
                }
                Impl::FileJob job{};
                if (impl_->jobs.try_pop(job)) {
                    impl_->process(job);
                    continue;
                }
                impl_->wake_event.wait(kInfiniteTimeout);
            }
            impl_->log_file.reset();
            impl_->atomic_stream.reset();
        });
    } catch (...) {
        impl_->running.store(false, std::memory_order_release);
        return false;
    }
    return true;
}

namespace {

XcomStatus submit_sync(LogWriter::Impl& impl, LogWriter::Impl::FileJob&& job,
                       std::uint32_t timeout_ms) noexcept
{
    LogWriter::Impl::Completion* const completion = impl.acquire_completion();
    if (completion == nullptr) {
        return XCOM_ERR_FULL;
    }
    completion->acquire();  // the queued job owns a second intrusive reference
    job.completion = completion;
    if (!impl.enqueue(std::move(job))) {
        impl.release_completion(*completion);  // job was never queued
        impl.release_completion(*completion);  // caller reference
        return XCOM_ERR_FULL;
    }
    if (!completion->done_event.wait(timeout_ms)) {
        impl.release_completion(*completion);
        return XCOM_ERR_TIMEOUT;
    }
    const XcomStatus status = static_cast<XcomStatus>(
        completion->status.load(std::memory_order_acquire));
    impl.release_completion(*completion);
    return status;
}

}  // namespace

XcomStatus LogWriter::open(const char* utf8_path, bool append) noexcept
{
    if (impl_ == nullptr) {
        return XCOM_ERR_IO;
    }
    Impl::FileJob job{};
    job.kind = Impl::Kind::Open;
    job.append = append;
    if (!utf8_to_wide(utf8_path, job.path)) {
        return XCOM_ERR_PARAM;
    }
    if (impl_->accepting_log.load(std::memory_order_acquire)) {
        return XCOM_ERR_BUSY;
    }
    return submit_sync(*impl_, std::move(job), 2000U);
}

XcomStatus LogWriter::append(const std::uint8_t* data, std::uint32_t size) noexcept
{
    if (impl_ == nullptr || data == nullptr || size > kFileBlockBytes) {
        return size > kFileBlockBytes ? XCOM_ERR_FULL : XCOM_ERR_PARAM;
    }
    if (!impl_->acquire_append_lease()) {
        return XCOM_ERR_NOT_OPEN;
    }
    struct AppendLease final {
        Impl& impl;
        ~AppendLease() { impl.release_append_lease(); }
    } lease{*impl_};
    void* const block = impl_->data_pool.allocate();
    if (block == nullptr) {
        return XCOM_ERR_FULL;
    }
    Impl::FileJob job{};
    job.kind = Impl::Kind::Append;
    job.block_id = static_cast<std::uint16_t>(impl_->data_pool.block_index(block));
    job.size = size;
    if (size > 0U) {
        std::memcpy(block, data, size);
    }
    if (!impl_->enqueue(std::move(job))) {
        impl_->data_pool.release(block);
        return XCOM_ERR_FULL;
    }
    return XCOM_OK;
}

XcomStatus LogWriter::flush(std::uint32_t timeout_ms) noexcept
{
    return impl_ == nullptr ? XCOM_ERR_IO :
           submit_sync(*impl_, Impl::FileJob{Impl::Kind::Flush}, timeout_ms);
}

XcomStatus LogWriter::close(std::uint32_t timeout_ms) noexcept
{
    if (impl_ == nullptr) {
        return XCOM_ERR_IO;
    }
    if (!impl_->close_append_admission(timeout_ms)) {
        return XCOM_ERR_TIMEOUT;
    }
    return submit_sync(*impl_, Impl::FileJob{Impl::Kind::Close}, timeout_ms);
}

XcomStatus LogWriter::submit_atomic(const char* utf8_path,
                                    const std::uint8_t* data,
                                    std::uint32_t size,
                                    std::uint64_t request_id) noexcept
{
    if (impl_ == nullptr || data == nullptr || size > kFileBlockBytes) {
        return size > kFileBlockBytes ? XCOM_ERR_FULL : XCOM_ERR_PARAM;
    }
    Impl::FileJob job{};
    job.kind = Impl::Kind::AtomicWrite;
    job.request_id = request_id;
    job.size = size;
    if (!utf8_to_wide(utf8_path, job.path)) {
        return XCOM_ERR_PARAM;
    }
    if (!impl_->reserve_completion()) {
        return XCOM_ERR_FULL;
    }
    void* const block = impl_->data_pool.allocate();
    if (block == nullptr) {
        impl_->release_completion_reservation();
        return XCOM_ERR_FULL;
    }
    job.block_id = static_cast<std::uint16_t>(impl_->data_pool.block_index(block));
    if (size > 0U) {
        std::memcpy(block, data, size);
    }
    if (!impl_->enqueue(std::move(job))) {
        impl_->data_pool.release(block);
        impl_->release_completion_reservation();
        return XCOM_ERR_FULL;
    }
    return XCOM_OK;
}

XcomStatus LogWriter::submit_atomic_borrowed(const char* utf8_path,
                                             const std::uint8_t* data,
                                             std::uint32_t size,
                                             std::uint64_t request_id) noexcept
{
    if (impl_ == nullptr || (size != 0U && data == nullptr)) {
        return XCOM_ERR_PARAM;
    }
    Impl::FileJob job{};
    job.kind = Impl::Kind::AtomicWrite;
    job.request_id = request_id;
    job.borrowed_data = data;
    job.borrowed = true;
    job.size = size;
    if (!utf8_to_wide(utf8_path, job.path)) {
        return XCOM_ERR_PARAM;
    }
    if (!impl_->reserve_completion()) {
        return XCOM_ERR_FULL;
    }
    if (!impl_->enqueue(std::move(job))) {
        impl_->release_completion_reservation();
        return XCOM_ERR_FULL;
    }
    return XCOM_OK;
}

XcomStatus LogWriter::stream_begin(const char* utf8_path, std::uint64_t stream_id,
                                   std::uint64_t request_id) noexcept
{
    if (impl_ == nullptr || stream_id == 0U) {
        return XCOM_ERR_PARAM;
    }
    Impl::FileJob job{};
    job.kind = Impl::Kind::StreamBegin;
    job.stream_id = stream_id;
    job.request_id = request_id;
    if (!utf8_to_wide(utf8_path, job.path)) {
        return XCOM_ERR_PARAM;
    }
    if (!impl_->reserve_completion()) {
        return XCOM_ERR_FULL;
    }
    if (!impl_->enqueue(std::move(job))) {
        impl_->release_completion_reservation();
        return XCOM_ERR_FULL;
    }
    return XCOM_OK;
}

XcomStatus LogWriter::stream_append_borrowed(
    std::uint64_t stream_id, const std::uint8_t* data, std::uint32_t size,
    std::uint64_t request_id) noexcept
{
    if (impl_ == nullptr || stream_id == 0U || (size != 0U && data == nullptr)) {
        return XCOM_ERR_PARAM;
    }
    Impl::FileJob job{};
    job.kind = Impl::Kind::StreamAppend;
    job.stream_id = stream_id;
    job.request_id = request_id;
    job.borrowed_data = data;
    job.borrowed = true;
    job.size = size;
    if (!impl_->reserve_completion()) {
        return XCOM_ERR_FULL;
    }
    if (!impl_->enqueue(std::move(job))) {
        impl_->release_completion_reservation();
        return XCOM_ERR_FULL;
    }
    return XCOM_OK;
}

XcomStatus LogWriter::stream_commit(std::uint64_t stream_id,
                                    std::uint64_t request_id) noexcept
{
    if (impl_ == nullptr || stream_id == 0U) {
        return XCOM_ERR_PARAM;
    }
    Impl::FileJob job{};
    job.kind = Impl::Kind::StreamCommit;
    job.stream_id = stream_id;
    job.request_id = request_id;
    if (!impl_->reserve_completion()) {
        return XCOM_ERR_FULL;
    }
    if (!impl_->enqueue(std::move(job))) {
        impl_->release_completion_reservation();
        return XCOM_ERR_FULL;
    }
    return XCOM_OK;
}

XcomStatus LogWriter::stream_abort(std::uint64_t stream_id,
                                   std::uint64_t request_id) noexcept
{
    if (impl_ == nullptr || stream_id == 0U) {
        return XCOM_ERR_PARAM;
    }
    Impl::FileJob job{};
    job.kind = Impl::Kind::StreamAbort;
    job.stream_id = stream_id;
    job.request_id = request_id;
    if (!impl_->reserve_completion()) {
        return XCOM_ERR_FULL;
    }
    if (!impl_->enqueue(std::move(job))) {
        impl_->release_completion_reservation();
        return XCOM_ERR_FULL;
    }
    return XCOM_OK;
}

XcomStatus LogWriter::take_completion(std::uint64_t& request_id,
                                      XcomStatus& status) noexcept
{
    if (impl_ == nullptr) {
        return XCOM_ERR_IO;
    }
    Impl::AtomicCompletion completion{};
    if (!impl_->completions.try_pop(completion)) {
        request_id = 0U;
        status = XCOM_OK;
        return XCOM_OK;
    }
    impl_->release_completion_reservation();
    request_id = completion.request_id;
    status = completion.status;
    return XCOM_OK;
}

void LogWriter::shutdown(std::uint32_t timeout_ms) noexcept
{
    if (impl_ == nullptr || !impl_->running.load(std::memory_order_acquire)) {
        return;
    }
    if (close(timeout_ms) != XCOM_OK) {
        // A failed disk write may be retrying at the queue head. Do not queue
        // an infinite close behind it: request cancellation so the current
        // append exits its retry loop, pending work receives an explicit
        // completion failure, and the owner can join deterministically.
        impl_->accepting_log.store(false, std::memory_order_release);
    }
    impl_->stopping.store(true, std::memory_order_release);
    impl_->wake_event.signal();
    if (impl_->thread.joinable()) {
        impl_->thread.join();
    }
    impl_->running.store(false, std::memory_order_release);
}

}  // namespace xcom
