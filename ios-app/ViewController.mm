#import "ViewController.h"
#import "app/ios_touch_controls.h"
#import "MC3DebugOverlay.h"
#include "audio/audio.h"
#include "core/input.h"
#include "core/log.h"
#include "gpu/backend.h"
#include "gpu/metal.h"
#include "kernel/memory.h"
#import <QuartzCore/CAMetalLayer.h>
#include <atomic>
#include <cstring>
#include <memory>

static std::atomic<uint64_t> g_audioFrames{0};

// Bridge: redirect logx::Write output to the on-screen debug overlay.
// Called from a C-linkage shim installed at app startup.
static void OverlayLogLine(const char* line) {
    NSString* s = [NSString stringWithUTF8String:line ?: ""];
    // Trim trailing newline for display
    s = [s stringByTrimmingCharactersInSet:[NSCharacterSet newlineCharacterSet]];
    if (s.length > 0) [MC3DebugOverlay log:s];
}

@interface ViewController ()
@property (strong, nonatomic) UIView* touchControlsOverlay;
@property (strong, nonatomic) CADisplayLink* displayLink;
@property (nonatomic) double startTime;
@property (strong, nonatomic) MC3DebugOverlay* debugOverlay;
@end

@implementation ViewController {
    std::unique_ptr<gpu::Backend> _gpuBackend;
    std::unique_ptr<gpu::State> _testState;
    uint32_t _testVbHeader;
    uint32_t _testVbData;
}

+ (Class)layerClass {
    return [CAMetalLayer class];
}

- (void)loadView {
    // Create view with explicit CAMetalLayer backing
    // +layerClass only works for UIView subclasses, not runtime instances
    UIView* metalView = [[UIView alloc] initWithFrame:[UIScreen mainScreen].bounds];

    // Replace default CALayer with CAMetalLayer
    CAMetalLayer* metalLayer = [CAMetalLayer layer];
    metalLayer.frame = metalView.bounds;
    metalLayer.contentsScale = [UIScreen mainScreen].scale;

    // Remove default layer and set metal layer as backing
    [metalView.layer addSublayer:metalLayer];

    self.view = metalView;
}

- (void)viewDidLoad {
    [super viewDidLoad];

    self.view.backgroundColor = [UIColor blackColor];
    self.startTime = CACurrentMediaTime();

    // Initialize logging subsystem inside the app sandbox's tmp directory
    NSString* tmpDir = NSTemporaryDirectory();
    logx::Init(tmpDir ? [tmpDir UTF8String] : "/tmp", "mc3ios");
    LOGI("MC3 iOS Host: UIKit app host started");

    // Initialize input subsystem (SDL gamepad + virtual controls)
    input::Init();
    LOGI("MC3 iOS Host: Input subsystem initialized");

    // Initialize and smoke-test portable guest memory (4 GiB virtual + shared physical alias)
    if (mem::Init()) {
        uint8_t* base = mem::Base();
        const uint32_t va = mem::AllocContiguous(4096, 0, mem::PhysicalSize() - 1, 4096);
        bool aliasOk = false;
        if (va) {
            const uint32_t wcVa = (va - mem::kContiguousBase) + mem::kWriteCombineBase;
            auto* pContig = reinterpret_cast<volatile uint32_t*>(base + va);
            auto* pWc = reinterpret_cast<volatile uint32_t*>(base + wcVa);
            *pContig = 0x12345678u;
            aliasOk = (*pWc == 0x12345678u);
            mem::FreeContiguous(va);
        }
        NSString* memMsg = [NSString stringWithFormat:@"[MEM] base=%p alias=%s",
                            static_cast<void*>(base), aliasOk ? "PASS" : "FAIL"];
        [MC3DebugOverlay log:memMsg];
        LOGI("%s", [memMsg UTF8String]);
    } else {
        [MC3DebugOverlay log:@"[MEM] Init FAILED"];
        LOGE("MC3 iOS Host: mem::Init failed");
    }

    // Initialize Apple Audio Queue output (silent callback to verify audio thread pulls buffers)
    audio::StartOutput([](float* out, uint32_t frames) {
        std::memset(out, 0, static_cast<size_t>(frames) * 2 * sizeof(float));
        g_audioFrames.fetch_add(frames, std::memory_order_relaxed);
    });
    [MC3DebugOverlay log:@"[AUDIO] AudioQueue started"];

    // Initialize Metal renderer - get metal layer from sublayers
    CAMetalLayer* metalLayer = nil;
    for (CALayer* layer in self.view.layer.sublayers) {
        if ([layer isKindOfClass:[CAMetalLayer class]]) {
            metalLayer = (CAMetalLayer*)layer;
            break;
        }
    }

    if (!metalLayer) {
        LOGE("MC3 iOS Host: CAMetalLayer not found in view");
        return;
    }

    // Initialize Metal gpu::Backend
    gpu::SetMetalLayer((__bridge void*)metalLayer);
    _gpuBackend = gpu::CreateBackend();
    if (!_gpuBackend || !_gpuBackend->Init(640, 480)) {
        _gpuBackend.reset();
        LOGE("MC3 iOS Host: Failed to initialize gpu::Backend (Metal)");
        [MC3DebugOverlay log:@"[GPU] MetalBackend FAILED"];
    } else {
        LOGI("MC3 iOS Host: gpu::Backend (Metal) initialized");
        [MC3DebugOverlay log:@"[GPU] MetalBackend ready (640x480)"];

        // Build a minimal pretransformed (XYZRHW | DIFFUSE) triangle in guest memory
        if (mem::Base()) {
            struct GuestVert { float x, y, z, rhw; uint32_t color; };
            _testVbData = mem::AllocContiguous(sizeof(GuestVert) * 3, 0, mem::PhysicalSize() - 1, 16);
            _testVbHeader = mem::AllocSystem(20, 16);
            if (_testVbData && _testVbHeader) {
                auto* v = reinterpret_cast<GuestVert*>(mem::Base() + _testVbData);
                v[0] = {320.0f, 120.0f, 0.0f, 1.0f, 0xFFFF3333u};
                v[1] = {160.0f, 360.0f, 0.0f, 1.0f, 0xFF33FF33u};
                v[2] = {480.0f, 360.0f, 0.0f, 1.0f, 0xFF3388FFu};
                auto* hdr = reinterpret_cast<uint32_t*>(mem::Base() + _testVbHeader);
                hdr[0] = 0;
                hdr[1] = mem::PhysicalFromVirtual(_testVbData);
                hdr[2] = 0;
                hdr[3] = 0;
                hdr[4] = sizeof(GuestVert) * 3;
                _testState = std::make_unique<gpu::State>();
                _testState->vs_handle = 0x44;  // D3DFVF_XYZRHW | D3DFVF_DIFFUSE
                _testState->streams[0] = {_testVbHeader, sizeof(GuestVert)};
            }
        }
    }

    // Create and add touch controls overlay
    self.touchControlsOverlay = app::CreateTouchControlsOverlay(self.view.bounds);
    if (self.touchControlsOverlay) {
        [self.view addSubview:self.touchControlsOverlay];
        LOGI("MC3 iOS Host: Touch controls overlay initialized");
    } else {
        LOGE("MC3 iOS Host: Failed to create touch controls overlay");
    }

    // Add debug overlay on top of everything (Windows devs: no Mac/Xcode needed)
    self.debugOverlay = [MC3DebugOverlay sharedOverlay];
    self.debugOverlay.frame = self.view.bounds;
    self.debugOverlay.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:self.debugOverlay];
    [MC3DebugOverlay log:@"[MC3] Debug overlay ready. Tap top-left to hide."];

    // Set up game loop using CADisplayLink (synced to display refresh rate)
    self.displayLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(gameLoopTick:)];
    [self.displayLink addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];

    LOGI("MC3 iOS Host: Display link game loop started");
    [MC3DebugOverlay log:@"[MC3] App started. Metal + Input + Loop ready."];
}

