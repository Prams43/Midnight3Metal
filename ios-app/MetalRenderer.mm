#import "MetalRenderer.h"
#include "core/log.h"
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#include <cmath>
#include <simd/simd.h>

// Vertex structure: position (x,y) + color (r,g,b,a)
struct Vertex {
    simd_float2 position;
    simd_float4 color;
};

// Metal Shading Language shader source (compiled at runtime)
static const char* kShaderSource = R"(
#include <metal_stdlib>
using namespace metal;

struct VertexIn {
    float2 position [[attribute(0)]];
    float4 color [[attribute(1)]];
};

struct VertexOut {
    float4 position [[position]];
    float4 color;
};

vertex VertexOut vertex_main(VertexIn in [[stage_in]]) {
    VertexOut out;
    out.position = float4(in.position, 0.0, 1.0);
    out.color = in.color;
    return out;
}

fragment float4 fragment_main(VertexOut in [[stage_in]]) {
    return in.color;
}
)";

MetalRenderer::MetalRenderer() {
    LOGI("MetalRenderer: Constructor called");
}

MetalRenderer::~MetalRenderer() {
    LOGI("MetalRenderer: Destructor called");
    // ARC handles cleanup of Metal objects
    device_ = nil;
    command_queue_ = nil;
    pipeline_state_ = nil;
    vertex_buffer_ = nil;
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
    layer_.framebufferOnly = YES;

    // Create rendering pipeline and geometry
    if (!CreatePipeline()) {
        LOGE("MetalRenderer: Failed to create pipeline");
        device_ = nil;
        command_queue_ = nil;
        return false;
    }

    if (!CreateVertexBuffer()) {
        LOGE("MetalRenderer: Failed to create vertex buffer");
        device_ = nil;
        command_queue_ = nil;
        pipeline_state_ = nil;
        return false;
    }

    LOGI("MetalRenderer: Initialization complete");
    return true;
}

bool MetalRenderer::CreatePipeline() {
    NSError* error = nil;

    // Compile shader source
    id<MTLLibrary> library = [device_ newLibraryWithSource:@(kShaderSource)
                                                   options:nil
                                                     error:&error];
    if (!library) {
        LOGE("MetalRenderer: Shader compilation failed: %s", [[error localizedDescription] UTF8String]);
        return false;
    }

    id<MTLFunction> vertex_func = [library newFunctionWithName:@"vertex_main"];
    id<MTLFunction> fragment_func = [library newFunctionWithName:@"fragment_main"];

    if (!vertex_func || !fragment_func) {
        LOGE("MetalRenderer: Failed to find shader functions");
        return false;
    }

    // Setup vertex descriptor
    MTLVertexDescriptor* vertex_desc = [[MTLVertexDescriptor alloc] init];

    // Attribute 0: position (float2)
    vertex_desc.attributes[0].format = MTLVertexFormatFloat2;
    vertex_desc.attributes[0].offset = 0;
    vertex_desc.attributes[0].bufferIndex = 0;

    // Attribute 1: color (float4)
    vertex_desc.attributes[1].format = MTLVertexFormatFloat4;
    vertex_desc.attributes[1].offset = sizeof(simd_float2);
    vertex_desc.attributes[1].bufferIndex = 0;

    // Buffer layout
    vertex_desc.layouts[0].stride = sizeof(Vertex);
    vertex_desc.layouts[0].stepFunction = MTLVertexStepFunctionPerVertex;

    // Create pipeline state
    MTLRenderPipelineDescriptor* pipeline_desc = [[MTLRenderPipelineDescriptor alloc] init];
    pipeline_desc.vertexFunction = vertex_func;
    pipeline_desc.fragmentFunction = fragment_func;
    pipeline_desc.vertexDescriptor = vertex_desc;
    pipeline_desc.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;

    pipeline_state_ = [device_ newRenderPipelineStateWithDescriptor:pipeline_desc error:&error];
    if (!pipeline_state_) {
        LOGE("MetalRenderer: Failed to create pipeline state: %s", [[error localizedDescription] UTF8String]);
        return false;
    }

    LOGI("MetalRenderer: Pipeline created successfully");
    return true;
}

bool MetalRenderer::CreateVertexBuffer() {
    // Triangle vertices: centered, normalized device coordinates
    // Top vertex (red), bottom-left (green), bottom-right (blue)
    const Vertex vertices[] = {
        {{  0.0f,  0.5f }, { 1.0f, 0.0f, 0.0f, 1.0f }}, // Top - red
        {{ -0.5f, -0.5f }, { 0.0f, 1.0f, 0.0f, 1.0f }}, // Bottom-left - green
        {{  0.5f, -0.5f }, { 0.0f, 0.0f, 1.0f, 1.0f }}  // Bottom-right - blue
    };

    vertex_buffer_ = [device_ newBufferWithBytes:vertices
                                          length:sizeof(vertices)
                                         options:MTLResourceStorageModeShared];
    if (!vertex_buffer_) {
        LOGE("MetalRenderer: Failed to create vertex buffer");
        return false;
    }

    LOGI("MetalRenderer: Vertex buffer created (3 vertices)");
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

    // Set up render pass with black clear
    MTLRenderPassDescriptor* render_pass = [MTLRenderPassDescriptor renderPassDescriptor];
    render_pass.colorAttachments[0].texture = drawable.texture;
    render_pass.colorAttachments[0].loadAction = MTLLoadActionClear;
    render_pass.colorAttachments[0].clearColor = MTLClearColorMake(0.0, 0.0, 0.0, 1.0);
    render_pass.colorAttachments[0].storeAction = MTLStoreActionStore;

    // Create render command encoder
    id<MTLRenderCommandEncoder> encoder = [command_buffer renderCommandEncoderWithDescriptor:render_pass];
    if (!encoder) {
        LOGE("MetalRenderer: Failed to create render encoder");
        return;
    }

    // Set pipeline and draw triangle
    [encoder setRenderPipelineState:pipeline_state_];
    [encoder setVertexBuffer:vertex_buffer_ offset:0 atIndex:0];
    [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];

    [encoder endEncoding];

    // Present drawable to screen
    [command_buffer presentDrawable:drawable];

    // Submit command buffer to GPU
    [command_buffer commit];

    // Log first frame and every 5 seconds
    static double last_log_time = 0.0;
    if (time - last_log_time > 5.0 || last_log_time == 0.0) {
        LOGI("MetalRenderer: Triangle rendered (time=%.2f)", time);
        last_log_time = time;
    }
}
