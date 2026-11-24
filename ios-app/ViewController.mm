#import "ViewController.h"
#import "MetalRenderer.h"
#import "app/ios_touch_controls.h"
#include "core/log.h"
#import <QuartzCore/CAMetalLayer.h>

@interface ViewController ()
@property (strong, nonatomic) UIView* touchControlsOverlay;
@property (strong, nonatomic) CADisplayLink* displayLink;
@property (nonatomic) MetalRenderer* renderer;
@property (nonatomic) double startTime;
@end

@implementation ViewController

+ (Class)layerClass {
    return [CAMetalLayer class];
}

- (void)viewDidLoad {
    [super viewDidLoad];

    self.view.backgroundColor = [UIColor blackColor];
    self.startTime = CACurrentMediaTime();

    // Initialize logging subsystem
    logx::Init("/tmp", "mc3ios");
    LOGI("MC3 iOS Host: UIKit app host started");

    // Initialize Metal renderer
    CAMetalLayer* metalLayer = (CAMetalLayer*)self.view.layer;
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

    // Set up game loop using CADisplayLink (synced to display refresh rate)
    self.displayLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(gameLoopTick:)];
    [self.displayLink addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];

    LOGI("MC3 iOS Host: Display link game loop started");
}

- (void)gameLoopTick:(CADisplayLink*)displayLink {
    double currentTime = CACurrentMediaTime() - self.startTime;

    // Render Metal frame
    if (self.renderer && self.renderer->IsReady()) {
        self.renderer->Draw(currentTime);
    }

    // Log once per second
    static int tickCount = 0;
    tickCount++;
    if (tickCount == 60) {
        LOGD("MC3 iOS Host: Game loop active (60 ticks, time=%.2f)", currentTime);
        tickCount = 0;
    }

    // Future: Call game->Tick(displayLink.duration) here
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];

    // Update Metal layer drawable size
    CAMetalLayer* metalLayer = (CAMetalLayer*)self.view.layer;
    CGSize drawableSize = self.view.bounds.size;
    drawableSize.width *= self.view.contentScaleFactor;
    drawableSize.height *= self.view.contentScaleFactor;
    metalLayer.drawableSize = drawableSize;

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

    [super dealloc];
}

- (BOOL)prefersStatusBarHidden {
    return YES; // Hide status bar for fullscreen game
}

- (UIInterfaceOrientationMask)supportedInterfaceOrientations {
    return UIInterfaceOrientationMaskLandscape; // MC3 is landscape only
}

@end
