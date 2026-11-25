#pragma once

namespace gpu {

// Bind the host CAMetalLayer before calling gpu::CreateBackend()->Init().
// Passing as void* keeps this header includable from pure C++ files too.
void SetMetalLayer(void* ca_metal_layer);

}  // namespace gpu
