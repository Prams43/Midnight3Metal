// Stub definitions for the ios-app target.
// The full implementations live in the game binary (app/, etc).
// These stubs satisfy the linker for input.cpp, which calls app::kGame.pad / rumble.
#include "app/app.h"
#include "gpu/metal.h"
#include "gpu/render_profile.h"

#include <chrono>
#include <thread>

namespace xnet {
void CloseSockets() {}
}  // namespace xnet

namespace gpu::render {
const Config& Get() {
    static const Config c{};
    return c;
}
bool MotionBlurTuneReady() { return false; }
void MarkMotionBlurTuneReady() {}
}  // namespace gpu::render

namespace app {

#ifndef MC3_HAS_RECOMPILED_GAME
// Minimal kGame stub: no callbacks, no title, no assets.
// Replaced by src/common/game_info.cpp when recompiled game code is linked.
const GameInfo kGame = {
    .title        = L"MC3 iOS",
    .short_title  = L"MC3",
    .name         = L"mc3ios",
    .log          = "mc3ios",
    .settings     = "mc3ios.toml",
    .splash       = nullptr,
    .missing      = L"Game files not found",
    .images       = {},
    .options      = {},
    .load         = nullptr,
    .save         = nullptr,
    .init         = nullptr,
    .loaded       = nullptr,
    .window       = nullptr,
    .message      = nullptr,
    .ui           = nullptr,
    .pad          = nullptr,  // no game pad callback yet
    .rumble       = nullptr,  // no game rumble callback yet
    .transform    = nullptr,
};
#endif

// Stub for functions referenced from app/app.h but not needed in ios-app yet
Settings& Get() {
    static Settings s;
    return s;
}

bool Widescreen() { return true; }
void Pace() {
    const uint32_t cap = gpu::GetTargetFps();
    if (cap > 0 && cap < 60) {
        using clock = std::chrono::steady_clock;
        static auto next = clock::now();
        const auto period = std::chrono::microseconds(1000000u / cap);
        const auto now = clock::now();
        next = std::max(next + period, now);
        std::this_thread::sleep_until(next);
    }
}
void SplashFirstFrame() {}
bool HandingOver() { return false; }
void FinishHandover() {}

}  // namespace app
