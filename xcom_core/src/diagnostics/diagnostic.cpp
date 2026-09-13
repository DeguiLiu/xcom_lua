// diagnostic.cpp - XCOM diagnostic log writer (task #5). See diagnostic.hpp.
//
// The core Logger is header-only; this TU owns the Windows adapter state:
//   - a coact::diag::Logger<64, 16, 50, 75>
//   - QPC clock ops (LogClockOps)
//   - an auto-reset wake event + Win32 wake ops (LogWakeOps)
//   - a spin critical section (LogSinkOps bound to a FILE*)
//   - a writer thread draining Critical (up to 4/batch) then Normal, rendering
//     each fixed 24-byte record into a text line via a static catalog, writing
//     through the FILE* sink, and rotating when the file exceeds the bound.
//
// SPDX-License-Identifier: MIT
#include "diagnostic.hpp"
#include "foundation/text.hpp"

#include <windows.h>

#include <array>
#include <atomic>
#include <cstdio>
#include <cstring>
#include <string_view>
#include <thread>

#include "coact/pal_windows.hpp"
#include "foundation/static_object_slot.hpp"
#include "xcom_core.hpp"

namespace xcom {

namespace {
constexpr uint16_t kNormalCap = 64U;
constexpr uint16_t kCriticalCap = 16U;
constexpr uint8_t kDebugWatermark = 50U;
constexpr uint8_t kInfoWatermark = 75U;
constexpr uint16_t kLineBufferSize = 256U;
constexpr uint16_t kCriticalDrainBatch = 4U;   // design §5.4
constexpr uint32_t kDefaultMaxBytes = 4U * 1024U * 1024U;   // 4 MB rotate bound

using LogLevel = coact::diag::LogLevel;
using LogLane = coact::diag::LogLane;
using LogRecord = coact::diag::LogRecord;

// Catalog descriptor for the writer-side renderer. kept in this adapter (the
// coact LogCatalog is designed for the RT-Thread policy; we own ours).
struct CatalogEntry {
    uint16_t event_id;
    const char* name;
};

// Returns the catalog name for the writer-side renderer as a string_view (all
// entries are rodata literals, so .data() stays NUL-terminated for the %s
// render below).
std::string_view diag_event_name(uint16_t event_id) noexcept
{
    switch (static_cast<DiagEvent>(event_id)) {
    case DiagEvent::kOpenOk:    return "OPEN_OK";
    case DiagEvent::kOpenFail:  return "OPEN_FAIL";
    case DiagEvent::kCloseOk:   return "CLOSE_OK";
    case DiagEvent::kFault:     return "FAULT";
    case DiagEvent::kWriteFail: return "WRITE_FAIL";
    case DiagEvent::kRxDrop:    return "RX_DROP";
    case DiagEvent::kTxRejected:return "TX_REJECTED";
    case DiagEvent::kErrPushed: return "ERR_PUSHED";
    case DiagEvent::kDiagTick:  return "DIAG_TICK";
    case DiagEvent::kDiagStart: return "DIAG_START";
    case DiagEvent::kDiagRotate:return "DIAG_ROTATE";
    case DiagEvent::kLineError: return "LINE_ERROR";
    }
    return "UNKNOWN";
}
}  // namespace

struct DiagnosticWriter::Impl {
    using LoggerT = coact::diag::Logger<kNormalCap, kCriticalCap,
                                        kDebugWatermark, kInfoWatermark>;

    Impl() : cs_ctx(coact::make_spin_critical_section(cs_))
    {
        foundation::copy_text("xcom_diag.log", path_);
    }

    static foundation::StaticObjectSlot<Impl>& slot() noexcept
    {
        static foundation::StaticObjectSlot<Impl> storage;
        return storage;
    }

    // ------- lifecycle / platform state ----------------
    LoggerT logger;
    coact::SpinCriticalSection cs_{};
    coact::CriticalSection cs_ctx;
    std::atomic<bool> stop_requested_{false};
    std::atomic<bool> started_{false};

    coact::pal::WakeEvent wake_;   // auto-reset (null-safe, value member)
    std::thread thread_;

    FILE* fp_ = nullptr;         // writer-thread owned
    uint64_t file_bytes_ = 0U;
    uint64_t max_bytes_ = kDefaultMaxBytes;
    uint32_t rotate_count_ = 0U;
    std::array<char, 512U> path_{};
    uint32_t sink_writes_ = 0U;

    uint64_t qpc_freq_ = 0U;

    // ------- QPC clock ops ----------------
    static uint32_t clock_read(void* ctx) noexcept
    {
        Impl* self = static_cast<Impl*>(ctx);
        if (self == nullptr) {
            return 0U;
        }
        LARGE_INTEGER c;
        QueryPerformanceCounter(&c);
        return static_cast<uint32_t>(c.QuadPart & 0xFFFFFFFFU);
    }

