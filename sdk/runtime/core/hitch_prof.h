#pragma once

#include <atomic>
#include <chrono>
#include <cstdint>
#include <cstring>
#include <functional>
#include <mutex>
#include <thread>

#include "core/log.h"

namespace hitch {

inline uint64_t ThreadTag() {
    static const std::hash<std::thread::id> hasher;
    const uint64_t h = uint64_t(hasher(std::this_thread::get_id()));
    return h ? h : 1ull;
}

enum DsOpKind : uint8_t {
    kDsOther = 0,
    kDsDoWork = 1,
    kDsGetStatus = 2,
    kDsSetVolume = 3,
    kDsFlushEx = 4,
    kDsDiscontinuity = 5,
    kDsProcess = 6,
    kDsPause = 7,
    kDsRelease = 8,
    kDsCount = 9
};

struct State {
    std::atomic<uint64_t> main_tid{0};
    std::atomic<uint64_t> io_us{0};
    std::atomic<uint64_t> io_bytes{0};
    std::atomic<uint32_t> io_ops{0};
    std::atomic<uint64_t> main_wait_us{0};
    std::atomic<uint32_t> main_wait_caller{0};
    std::atomic<uint32_t> main_wait_kind{0};  // 1=Wait, 2=Delay, 3=CS
    std::atomic<uint64_t> bg_wait_us{0};
    std::atomic<uint64_t> main_stall_us{0};
    std::atomic<uint32_t> main_stall_ops{0};
    std::atomic<uint32_t> main_stall_caller{0};
    std::atomic<uint32_t> main_yield_ops{0};
    std::atomic<uint32_t> main_yield_caller{0};
    std::atomic<uint32_t> main_apu_ops{0};
    std::atomic<uint32_t> main_qpc_ops{0};
    std::atomic<uint32_t> main_irq_ops{0};
    std::atomic<uint32_t> ds_buf_ops{0};
    std::atomic<uint32_t> ds_buf_caller{0};
    std::atomic<uint64_t> dsound_us{0};
    std::atomic<uint32_t> dsound_ops{0};
    std::atomic<uint32_t> dsound_main_ops{0};
    std::atomic<uint32_t> ds_kind_ops[kDsCount]{};
    std::atomic<uint32_t> ds_kind_caller[kDsCount]{};
    std::atomic<const char*> dsound_last_op{nullptr};
    std::atomic<uint32_t> dsound_last_caller{0};
    std::atomic<uint64_t> render_wait_us{0};
    std::atomic<uint64_t> metal_compile_us{0};
    std::atomic<uint64_t> metal_tex_us{0};
    std::atomic<uint64_t> d3d_flush_us{0};

    std::mutex file_lock;
    char slow_file[64]{};
    uint64_t slow_file_us = 0;

