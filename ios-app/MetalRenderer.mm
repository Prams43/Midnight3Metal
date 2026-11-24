#import "MetalRenderer.h"
#include "core/log.h"
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#include <cmath>

MetalRenderer::MetalRenderer() {
    LOGI("MetalRenderer: Constructor called");
}

MetalRenderer::~MetalRenderer() {
    LOGI("MetalRenderer: Destructor called");
    // ARC handles cleanup of Metal objects
    device_ = nil;
    command_queue_ = nil;
    layer_ = nil;
}

bool MetalRenderer::Init(CAMetalLayer* layer) {
    if (!layer) {
        LOGE("MetalRenderer: CAMetalLayer is null");
        return false;
    }

    // Get default Metal device (GPU)
    device_ = MTLCreateSystemDefaultDevice();
    if (!device_) {
        LOGE("MetalRenderer: Failed to create Metal device (no GPU available)");
        return false;
    }

    LOGI("MetalRenderer: Metal device created: %s", [device_.name UTF8String]);

    // Create command queue for submitting work to GPU
    command_queue_ = [device_ newCommandQueue];
    if (!command_queue_) {
        LOGE("MetalRenderer: Failed to create command queue");
        device_ = nil;
        return false;
    }

    // Configure Metal layer
    layer_ = layer;
    layer_.device = device_;
    layer_.pixelFormat = MTLPixelFormatBGRA8Unorm;
    layer_.framebufferOnly = YES; // Optimize for rendering-only (no sampling)

    LOGI("MetalRenderer: Initialization complete");
    return true;
}

void MetalRenderer::Draw(double time) {
    if (!IsReady()) {
        LOGE("MetalRenderer: Draw called but renderer not ready");
        return;
    }

    // Get next drawable from layer
    id<CAMetalDrawable> drawable = [layer_ nextDrawable];
    if (!drawable) {
        LOGW("MetalRenderer: No drawable available this frame");
        return;
    }

    // Create command buffer for this frame
    id<MTLCommandBuffer> command_buffer = [command_queue_ commandBuffer];
    if (!command_buffer) {
        LOGE("MetalRenderer: Failed to create command buffer");
        return;
    }

    // Animate clear color: cycle through red -> green -> blue
    float hue = fmod(time * 0.2, 1.0); // Complete cycle every 5 seconds
    float r = 0.0f, g = 0.0f, b = 0.0f;

    if (hue < 1.0f / 3.0f) {
        // Red to Green
        r = 1.0f - (hue * 3.0f);
        g = hue * 3.0f;
    } else if (hue < 2.0f / 3.0f) {
        // Green to Blue
        g = 1.0f - ((hue - 1.0f / 3.0f) * 3.0f);
        b = (hue - 1.0f / 3.0f) * 3.0f;
    } else {
        // Blue to Red
        b = 1.0f - ((hue - 2.0f / 3.0f) * 3.0f);
        r = (hue - 2.0f / 3.0f) * 3.0f;
    }

    // Set up render pass to clear screen
    MTLRenderPassDescriptor* render_pass = [MTLRenderPassDescriptor renderPassDescriptor];
    render_pass.colorAttachments[0].texture = drawable.texture;
    render_pass.colorAttachments[0].loadAction = MTLLoadActionClear;
    render_pass.colorAttachments[0].clearColor = MTLClearColorMake(r, g, b, 1.0);
    render_pass.colorAttachments[0].storeAction = MTLStoreActionStore;

    // Create render command encoder (even though we're just clearing, this validates the pipeline)
    id<MTLRenderCommandEncoder> encoder = [command_buffer renderCommandEncoderWithDescriptor:render_pass];
    if (!encoder) {
        LOGE("MetalRenderer: Failed to create render encoder");
        return;
    }

    // No actual draw calls yet - just clearing
    [encoder endEncoding];

    // Present drawable to screen
    [command_buffer presentDrawable:drawable];

    // Submit command buffer to GPU
    [command_buffer commit];

    // Log first frame and every 5 seconds for debugging
    static double last_log_time = 0.0;
    if (time - last_log_time > 5.0 || last_log_time == 0.0) {
        LOGI("MetalRenderer: Frame rendered (time=%.2f, color=RGB(%.2f,%.2f,%.2f))", time, r, g, b);
        last_log_time = time;
    }
}
