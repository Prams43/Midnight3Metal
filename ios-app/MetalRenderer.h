#pragma once
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>

// Basic Metal renderer for iOS app host.
// This is a minimal clear-screen renderer to verify Metal pipeline works.
// Game rendering will be added incrementally after this foundation is validated.
class MetalRenderer {
public:
    MetalRenderer();
    ~MetalRenderer();

    // Initialize Metal with the drawable layer from the view
    bool Init(CAMetalLayer* layer);

    // Draw one frame - clears screen with animated color
    void Draw(double time);

    // Returns whether Metal is available and initialized
    bool IsReady() const { return device_ != nil && command_queue_ != nil; }

private:
    id<MTLDevice> device_ = nil;
    id<MTLCommandQueue> command_queue_ = nil;
    CAMetalLayer* layer_ = nil;
};