    std::atomic<uint32_t> frame_num{0};
    std::atomic<uint32_t> logged{0};
};

inline State& Get() {
    static State s;
    return s;
}

inline uint64_t NowUs() {
    using namespace std::chrono;
    return uint64_t(duration_cast<microseconds>(steady_clock::now().time_since_epoch()).count());
}

inline bool IsMainThread() {
    const uint64_t mt = Get().main_tid.load(std::memory_order_relaxed);
    return mt != 0 && mt == ThreadTag();
}

inline DsOpKind ClassifyDsOp(const char* op) {
    if (!op) return kDsOther;
    if (std::strcmp(op, "DoWork") == 0) return kDsDoWork;
    if (std::strcmp(op, "GetStatus") == 0) return kDsGetStatus;
    if (std::strcmp(op, "SetVolume") == 0) return kDsSetVolume;
    if (std::strcmp(op, "FlushEx") == 0 || std::strcmp(op, "FlushExC") == 0 || std::strcmp(op, "Flush") == 0) return kDsFlushEx;
    if (std::strcmp(op, "Discontinuity") == 0) return kDsDiscontinuity;
    if (std::strcmp(op, "Process") == 0) return kDsProcess;
    if (std::strcmp(op, "Pause") == 0) return kDsPause;
    if (std::strcmp(op, "Release") == 0) return kDsRelease;
    return kDsOther;
}

inline void AddIo(uint64_t us, uint32_t bytes, const char* path = nullptr) {
    auto& s = Get();
    s.io_us.fetch_add(us, std::memory_order_relaxed);
    s.io_bytes.fetch_add(bytes, std::memory_order_relaxed);
    s.io_ops.fetch_add(1, std::memory_order_relaxed);
    if (path && *path && us >= 500) {
        std::lock_guard<std::mutex> lk(s.file_lock);
        if (us >= s.slow_file_us) {
            s.slow_file_us = us;
            const char* base = path;
            for (const char* p = path; *p; ++p) {
                if (*p == '\\' || *p == '/') base = p + 1;
            }
            size_t len = std::strlen(base);
            if (len >= sizeof(s.slow_file)) len = sizeof(s.slow_file) - 1;
            std::memcpy(s.slow_file, base, len);
            s.slow_file[len] = '\0';
        }
    }
}

inline void AddWait(uint64_t us, uint32_t kind, uint32_t caller = 0) {
    if (!us) return;
    auto& s = Get();
    if (IsMainThread()) {
        s.main_wait_us.fetch_add(us, std::memory_order_relaxed);
        if (us >= 500) {
            s.main_wait_kind.store(kind, std::memory_order_relaxed);
            if (caller) s.main_wait_caller.store(caller, std::memory_order_relaxed);
        }
    } else {
        s.bg_wait_us.fetch_add(us, std::memory_order_relaxed);
    }
}

inline void AddStall(uint64_t us, uint32_t caller = 0) {
    if (!IsMainThread()) return;
    auto& s = Get();
    s.main_stall_us.fetch_add(us, std::memory_order_relaxed);
    s.main_stall_ops.fetch_add(1, std::memory_order_relaxed);
    if (caller) s.main_stall_caller.store(caller, std::memory_order_relaxed);
}

inline void AddYield(uint32_t caller = 0) {
    if (!IsMainThread()) return;
    auto& s = Get();
    s.main_yield_ops.fetch_add(1, std::memory_order_relaxed);
    if (caller) s.main_yield_caller.store(caller, std::memory_order_relaxed);
}

inline void AddApuRead() {
    if (IsMainThread()) Get().main_apu_ops.fetch_add(1, std::memory_order_relaxed);
}

inline void AddQpcRead() {
    if (IsMainThread()) Get().main_qpc_ops.fetch_add(1, std::memory_order_relaxed);
}

inline void AddIrqRead() {
    if (IsMainThread()) Get().main_irq_ops.fetch_add(1, std::memory_order_relaxed);
}

inline void AddDsBuf(uint32_t caller = 0) {
    if (!IsMainThread()) return;
    auto& s = Get();
    s.ds_buf_ops.fetch_add(1, std::memory_order_relaxed);
    if (caller) s.ds_buf_caller.store(caller, std::memory_order_relaxed);
}

inline void AddDSound(uint64_t us, const char* op = nullptr, uint32_t caller = 0) {
    auto& s = Get();
    s.dsound_us.fetch_add(us, std::memory_order_relaxed);
    s.dsound_ops.fetch_add(1, std::memory_order_relaxed);
    if (IsMainThread()) {
        s.dsound_main_ops.fetch_add(1, std::memory_order_relaxed);
        const DsOpKind k = ClassifyDsOp(op);
        s.ds_kind_ops[k].fetch_add(1, std::memory_order_relaxed);
        if (caller) s.ds_kind_caller[k].store(caller, std::memory_order_relaxed);
    }
    if (op) s.dsound_last_op.store(op, std::memory_order_relaxed);
    if (caller) s.dsound_last_caller.store(caller, std::memory_order_relaxed);
}

inline void AddRenderWait(uint64_t us) {
    Get().render_wait_us.fetch_add(us, std::memory_order_relaxed);
}

inline void AddMetalCompile(uint64_t us) {
    Get().metal_compile_us.fetch_add(us, std::memory_order_relaxed);
}

inline void AddMetalTex(uint64_t us) {
    Get().metal_tex_us.fetch_add(us, std::memory_order_relaxed);
}

inline void AddD3dFlush(uint64_t us) {
    Get().d3d_flush_us.fetch_add(us, std::memory_order_relaxed);
}

inline void OnFrameSwap() {
    static std::atomic<uint64_t> prev_us{0};
    auto& s = Get();
    if (s.main_tid.load(std::memory_order_relaxed) == 0) {
        s.main_tid.store(ThreadTag(), std::memory_order_relaxed);
    }
    const uint64_t now = NowUs();
    const uint64_t last = prev_us.exchange(now, std::memory_order_relaxed);
    const uint32_t fn = s.frame_num.fetch_add(1, std::memory_order_relaxed) + 1;

    const uint64_t io_us = s.io_us.exchange(0, std::memory_order_relaxed);
    const uint64_t io_bytes = s.io_bytes.exchange(0, std::memory_order_relaxed);
    const uint32_t io_ops = s.io_ops.exchange(0, std::memory_order_relaxed);
    const uint64_t mw_us = s.main_wait_us.exchange(0, std::memory_order_relaxed);
    const uint32_t mw_caller = s.main_wait_caller.exchange(0, std::memory_order_relaxed);
    const uint32_t mw_kind = s.main_wait_kind.exchange(0, std::memory_order_relaxed);
    const uint64_t bgw_us = s.bg_wait_us.exchange(0, std::memory_order_relaxed);
    const uint64_t stall_us = s.main_stall_us.exchange(0, std::memory_order_relaxed);
    const uint32_t stall_ops = s.main_stall_ops.exchange(0, std::memory_order_relaxed);
    const uint32_t stall_caller = s.main_stall_caller.exchange(0, std::memory_order_relaxed);
    const uint32_t yld_ops = s.main_yield_ops.exchange(0, std::memory_order_relaxed);
    const uint32_t yld_caller = s.main_yield_caller.exchange(0, std::memory_order_relaxed);
    const uint32_t apu_ops = s.main_apu_ops.exchange(0, std::memory_order_relaxed);
    const uint32_t qpc_ops = s.main_qpc_ops.exchange(0, std::memory_order_relaxed);
    const uint32_t irq_ops = s.main_irq_ops.exchange(0, std::memory_order_relaxed);
    const uint32_t ds_buf_ops = s.ds_buf_ops.exchange(0, std::memory_order_relaxed);
    const uint32_t ds_buf_caller = s.ds_buf_caller.exchange(0, std::memory_order_relaxed);
    const uint64_t ds_us = s.dsound_us.exchange(0, std::memory_order_relaxed);
    const uint32_t ds_ops = s.dsound_ops.exchange(0, std::memory_order_relaxed);
    const uint32_t ds_mops = s.dsound_main_ops.exchange(0, std::memory_order_relaxed);
    uint32_t dk[kDsCount]{}, dc[kDsCount]{};
    for (int i = 0; i < kDsCount; ++i) {
        dk[i] = s.ds_kind_ops[i].exchange(0, std::memory_order_relaxed);
        dc[i] = s.ds_kind_caller[i].exchange(0, std::memory_order_relaxed);
    }
    const char* ds_op = s.dsound_last_op.exchange(nullptr, std::memory_order_relaxed);
    const uint32_t ds_caller = s.dsound_last_caller.exchange(0, std::memory_order_relaxed);
    const uint64_t rw_us = s.render_wait_us.exchange(0, std::memory_order_relaxed);
    const uint64_t msl_us = s.metal_compile_us.exchange(0, std::memory_order_relaxed);
    const uint64_t tex_us = s.metal_tex_us.exchange(0, std::memory_order_relaxed);
    const uint64_t fl_us = s.d3d_flush_us.exchange(0, std::memory_order_relaxed);

    char file_copy[64] = "-";
    {
        std::lock_guard<std::mutex> lk(s.file_lock);
        if (s.slow_file[0]) std::memcpy(file_copy, s.slow_file, sizeof(file_copy));
        s.slow_file[0] = '\0';
        s.slow_file_us = 0;
    }

    if (!last || fn <= 120) return;
    const uint64_t frame_us = now > last ? (now - last) : 0;
    if (frame_us < 45000) return;
    const uint32_t n = s.logged.fetch_add(1, std::memory_order_relaxed) + 1;
    if (n > 160) return;

    const uint64_t accounted = io_us + mw_us + stall_us + ds_us + rw_us;
    const uint64_t guest_us = frame_us > accounted ? (frame_us - accounted) : 0;
    const char* wk = mw_kind == 1 ? "Wait" : mw_kind == 2 ? "Delay" : mw_kind == 3 ? "CS" : "-";
    LOGR("HITCH #%u total=%.1fms io=%.1fms(%u/%uKB/%s) mw=%.1fms(%s@%08X) stall=%.1fms(%u@%08X) yld=%u@%08X apu=%u qpc=%u irq=%u ds=%.1fms(%u/m%u/%s@%08X) gpu_w=%.1fms msl=%.1fms tex=%.1fms guest=%.1fms",
         n, frame_us / 1000.0, io_us / 1000.0, io_ops, unsigned(io_bytes >> 10), file_copy,
         mw_us / 1000.0, wk, mw_caller,
         stall_us / 1000.0, stall_ops, stall_caller,
         yld_ops, yld_caller, apu_ops, qpc_ops, irq_ops,
         ds_us / 1000.0, ds_ops, ds_mops, ds_op ? ds_op : "-", ds_caller,
         rw_us / 1000.0, msl_us / 1000.0, tex_us / 1000.0, guest_us / 1000.0);
    if (ds_mops >= 16) {
        LOGR("HITCH #%u DS_BREAKDOWN dw=%u@%08X gs=%u@%08X sv=%u@%08X fx=%u@%08X dc=%u@%08X pr=%u@%08X pa=%u@%08X rl=%u@%08X oth=%u@%08X buf=%u@%08X bgw=%.1fms fl=%.1fms",
             n,
             dk[kDsDoWork], dc[kDsDoWork],
             dk[kDsGetStatus], dc[kDsGetStatus],
             dk[kDsSetVolume], dc[kDsSetVolume],
             dk[kDsFlushEx], dc[kDsFlushEx],
             dk[kDsDiscontinuity], dc[kDsDiscontinuity],
             dk[kDsProcess], dc[kDsProcess],
             dk[kDsPause], dc[kDsPause],
             dk[kDsRelease], dc[kDsRelease],
             dk[kDsOther], dc[kDsOther],
             ds_buf_ops, ds_buf_caller,
             bgw_us / 1000.0, fl_us / 1000.0);
    }
}

}  // namespace hitch