- (void)gameLoopTick:(CADisplayLink*)displayLink {
    double currentTime = CACurrentMediaTime() - self.startTime;

    // Render frame through gpu::Backend
    if (_gpuBackend) {
        gpu::State clearState;
        _gpuBackend->Clear(clearState, 0, nullptr, gpu::kClearTarget, 0xFF0A1020u, 1.0f, 0);
        if (_testState) {
            _gpuBackend->Draw(*_testState, 4 /* D3DPT_TRIANGLELIST */, 0, 1, nullptr);
        }
        gpu::Surface front{};
        _gpuBackend->Present(front);
    }

    // Log once per second: game loop heartbeat + input state
    static int tickCount = 0;
    tickCount++;
    if (tickCount == 60) {
        LOGD("MC3 iOS Host: Game loop active (60 ticks, time=%.2f)", currentTime);

        // Poll port 0 to verify touch overlay → input routing
        input::Pad pad = input::Poll(0);
        if (pad.connected) {
            NSString* padStr = [NSString stringWithFormat:
                @"[PAD] btn=%04X A=%d B=%d X=%d Y=%d L=%d R=%d lx=%d ly=%d",
                pad.buttons,
                pad.analog[0], pad.analog[1], pad.analog[2], pad.analog[3],
                pad.analog[4], pad.analog[5],
                (int)pad.lx, (int)pad.ly];
            [MC3DebugOverlay log:padStr];
            LOGI("%s", [padStr UTF8String]);
        }

        // Show uptime + audio frame count on overlay every second
        const uint64_t audioFrames = g_audioFrames.load(std::memory_order_relaxed);
        [MC3DebugOverlay log:[NSString stringWithFormat:@"[LOOP] t=%.1fs audio=%llu",
                              currentTime, static_cast<unsigned long long>(audioFrames)]];

        tickCount = 0;
    }

    // Future: Call game->Tick(displayLink.duration) here
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];

    // Find and update Metal layer drawable size
    CAMetalLayer* metalLayer = nil;
    for (CALayer* layer in self.view.layer.sublayers) {
        if ([layer isKindOfClass:[CAMetalLayer class]]) {
            metalLayer = (CAMetalLayer*)layer;
            break;
        }
    }

    if (metalLayer) {
        metalLayer.frame = self.view.bounds;
        CGSize drawableSize = self.view.bounds.size;
        drawableSize.width *= self.view.contentScaleFactor;
        drawableSize.height *= self.view.contentScaleFactor;
        metalLayer.drawableSize = drawableSize;
    }

    // Update touch overlay frame when view bounds change (e.g., rotation)
    if (self.touchControlsOverlay) {
        self.touchControlsOverlay.frame = self.view.bounds;
    }
}

- (void)dealloc {
    [self.displayLink invalidate];
    self.displayLink = nil;

    _gpuBackend.reset();
    _testState.reset();
    if (_testVbData) mem::FreeContiguous(_testVbData);
    if (_testVbHeader) mem::FreeSystem(_testVbHeader);

#if !__has_feature(objc_arc)
    [super dealloc];
#endif
}

- (BOOL)prefersStatusBarHidden {
    return YES; // Hide status bar for fullscreen game
}

- (UIInterfaceOrientationMask)supportedInterfaceOrientations {
    return UIInterfaceOrientationMaskLandscape; // MC3 is landscape only
}

@end
