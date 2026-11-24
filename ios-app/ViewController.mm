#import "ViewController.h"
#import "MetalRenderer.h"
#import "app/ios_touch_controls.h"
#import "MC3DebugOverlay.h"
#include "core/input.h"
#include "core/log.h"
#import <QuartzCore/CAMetalLayer.h>

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
@property (nonatomic) MetalRenderer* renderer;
@property (nonatomic) double startTime;
@property (strong, nonatomic) MC3DebugOverlay* debugOverlay;
@end

@implementation ViewController

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

    self.renderer = new MetalRenderer();

    if (!self.renderer->Init(metalLayer)) {
        LOGE("MC3 iOS Host: Failed to initialize Metal renderer");
        delete self.renderer;
        self.renderer = nullptr;
    } else {
        LOGI("MC3 iOS Host: Metal renderer initialized successfully");
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

    // Render Metal frame
    if (self.renderer && self.renderer->IsReady()) {
        self.renderer->Draw(currentTime);
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

        // Show uptime on overlay every second
        [MC3DebugOverlay log:[NSString stringWithFormat:@"[LOOP] t=%.1fs", currentTime]];

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

    if (self.renderer) {
        delete self.renderer;
        self.renderer = nullptr;
    }

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
