#pragma once
#include <cstdint>

namespace gpu {

// Bind the host CAMetalLayer before calling gpu::CreateBackend()->Init().
// Passing as void* keeps this header includable from pure C++ files too.
void SetMetalLayer(void* ca_metal_layer);

// Monotonic count of frames presented by the Metal backend (used by the iOS FPS HUD).
uint32_t PresentedFrameCount();

}  // namespace gpu
