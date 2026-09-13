// log_writer.cpp - bounded, ordered file I/O implementation.
#include "log_writer.hpp"

#include "foundation/fixed_pool.hpp"
#include "foundation/static_object_slot.hpp"
#include "foundation/rx_block_lane.hpp"
#include "foundation/unique_handle.hpp"
#include "xcom_core.hpp"

#include "coact/spsc_ring.hpp"
#include "coact/pal_windows.hpp"

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
// The writer is single-consumer and the UI submits at most one batch per
// frame.  Keep a small bounded backlog instead of reserving several MiB at
// startup; saturation reports XCOM_ERR_FULL and applies natural backpressure.
constexpr std::uint16_t kFileBlockCount = 16U;
constexpr std::uint16_t kFileJobCapacity = 16U;
constexpr std::uint16_t kCompletionCapacity = 32U;
constexpr std::uint16_t kCompletionPoolCapacity = 8U;
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
        // Explicit noexcept default ctor: GCC cannot compute the implicit
        // default constructor's exception specification for a nested type with
        // NSDMIs while the enclosing Impl is still incomplete, so
        // std::is_nothrow_default_constructible<FileJob> is a false negative
        // when coact::SpscRing<FileJob, ...> is instantiated at the member
        // declaration below. This declaration is behaviour- and ABI-identical
        // to the implicit one and keeps the type an aggregate in C++17.
        FileJob() noexcept = default;
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
        // See FileJob above: the explicit noexcept default ctor works around
        // the same GCC false negative on is_nothrow_default_constructible.
        AtomicCompletion() noexcept = default;
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
    // The public ABI serializes every call through one caller thread (the Lua
    // UI thread), while this dedicated writer thread is the sole consumer.
    // Keep this path SPSC so high-rate log append avoids the MPSC per-cell
    // probe and ticket scan.
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

    // Liveness (design §4.2 item 3). The writer thread stores its monotonic-ms
    // once per loop iteration and marks itself parked around the INFINITE idle
    // wake. PROGRESS is a different axis and must not be folded in: a writer
    // retrying a dead disk is ALIVE and keeps beating here; the storage-stall
    // episode below is what reports that it is making no progress. Do not
    // "fix" beat() to require progress.
    void beat() noexcept
    {
        if (core != nullptr) {
            core->heartbeats.log_writer_ms.store(
                static_cast<std::uint32_t>(coact::pal::monotonic_ms()),
                std::memory_order_relaxed);
        }
    }

    void set_parked(bool parked) noexcept
    {
        if (core != nullptr) {
            core->heartbeats.log_writer_parked.store(
                parked ? 1U : 0U, std::memory_order_release);
        }
    }

    // Lifecycle gate for the observer: 1 from the writer thread's first
    // iteration until it exits (and from shutdown() once teardown starts), 0
    // otherwise. A stopped writer leaves a stale stamp, which the observer
    // would otherwise read as an endless stall (design section 4.4 item 3).
    void set_running(bool up) noexcept
    {
        if (core != nullptr) {
            core->heartbeats.log_writer_running.store(
                up ? 1U : 0U, std::memory_order_release);
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

    // Write one raw RX block directly from its pool payload (no extra copy)
    // and release its single owned reference. Mirrors Kind::Append's no-loss
    // retry: a temporary disk failure never converts to a drop; if shutdown is
    // requested mid-retry the unwritten tail is surfaced, never silently
    // persisted as complete.
    void process_rx_ref(const foundation::RxBlockRef& ref) noexcept
    {
        if (ref.event == nullptr) {
            return;
        }
        const std::uint8_t* const data =
            foundation::RxBlockLane::payload(ref.event);
        std::uint32_t offset = 0U;
        if (ref.len != 0U) {
            if (!log_file.valid()) {
                if (core != nullptr) {
                    // Close admission now quiesces the reader, so this should be
                    // unreachable; kept as the loss ledger of last resort. An
                    // error-ring line alone is not a ledger.
                    core->metrics.save_rejected_bytes.fetch_add(
                        ref.len, std::memory_order_relaxed);
                    core->errors.push(XCOM_ERR_NOT_OPEN, 2U,
                                      "raw RX with no open file (counted as loss)");
                }
            }
            else {
                while (offset < ref.len &&
                       !stopping.load(std::memory_order_acquire)) {
                    // Alive while retrying a stalled raw-RX write: keep beating
                    // so a slow disk is not misreported as a wedged writer.
                    beat();
                    unsigned long written = 0U;
                    const unsigned long remaining =
                        static_cast<unsigned long>(ref.len - offset);
                    if (!WriteFile(log_file.get(), data + offset, remaining,
                                   &written, nullptr) ||
                        written == 0U) {
                        if (stopping.load(std::memory_order_acquire)) {
                            break;
                        }
                        coact::pal::sleep_ms(50U);
                        continue;
                    }
                    offset += static_cast<std::uint32_t>(written);
                }
                if (offset < ref.len && core != nullptr) {
                    core->metrics.save_rejected_bytes.fetch_add(
                        ref.len - offset, std::memory_order_relaxed);
                    core->errors.push(XCOM_ERR_IO, 2U,
                                      "raw RX log tail unwritten at stop (counted as loss)");
                }
            }
        }
        if (core != nullptr) {
            core->rx.release(ref.event);   // wakes a blocked reader
        }
        else {
            coact::event_gc(ref.event);
        }
    }

    // Best-effort drain used at shutdown/cancel: process_rx_ref releases every
    // reference and does not write once `stopping` is set.
    void cancel_pending_rx() noexcept
    {
        if (core == nullptr) {
            return;
        }
        foundation::RxBlockRef ref{};
        while (core->rx.pop_raw(ref)) {
            process_rx_ref(ref);
        }
    }

    // Flush queued raw RX to the currently open file before it is closed, so a
    // normal Close never strands already-accepted raw bytes.
    void flush_rx_before_close() noexcept
    {
        if (core == nullptr || !log_file.valid()) {
            return;
        }
        foundation::RxBlockRef ref{};
        while (core->rx.pop_raw(ref)) {
            process_rx_ref(ref);
        }
    }

    [[nodiscard]] XcomStatus write_all(FileJob& job,
                                       foundation::UniqueHandle& file,
                                       std::int32_t* win32_error = nullptr) noexcept
    {
        while (job.offset < job.size) {
            // Liveness (design section 4.2 item 3): beat before EVERY WriteFile.
            // Without this, a write_all that loops over many short writes (a
            // large atomic/stream write) could run past the writer timeout with
            // no signal, and so could a caller that never beats around it
            // (process_atomic / stream append). The ONLY un-beated span left is
            // one synchronous WriteFile call itself, which the platform cannot
            // bound (no per-call timeout): a single call into a wedged
            // redirector may still trip one false "stalled" episode. That is
            // accepted on purpose - liveness and progress are different axes,
            // and the storage-stall episode reports the progress axis.
            beat();
            // `unsigned long` is the exact native Win32 counter type WriteFile
            // expects; using it directly keeps the boundary cast-free.
            unsigned long written = 0U;
            const unsigned long remaining =
                static_cast<unsigned long>(job.size - job.offset);
            const BOOL written_ok =
                WriteFile(file.get(), job_data(job) + job.offset, remaining,
                          &written, nullptr);
            if (written_ok == FALSE || written == 0U) {
                // Surface the Win32 cause so the Append retry loop can name the
                // storage failure instead of retrying silently. A WriteFile
                // that succeeded yet wrote nothing has no GetLastError of its
                // own, so report the device-write code for that case.
                if (win32_error != nullptr) {
                    *win32_error = written_ok == FALSE
                        ? static_cast<std::int32_t>(GetLastError())
                        : static_cast<std::int32_t>(ERROR_WRITE_FAULT);
                }
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
        case Kind::Append: {
            if (!log_file.valid()) {
                status = XCOM_ERR_NOT_OPEN;
                break;
            }
            // Accepted log data remains in its owned block until every byte is
            // written. A temporary disk failure never converts to a drop.
            // Report the stall ONCE per failure run (not once per 50 ms retry)
            // so a dead disk is visible in the error ring without flooding it,
            // then report the recovery once when the run finally succeeds.
            bool stall_reported = false;
            std::int32_t write_error = 0;
            do {
                // Alive while retrying a stalled log write: the 50 ms retry
                // beat keeps a dead disk from looking like a wedged thread.
                beat();
                status = write_all(job, log_file, &write_error);
                if (status != XCOM_OK) {
                    if (!stall_reported) {
                        stall_reported = true;
                        if (core != nullptr) {
                            core->errors.push(
                                write_error, 2U,
                                "storage stalled: log write retrying (disk slow or device gone)");
                        }
                    }
                    if (!stopping.load(std::memory_order_acquire)) {
                        coact::pal::sleep_ms(50U);
                    }
                }
            } while (status != XCOM_OK &&
                     !stopping.load(std::memory_order_acquire));
            if (stall_reported && status == XCOM_OK && core != nullptr) {
                core->errors.push(XCOM_OK, 2U,
                                  "storage recovered: log write resumed");
            }
            break;
        }
        case Kind::Flush:
            if (!log_file.valid() || !FlushFileBuffers(log_file.get())) {
                status = XCOM_ERR_IO;
            }
            break;
        case Kind::Close:
            // Stop admitting raw RX first, then drain queued references to the
            // still-open file: already accepted bytes must reach disk even if
            // the Close raced them.
            accepting_log.store(false, std::memory_order_release);
            flush_rx_before_close();
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

LogWriter::LogWriter() noexcept = default;

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
    if (core == nullptr) {
        return false;
    }
    if (impl_ == nullptr) {
        impl_ = Impl::slot().try_emplace();
        if (impl_ == nullptr) {
            return false;
        }
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
            // Liveness gate up: from here the observer may judge this thread.
            impl_->set_running(true);
            for (;;) {
                // Liveness: a completed iteration means the loop came back to
                // its wait point, regardless of whether a job arrived.
                impl_->beat();
                // Shutdown takes precedence over queued work. In particular,
                // a permanently failing Append retries until `stopping` is
                // set; processing the queued Close before setting that flag
                // would otherwise make destruction wait forever.
                if (impl_->stopping.load(std::memory_order_acquire)) {
                    impl_->cancel_pending();
                    impl_->cancel_pending_rx();
                    break;
                }
                Impl::FileJob job{};
                if (impl_->jobs.try_pop(job)) {
                    impl_->process(job);
                    continue;
                }
                // Raw RX lane: the read thread is the sole producer, this
                // thread the sole consumer. Prefer queued jobs (Open/Close/
                // Flush control ordering) over the byte stream.
                foundation::RxBlockRef rx_ref{};
                if (impl_->core != nullptr &&
                    impl_->core->rx.pop_raw(rx_ref)) {
                    impl_->process_rx_ref(rx_ref);
                    continue;
                }
                // No work: park in the INFINITE wake. The park flag keeps the
                // idle writer healthy (design §4.1: parked is not a wedge).
                impl_->set_parked(true);
                impl_->wake_event.wait(kInfiniteTimeout);
                impl_->set_parked(false);
            }
            impl_->log_file.reset();
            impl_->atomic_stream.reset();
            // Liveness gate down before the thread object is joined, so a
            // leftover stamp is never reported as a stall.
            impl_->set_running(false);
        });
    } catch (...) {
        impl_->running.store(false, std::memory_order_release);
        return false;
    }
    return true;
}

bool LogWriter::accepting() const noexcept
{
    return impl_ != nullptr &&
           impl_->accepting_log.load(std::memory_order_acquire);
}

bool LogWriter::acquire_lease() noexcept
{
    // Reuses the append admission pair: close_append_admission() waits for this
    // counter to reach zero, so a raw-RX publish that passed admission is
    // guaranteed to complete before the Close handler drains the raw ring.
    return impl_ != nullptr && impl_->acquire_append_lease();
}

void LogWriter::release_lease() noexcept
{
    if (impl_ != nullptr) {
        impl_->release_append_lease();
    }
}

void LogWriter::wake_rx() noexcept
{
    if (impl_ != nullptr && impl_->running.load(std::memory_order_acquire)) {
        impl_->wake_event.signal();
    }
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
    // Teardown is underway and the queue is settled: stop the observer from
    // judging this thread, so the stale stamp left before the join is never a
    // stall. The worker also clears the gate on its own exit.
    impl_->set_running(false);
    impl_->wake_event.signal();
    if (impl_->thread.joinable()) {
        impl_->thread.join();
    }
    impl_->running.store(false, std::memory_order_release);
}

}  // namespace xcom
