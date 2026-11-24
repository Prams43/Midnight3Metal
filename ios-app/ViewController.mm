#import "ViewController.h"
#import "app/ios_touch_controls.h"
#include "core/log.h"

@interface ViewController ()
@property (strong, nonatomic) UIView* touchControlsOverlay;
@property (strong, nonatomic) CADisplayLink* displayLink;
@end

@implementation ViewController

- (void)viewDidLoad {
    [super viewDidLoad];

    self.view.backgroundColor = [UIColor blackColor];

    // Initialize logging subsystem
    log::Init();
    log::Info("MC3 iOS Host", "UIKit app host started");

    // Create and add touch controls overlay
    self.touchControlsOverlay = app::CreateTouchControlsOverlay(self.view.bounds);
    if (self.touchControlsOverlay) {
        [self.view addSubview:self.touchControlsOverlay];
        log::Info("MC3 iOS Host", "Touch controls overlay initialized");
    } else {
        log::Error("MC3 iOS Host", "Failed to create touch controls overlay");
    }

    // Set up game loop using CADisplayLink (synced to display refresh rate)
    self.displayLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(gameLoopTick:)];
    [self.displayLink addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];

    log::Info("MC3 iOS Host", "Display link game loop started");
}

- (void)gameLoopTick:(CADisplayLink*)displayLink {
    // Placeholder game loop - will be replaced with actual game tick
    // For now, just verify the loop is running
    static int tickCount = 0;
    tickCount++;

    if (tickCount == 60) { // Log once per second at 60fps
        log::Debug("MC3 iOS Host", "Game loop active (60 ticks)");
        tickCount = 0;
    }

    // Future: Call game->Tick(displayLink.duration) here
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];

    // Update touch overlay frame when view bounds change (e.g., rotation)
    if (self.touchControlsOverlay) {
        self.touchControlsOverlay.frame = self.view.bounds;
    }
}

- (void)dealloc {
    [self.displayLink invalidate];
    self.displayLink = nil;
    [super dealloc];
}

- (BOOL)prefersStatusBarHidden {
    return YES; // Hide status bar for fullscreen game
}

- (UIInterfaceOrientationMask)supportedInterfaceOrientations {
    return UIInterfaceOrientationMaskLandscape; // MC3 is landscape only
}

@end
