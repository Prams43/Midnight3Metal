#pragma once

#include <atomic>
#include <chrono>
#include <cstdint>
#include <cstring>
#include <mutex>

#include "core/log.h"

namespace hitch {

struct State {
    std::atomic<uint64_t> io_us{0};
    std::atomic<uint64_t> io_bytes{0};
    std::atomic<uint32_t> io_ops{0};
    std::atomic<uint64_t> wait_us{0};
    std::atomic<uint32_t> wait_caller{0};
    std::atomic<uint32_t> wait_kind{0};  // 1=Wait, 2=Delay, 3=CS
    std::atomic<uint64_t> dsound_us{0};
    std::atomic<uint32_t> dsound_ops{0};
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
    s.wait_us.fetch_add(us, std::memory_order_relaxed);
    if (us >= 1000) {
        s.wait_kind.store(kind, std::memory_order_relaxed);
        if (caller) s.wait_caller.store(caller, std::memory_order_relaxed);
    }
}

inline void AddDSound(uint64_t us) {
    auto& s = Get();
    s.dsound_us.fetch_add(us, std::memory_order_relaxed);
    s.dsound_ops.fetch_add(1, std::memory_order_relaxed);
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
    const uint64_t now = NowUs();
    const uint64_t last = prev_us.exchange(now, std::memory_order_relaxed);
    auto& s = Get();
    const uint32_t fn = s.frame_num.fetch_add(1, std::memory_order_relaxed) + 1;

    const uint64_t io_us = s.io_us.exchange(0, std::memory_order_relaxed);
    const uint64_t io_bytes = s.io_bytes.exchange(0, std::memory_order_relaxed);
    const uint32_t io_ops = s.io_ops.exchange(0, std::memory_order_relaxed);
    const uint64_t wait_us = s.wait_us.exchange(0, std::memory_order_relaxed);
    const uint32_t wait_caller = s.wait_caller.exchange(0, std::memory_order_relaxed);
    const uint32_t wait_kind = s.wait_kind.exchange(0, std::memory_order_relaxed);
    const uint64_t ds_us = s.dsound_us.exchange(0, std::memory_order_relaxed);
    const uint32_t ds_ops = s.dsound_ops.exchange(0, std::memory_order_relaxed);
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
    if (n > 80) return;

    const uint64_t accounted = io_us + wait_us + ds_us + rw_us;
    const uint64_t guest_us = frame_us > accounted ? (frame_us - accounted) : 0;
    const char* wk = wait_kind == 1 ? "Wait" : wait_kind == 2 ? "Delay" : wait_kind == 3 ? "CS" : "-";
    LOGR("HITCH #%u total=%.1fms io=%.1fms(%u/%uKB/%s) wait=%.1fms(%s@%08X) ds=%.1fms(%u) gpu_w=%.1fms msl=%.1fms tex=%.1fms fl=%.1fms guest=%.1fms",
         n, frame_us / 1000.0, io_us / 1000.0, io_ops, unsigned(io_bytes >> 10), file_copy,
         wait_us / 1000.0, wk, wait_caller, ds_us / 1000.0, ds_ops,
         rw_us / 1000.0, msl_us / 1000.0, tex_us / 1000.0, fl_us / 1000.0, guest_us / 1000.0);
}

}  // namespace hitch