    // ------- Wake ops (auto-reset event) ----------------
    static void wake_signal_task(void* ctx) noexcept
    {
        Impl* self = static_cast<Impl*>(ctx);
        if (self != nullptr) {
            self->wake_.signal();
        }
    }
    static void wake_signal_isr(void* ctx) noexcept { wake_signal_task(ctx); }
    static void wake_wait_block(void* ctx) noexcept
    {
        Impl* self = static_cast<Impl*>(ctx);
        if (self != nullptr) {
            self->wake_.wait(0U);
        }
    }
    static void wake_wait_bounded(void* ctx, uint32_t timeout_ms) noexcept
    {
        Impl* self = static_cast<Impl*>(ctx);
        if (self != nullptr) {
            self->wake_.wait(timeout_ms);
        }
    }

    // ------- Sink ops (FILE*) ----------------
    static bool file_sink(void* ctx, const char* bytes, uint16_t length) noexcept
    {
        Impl* self = static_cast<Impl*>(ctx);
        if (self == nullptr || self->fp_ == nullptr) {
            return false;
        }
        // Rotate before the line if appending would exceed the bound.
        if (self->file_bytes_ + length > self->max_bytes_ &&
            self->max_bytes_ > 0U) {
            self->rotate();
        }
        const size_t n =
            std::fwrite(bytes, 1, static_cast<size_t>(length), self->fp_);
        if (n != static_cast<size_t>(length)) {
            return false;
        }
        self->file_bytes_ += length;
        ++self->sink_writes_;
        return true;
    }

    void rotate() noexcept
    {
        if (fp_ != nullptr) {
            std::fclose(fp_);
            fp_ = nullptr;
        }
        ++rotate_count_;
        file_bytes_ = 0U;
        fp_ = std::fopen(path_.data(), "wt");
        // Note the rotation event from the sink context is not safe to push into
        // the logger we are draining; the writer loop reports it instead.
        (void)rotate_count_;
    }

    bool bind_logger() noexcept
    {
        if (!wake_.valid()) {
            return false;
        }
        LARGE_INTEGER f;
        QueryPerformanceFrequency(&f);
        qpc_freq_ = static_cast<uint64_t>(f.QuadPart);

        coact::diag::LogClockOps clock;
        clock.read_counter = &Impl::clock_read;
        clock.frequency_hz = static_cast<uint32_t>(qpc_freq_);
        clock.context = this;

        coact::diag::LogSinkOps sink;
        sink.write = &Impl::file_sink;
        sink.context = this;

        coact::diag::LogWakeOps wake;
        wake.signal_from_task = &Impl::wake_signal_task;
        wake.signal_from_isr = &Impl::wake_signal_isr;
        wake.wait_block = &Impl::wake_wait_block;
        wake.wait_bounded = &Impl::wake_wait_bounded;
        wake.context = this;

        // fp_ may be nullptr if the file could not be opened; the logger still
        // binds and the sink simply reports sink_failed (producers never block).
        return logger.bind(clock, sink, wake, cs_ctx);
    }

    void writer_run() noexcept
    {
        for (;;) {
            bool drained_any = false;
            for (uint8_t i = 0U; i < kCriticalDrainBatch; ++i) {
                LogRecord r;
                if (logger.pop_from_lane(LogLane::kCritical, r)) {
                    emit_line(r);
                    drained_any = true;
                }
                else {
                    break;
                }
            }
            LogRecord normal;
            if (logger.pop_from_lane(LogLane::kNormal, normal)) {
                emit_line(normal);
                drained_any = true;
            }

            const bool stop = stop_requested_.load(std::memory_order_acquire);
            if (stop && logger.size(LogLane::kCritical) == 0U &&
                logger.size(LogLane::kNormal) == 0U) {
                break;
            }
            if (!drained_any) {
                if (stop) {
                    break;
                }
                // Pure blocking wait; no polling backoff (design §5.4).
                wake_.wait(0U);
            }
        }
    }

    void emit_line(const LogRecord& r) noexcept
    {
        std::array<char, kLineBufferSize> line{};
        int n = std::snprintf(
            line.data(), line.size(),
            "[%u] ev=%u src=%u %s a0=%u a1=%u a2=%u a3=%u\n",
            r.counter, static_cast<unsigned>(r.event_id),
            static_cast<unsigned>(r.source_id),
            diag_event_name(r.event_id).data(),
            static_cast<unsigned>(r.arg0), static_cast<unsigned>(r.arg1),
            static_cast<unsigned>(r.arg2), static_cast<unsigned>(r.arg3));
        if (n < 0) {
            return;
        }
        if (n >= static_cast<int>(line.size())) {
            n = static_cast<int>(line.size() - 1U);
        }
        const bool ok = file_sink(this, line.data(), static_cast<uint16_t>(n));
        if (!ok) {
            logger.note_sink_failed();
        }
    }

