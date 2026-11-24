#pragma once
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>

class MetalRenderer {
public:
    MetalRenderer();
    ~MetalRenderer();

    bool Init(CAMetalLayer* layer);
    void Draw(double time);
    bool IsReady() const { return device_ != nil && command_queue_ != nil; }

private:
    bool CreatePipeline();
    bool CreateVertexBuffer();

    id<MTLDevice> device_ = nil;
    id<MTLCommandQueue> command_queue_ = nil;
    id<MTLRenderPipelineState> pipeline_state_ = nil;
    id<MTLBuffer> vertex_buffer_ = nil;
    CAMetalLayer* layer_ = nil;
};
