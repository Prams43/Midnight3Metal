#pragma once
#include <cstdint>

namespace gpu {

// Bind the host CAMetalLayer before calling gpu::CreateBackend()->Init().
// Passing as void* keeps this header includable from pure C++ files too.
void SetMetalLayer(void* ca_metal_layer);

// Monotonic count of frames presented by the Metal backend (used by the iOS FPS HUD).
uint32_t PresentedFrameCount();

// Runtime graphics & HUD settings configurable from the iOS launcher and in-game HUD editor.
void SetResolutionScale(float scale);  // 1.0 (native), 1.5 (HD), 2.0 (Ultra)
float GetResolutionScale();

void SetAnisotropicFiltering(bool enabled);
bool GetAnisotropicFiltering();

void SetMotionBlurEnabled(bool enabled);  // false = crisp (default), true = original Xbox speed blur
bool GetMotionBlurEnabled();

void SetTargetFps(uint32_t fps);  // 60 or 30
uint32_t GetTargetFps();

// In-game Xbox minimap placement (normalized center 0..1 on screen, or default Xbox bottom-left).
struct MinimapConfig {
    bool visible = true;
    bool custom = false;  // false = default Xbox bottom-left position
    float norm_x = 0.14f;
    float norm_y = 0.78f;
};
void SetMinimapConfig(const MinimapConfig& cfg);
MinimapConfig GetMinimapConfig();

// Internal per-frame minimap transform reported by d3d8 SetViewport for Metal XYZRHW/rect shifting.
void ReportMinimapFrame(bool active, bool hidden, float orig_x, float orig_y, float orig_w, float orig_h, float dx, float dy);

}  // namespace gpu