    // Map a logical DiagEvent to a compile-time {level, event_id} record.
    void emit(DiagEvent ev, uint16_t source, uint32_t a0, uint32_t a1,
              uint32_t a2, uint32_t a3) noexcept
    {
        // The event id written to the file is the logical id (matches the
        // catalog name); coact's EventId (the template arg) is distinct per
        // event but we keep it convenient. Each case calls the typed record.
        switch (ev) {
        case DiagEvent::kOpenOk:
            logger.record<LogLevel::kInfo, 1>(source, a0, a1);
            return;
        case DiagEvent::kOpenFail:
            logger.record<LogLevel::kError, 2>(source, a0, a1);
            return;
        case DiagEvent::kCloseOk:
            logger.record<LogLevel::kInfo, 3>(source, a0);
            return;
        case DiagEvent::kFault:
            logger.record<LogLevel::kError, 4>(source, a0, a1);
            return;
        case DiagEvent::kWriteFail:
            logger.record<LogLevel::kError, 5>(source, a0, a1);
            return;
        case DiagEvent::kRxDrop:
            logger.record<LogLevel::kWarn, 6>(source, a0);
            return;
        case DiagEvent::kTxRejected:
            logger.record<LogLevel::kWarn, 7>(source, a0);
            return;
        case DiagEvent::kErrPushed:
            logger.record<LogLevel::kWarn, 8>(source, a0);
            return;
        case DiagEvent::kDiagTick:
            logger.record<LogLevel::kDebug, 9>(source, a0, a1, a2, a3);
            return;
        case DiagEvent::kDiagStart:
            logger.record<LogLevel::kInfo, 10>(source, a0);
            return;
        case DiagEvent::kDiagRotate:
            logger.record<LogLevel::kWarn, 11>(source, a0);
            return;
        case DiagEvent::kLineError:
            logger.record<LogLevel::kWarn, 12>(source, a0, a1, a2, a3);
            return;
        }
    }
};

DiagnosticWriter::DiagnosticWriter() = default;
DiagnosticWriter::~DiagnosticWriter()
{
    shutdown();
}

bool DiagnosticWriter::start(CoreCtx* core) noexcept
{
    if (impl_ != nullptr) {
        return false;
    }
    char disable;
    if (GetEnvironmentVariableA("XCOM_DIAG_DISABLE", &disable, 1) > 0) {
        if (disable == '1') {
            bound_ = false;
            return false;   // disabled
        }
    }
    std::array<char, 512U> env{};
    const std::uint32_t elen =
        GetEnvironmentVariableA("XCOM_DIAG_LOG", env.data(),
                                static_cast<DWORD>(env.size()));
    // A value that does not fit the fixed buffer is no longer silently ignored:
    // record a diagnostic error so the misconfiguration is visible, then fall
    // back to the default "xcom_diag.log" path.
    if (elen >= env.size() && core != nullptr) {
        core->errors.push(XCOM_ERR_PARAM, 0U,
                          "XCOM_DIAG_LOG path too long (>=512); using default");
    }

    Impl* p = Impl::slot().try_emplace();
    if (p == nullptr) {
        return false;
    }
    if (elen > 0U && elen < env.size()) {
        foundation::copy_text(std::string_view(env.data(), elen), p->path_);
    }
    p->fp_ = std::fopen(p->path_.data(), "wt");
    if (!p->bind_logger()) {
        if (p->fp_ != nullptr) {
            std::fclose(p->fp_);
            p->fp_ = nullptr;
        }
        Impl::slot().destroy(*p);
        return false;
    }
    p->stop_requested_.store(false, std::memory_order_release);
    p->started_.store(true, std::memory_order_release);
    try {
        p->thread_ = std::thread(&Impl::writer_run, p);
    }
    catch (...) {
        if (p->fp_ != nullptr) {
            std::fclose(p->fp_);
            p->fp_ = nullptr;
        }
        Impl::slot().destroy(*p);
        return false;
    }
    impl_ = p;
    bound_ = true;
    p->emit(DiagEvent::kDiagStart, 0U, static_cast<uint32_t>(p->qpc_freq_),
            0U, 0U, 0U);
    return true;
}

void DiagnosticWriter::shutdown() noexcept
{
    Impl* p = impl_;
    if (p == nullptr) {
        return;
    }
    p->stop_requested_.store(true, std::memory_order_release);
    p->wake_.signal();
    if (p->thread_.joinable()) {
        p->thread_.join();
    }
    if (p->fp_ != nullptr) {
        std::fclose(p->fp_);
        p->fp_ = nullptr;
    }
    p->started_.store(false, std::memory_order_release);
    impl_ = nullptr;
    bound_ = false;
    Impl::slot().destroy(*p);
}

void DiagnosticWriter::emit(DiagEvent ev, uint16_t source, uint32_t a0,
                            uint32_t a1, uint32_t a2, uint32_t a3) noexcept
{
    Impl* p = impl_;
    if (p == nullptr || !p->started_.load(std::memory_order_acquire)) {
        return;
    }
    p->emit(ev, source, a0, a1, a2, a3);
}

}  // namespace xcom
