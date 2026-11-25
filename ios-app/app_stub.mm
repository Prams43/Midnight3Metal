// Stub definitions for the ios-app target.
// The full implementations live in the game binary (app/, etc).
// These stubs satisfy the linker for input.cpp, which calls app::kGame.pad / rumble.
#include "app/app.h"
#include "gpu/render_profile.h"

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

// Minimal kGame stub: no callbacks, no title, no assets.
// Replace with the real game's GameInfo once game code is linked.
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

// Stub for functions referenced from app/app.h but not needed in ios-app yet
Settings& Get() {
    static Settings s;
    return s;
}

bool Widescreen() { return true; }
void Pace() {}
void SplashFirstFrame() {}
bool HandingOver() { return false; }
void FinishHandover() {}

}  // namespace app
