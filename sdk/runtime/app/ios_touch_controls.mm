#include <TargetConditionals.h>
#if TARGET_OS_IPHONE
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>

#include <array>
#include <cmath>
#include <cstddef>

#include "app/ios_touch_controls.h"
#include "core/input.h"
#include "gpu/metal.h"

namespace {

using input::UiMode;
using input::VirtualControl;

enum class ButtonStyle : uint8_t {
    Neutral = 0,
    Gas,      // emerald racing throttle pedal
    Brake,    // crimson brake/reverse pedal
    Nitro,    // electric cyan boost button
    Drift,    // amber handbrake button
    Special,  // violet special ability button
    TopPill,  // subtle top bar utility pill
    Confirm,  // emerald menu confirm
    Cancel,   // crimson menu back
};

struct ControlSpec {
    VirtualControl control;
    const char* title;
    CGFloat x;
    CGFloat y;
    CGFloat width;
    CGFloat height;
    CGFloat radius;  // 0 = full capsule/circle
    ButtonStyle style;
};

// Native mobile racing HUD (shown automatically during active driving / racing):
// - Bottom-left: sleek analog steering pad (toggleable to left/right steer pedals)
// - Bottom-right: tall GAS pedal (R-Trigger), BRAKE pedal (L-Trigger),
//   NOS turbo (X), DRIFT handbrake (A), SPEC special (L3), 2W weight/skip (B)
// - Top-left/center utility strip: Pause, Map, Camera, Rear View, Flash/Challenge, Next Song
//   (Top-right is kept completely clear for the race timer & POS HUD.)
constexpr std::array<ControlSpec, 12> kDrivingControls{{
    // Primary racing pedals & actions (bottom-right)
    {VirtualControl::TriggerR,  "GAS",   0.928, 0.785, 68, 114, 18, ButtonStyle::Gas},
    {VirtualControl::TriggerL,  "BRAKE", 0.816, 0.835, 70,  80, 16, ButtonStyle::Brake},
    {VirtualControl::FaceX,     "NOS",   0.822, 0.585, 60,  60,  0, ButtonStyle::Nitro},
    {VirtualControl::FaceA,     "DRIFT", 0.928, 0.525, 62,  54, 16, ButtonStyle::Drift},
    {VirtualControl::ThumbL,    "SPEC",  0.716, 0.695, 56,  42, 14, ButtonStyle::Special},
    {VirtualControl::FaceB,     "2W",    0.716, 0.865, 54,  42, 14, ButtonStyle::Neutral},
    // Minimal top utility pills (clear of top-right timer/POS)
    {VirtualControl::Start,     "⏸",     0.050, 0.095, 44,  34, 12, ButtonStyle::TopPill},
    {VirtualControl::MenuBack,  "MAP",   0.120, 0.095, 50,  34, 12, ButtonStyle::TopPill},
    {VirtualControl::ShoulderR, "CAM",   0.195, 0.095, 50,  34, 12, ButtonStyle::TopPill},
    {VirtualControl::FaceY,     "REAR",  0.272, 0.095, 54,  34, 12, ButtonStyle::TopPill},
    {VirtualControl::ShoulderL, "FLASH", 0.355, 0.095, 58,  34, 12, ButtonStyle::TopPill},
    {VirtualControl::DpadRight, "♫",     0.432, 0.095, 42,  34, 12, ButtonStyle::TopPill},
}};

// Optional digital steering pedals (when toggled from analog stick)
constexpr std::array<ControlSpec, 2> kSteerArrowControls{{
    {VirtualControl::SteerLeft,  "◀", 0.075, 0.775, 76, 72, 18, ButtonStyle::Neutral},
    {VirtualControl::SteerRight, "▶", 0.195, 0.775, 76, 72, 18, ButtonStyle::Neutral},
}};

// Clean native Menu & Garage navigation HUD (shown in Main Menu, 619 Customs Garage, Cutscenes, Pause):
constexpr std::array<ControlSpec, 13> kMenuControls{{
    // Navigation arrows (bottom-left)
    {VirtualControl::DpadUp,    "▲",      0.135, 0.645, 50, 48, 13, ButtonStyle::Neutral},
    {VirtualControl::DpadDown,  "▼",      0.135, 0.885, 50, 48, 13, ButtonStyle::Neutral},
    {VirtualControl::DpadLeft,  "◀",      0.068, 0.765, 50, 48, 13, ButtonStyle::Neutral},
    {VirtualControl::DpadRight, "▶",      0.202, 0.765, 50, 48, 13, ButtonStyle::Neutral},
    // Primary menu actions (bottom-right)
    {VirtualControl::Confirm,   "OK",     0.895, 0.855, 96, 52, 16, ButtonStyle::Confirm},
    {VirtualControl::FaceB,     "BACK",   0.895, 0.695, 96, 46, 15, ButtonStyle::Cancel},
    {VirtualControl::FaceX,     "OPTS",   0.762, 0.855, 68, 44, 14, ButtonStyle::Neutral},
    {VirtualControl::FaceY,     "VIEW",   0.762, 0.700, 68, 44, 14, ButtonStyle::Neutral},
    // Top bar (Garage tabs, camera zoom, Start)
    {VirtualControl::ShoulderL, "◀ TAB",  0.075, 0.095, 62, 34, 12, ButtonStyle::TopPill},
    {VirtualControl::ShoulderR, "TAB ▶",  0.165, 0.095, 62, 34, 12, ButtonStyle::TopPill},
    {VirtualControl::TriggerL,  "ZOOM-",  0.260, 0.095, 64, 34, 12, ButtonStyle::TopPill},
    {VirtualControl::TriggerR,  "ZOOM+",  0.355, 0.095, 64, 34, 12, ButtonStyle::TopPill},
    {VirtualControl::Start,     "START",  0.485, 0.095, 66, 34, 12, ButtonStyle::TopPill},
}};

constexpr CGFloat kStickX = 0.120;
constexpr CGFloat kStickY = 0.745;
constexpr CGFloat kStickDiameter = 122.0;
constexpr CGFloat kKnobDiameter = 46.0;
constexpr CGFloat kStickDeadzone = 0.05;

constexpr CGFloat kSteerToggleX = 0.498;
constexpr CGFloat kModeToggleDrivingX = 0.575;
constexpr CGFloat kModeToggleMenuX = 0.590;
constexpr CGFloat kFpsPillX = 0.670;
constexpr CGFloat kTopBarY = 0.095;

void ApplyButtonStyle(UIButton* button, ButtonStyle style, CGFloat width, CGFloat height, CGFloat radius) {
    UIColor* bg = [UIColor colorWithRed:0.06 green:0.08 blue:0.11 alpha:0.46];
    UIColor* border = [UIColor colorWithWhite:1.0 alpha:0.45];
    UIColor* titleColor = UIColor.whiteColor;
    CGFloat fontSize = 13.0;

    switch (style) {
    case ButtonStyle::Gas:
        bg = [UIColor colorWithRed:0.05 green:0.32 blue:0.20 alpha:0.54];
        border = [UIColor colorWithRed:0.25 green:0.95 blue:0.60 alpha:0.85];
        titleColor = [UIColor colorWithRed:0.85 green:1.0 blue:0.92 alpha:1.0];
        fontSize = 16.0;
        break;
    case ButtonStyle::Brake:
        bg = [UIColor colorWithRed:0.36 green:0.07 blue:0.10 alpha:0.54];
        border = [UIColor colorWithRed:1.0 green:0.34 blue:0.38 alpha:0.85];
        titleColor = [UIColor colorWithRed:1.0 green:0.88 blue:0.88 alpha:1.0];
        fontSize = 13.5;
        break;
    case ButtonStyle::Nitro:
        bg = [UIColor colorWithRed:0.04 green:0.22 blue:0.38 alpha:0.56];
        border = [UIColor colorWithRed:0.22 green:0.78 blue:1.0 alpha:0.90];
        titleColor = [UIColor colorWithRed:0.85 green:0.96 blue:1.0 alpha:1.0];
        fontSize = 14.0;
        break;
    case ButtonStyle::Drift:
        bg = [UIColor colorWithRed:0.36 green:0.22 blue:0.04 alpha:0.54];
        border = [UIColor colorWithRed:1.0 green:0.72 blue:0.20 alpha:0.88];
        titleColor = [UIColor colorWithRed:1.0 green:0.94 blue:0.80 alpha:1.0];
        fontSize = 13.0;
        break;
    case ButtonStyle::Special:
        bg = [UIColor colorWithRed:0.22 green:0.10 blue:0.36 alpha:0.52];
        border = [UIColor colorWithRed:0.74 green:0.46 blue:1.0 alpha:0.85];
        titleColor = [UIColor colorWithRed:0.94 green:0.88 blue:1.0 alpha:1.0];
        fontSize = 12.0;
        break;
    case ButtonStyle::Confirm:
        bg = [UIColor colorWithRed:0.06 green:0.34 blue:0.22 alpha:0.60];
        border = [UIColor colorWithRed:0.30 green:0.95 blue:0.62 alpha:0.88];
        fontSize = 15.0;
        break;
    case ButtonStyle::Cancel:
        bg = [UIColor colorWithRed:0.36 green:0.09 blue:0.12 alpha:0.58];
        border = [UIColor colorWithRed:1.0 green:0.38 blue:0.42 alpha:0.85];
        fontSize = 14.0;
        break;
    case ButtonStyle::TopPill:
        bg = [UIColor colorWithRed:0.05 green:0.07 blue:0.10 alpha:0.44];
        border = [UIColor colorWithWhite:1.0 alpha:0.35];
        fontSize = 11.5;
        break;
    case ButtonStyle::Neutral:
    default:
        break;
    }

    button.backgroundColor = bg;
    button.titleLabel.font = [UIFont systemFontOfSize:fontSize weight:UIFontWeightHeavy];
    [button setTitleColor:titleColor forState:UIControlStateNormal];
    button.layer.cornerRadius = (radius > 0.0) ? radius : (MIN(width, height) * 0.5);
    button.layer.borderWidth = (style == ButtonStyle::TopPill) ? 1.0 : 1.5;
    button.layer.borderColor = border.CGColor;
    button.layer.shadowColor = UIColor.blackColor.CGColor;
    button.layer.shadowOpacity = 0.45f;
    button.layer.shadowOffset = CGSizeMake(0, 2);
    button.layer.shadowRadius = 4.0;
    button.exclusiveTouch = NO;
}

}  // namespace

@interface MC3AnalogStickView : UIView
- (void)resetStick;
@end

@implementation MC3AnalogStickView {
    UIView* _knobView;
    UITouch* _activeTouch;
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;
    self.backgroundColor = [UIColor colorWithRed:0.05 green:0.07 blue:0.10 alpha:0.30];
    self.opaque = NO;
    self.multipleTouchEnabled = NO;
    self.exclusiveTouch = NO;
    self.userInteractionEnabled = YES;
    self.layer.cornerRadius = frame.size.width * 0.5;
    self.layer.borderWidth = 1.5;
    self.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.45].CGColor;

    // Subtle left/right steering chevron hints inside the steering ring
    UILabel* leftHint = [[UILabel alloc] initWithFrame:CGRectMake(6, frame.size.height * 0.5 - 10, 16, 20)];
    leftHint.text = @"‹";
    leftHint.textColor = [UIColor colorWithWhite:1.0 alpha:0.45];
    leftHint.font = [UIFont systemFontOfSize:18 weight:UIFontWeightBold];
    leftHint.textAlignment = NSTextAlignmentCenter;
    leftHint.userInteractionEnabled = NO;
    [self addSubview:leftHint];

    UILabel* rightHint = [[UILabel alloc] initWithFrame:CGRectMake(frame.size.width - 22, frame.size.height * 0.5 - 10, 16, 20)];
    rightHint.text = @"›";
    rightHint.textColor = [UIColor colorWithWhite:1.0 alpha:0.45];
    rightHint.font = [UIFont systemFontOfSize:18 weight:UIFontWeightBold];
    rightHint.textAlignment = NSTextAlignmentCenter;
    rightHint.userInteractionEnabled = NO;
    [self addSubview:rightHint];

    _knobView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, kKnobDiameter, kKnobDiameter)];
    _knobView.backgroundColor = [UIColor colorWithRed:0.20 green:0.75 blue:1.0 alpha:0.40];
    _knobView.layer.cornerRadius = kKnobDiameter * 0.5;
    _knobView.layer.borderWidth = 1.5;
    _knobView.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.85].CGColor;
    _knobView.userInteractionEnabled = NO;
    _knobView.center = CGPointMake(frame.size.width * 0.5, frame.size.height * 0.5);
    [self addSubview:_knobView];
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    self.layer.cornerRadius = MIN(self.bounds.size.width, self.bounds.size.height) * 0.5;
    if (!_activeTouch) {
        _knobView.center = CGPointMake(CGRectGetMidX(self.bounds), CGRectGetMidY(self.bounds));
    }
}

- (void)updateWithPoint:(CGPoint)pt {
    const CGPoint center = CGPointMake(CGRectGetMidX(self.bounds), CGRectGetMidY(self.bounds));
    const CGFloat maxRadius = MAX(1.0, (MIN(self.bounds.size.width, self.bounds.size.height) - kKnobDiameter) * 0.5);
    CGFloat dx = pt.x - center.x;
    CGFloat dy = pt.y - center.y;
    const CGFloat dist = std::hypot(dx, dy);
    if (dist > maxRadius) {
        const CGFloat scale = maxRadius / dist;
        dx *= scale;
        dy *= scale;
    }
    _knobView.center = CGPointMake(center.x + dx, center.y + dy);

    CGFloat nx = dx / maxRadius;
    CGFloat ny = -dy / maxRadius;  // UIKit +y is down; Xbox +ly is up
    if (std::fabs(nx) < kStickDeadzone) nx = 0.0;
    if (std::fabs(ny) < kStickDeadzone) ny = 0.0;
    input::SetVirtualLeftStick(static_cast<float>(nx), static_cast<float>(ny));
}

- (void)resetStick {
    _activeTouch = nil;
    _knobView.center = CGPointMake(CGRectGetMidX(self.bounds), CGRectGetMidY(self.bounds));
    _knobView.alpha = 1.0;
    input::SetVirtualLeftStick(0.0f, 0.0f);
}

- (void)touchesBegan:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)event {
    (void)event;
    if (!_activeTouch) {
        _activeTouch = [touches anyObject];
        if (_activeTouch) {
            _knobView.alpha = 0.85;
            [self updateWithPoint:[_activeTouch locationInView:self]];
        }
    }
}

- (void)touchesMoved:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)event {
    (void)event;
    if (_activeTouch && [touches containsObject:_activeTouch]) {
        [self updateWithPoint:[_activeTouch locationInView:self]];
    }
}

- (void)touchesEnded:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)event {
    (void)event;
    if (_activeTouch && [touches containsObject:_activeTouch]) {
        [self resetStick];
    }
}

- (void)touchesCancelled:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)event {
    (void)event;
    if (_activeTouch && [touches containsObject:_activeTouch]) {
        [self resetStick];
    }
}

@end

@interface MC3TouchControlsView : UIView
- (void)controlDown:(UIButton*)sender;
- (void)controlUp:(UIButton*)sender;
- (void)toggleSteerStyle:(UIButton*)sender;
- (void)toggleManualMode:(UIButton*)sender;
- (void)syncGameUiMode;
- (void)releaseAllControls;
- (void)applicationWillResignActive:(NSNotification*)notification;
@end

@implementation MC3TouchControlsView {
    UIView* _drivingContainer;
    UIView* _menuContainer;
    MC3AnalogStickView* _stickView;
    std::array<UIButton*, kDrivingControls.size()> _drivingButtons;
    std::array<UIButton*, kSteerArrowControls.size()> _steerArrowButtons;
    std::array<UIButton*, kMenuControls.size()> _menuButtons;
    UIButton* _steerToggleButton;
    UIButton* _toMenuButton;
    UIButton* _toDrivingButton;
    UILabel* _fpsLabel;
    NSTimer* _modeTimer;
    double _fpsLastTime;
    uint32_t _fpsLastFrames;
    UiMode _lastAutoMode;
    UiMode _activeMode;
    BOOL _manualOverride;
    BOOL _useArrowSteering;
}

- (UIButton*)makeButtonForSpec:(const ControlSpec&)spec tag:(NSInteger)tag {
    UIButton* button = [UIButton buttonWithType:UIButtonTypeCustom];
    button.tag = tag;
    NSString* title = [NSString stringWithUTF8String:spec.title];
    button.accessibilityLabel = title;
    [button setTitle:title forState:UIControlStateNormal];
    ApplyButtonStyle(button, spec.style, spec.width, spec.height, spec.radius);
    button.frame = CGRectMake(0, 0, spec.width, spec.height);
    button.autoresizingMask = UIViewAutoresizingNone;
    [button addTarget:self action:@selector(controlDown:) forControlEvents:UIControlEventTouchDown];
    [button addTarget:self action:@selector(controlUp:) forControlEvents:UIControlEventTouchUpInside |
                                                           UIControlEventTouchUpOutside |
                                                           UIControlEventTouchCancel];
    return button;
}

- (UIButton*)makeUtilityButtonWithTitle:(NSString*)title width:(CGFloat)w height:(CGFloat)h action:(SEL)action {
    UIButton* button = [UIButton buttonWithType:UIButtonTypeCustom];
    button.accessibilityLabel = title;
    [button setTitle:title forState:UIControlStateNormal];
    ApplyButtonStyle(button, ButtonStyle::TopPill, w, h, 12.0);
    button.frame = CGRectMake(0, 0, w, h);
    button.autoresizingMask = UIViewAutoresizingNone;
    [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    return button;
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;
    self.backgroundColor = UIColor.clearColor;
    self.opaque = NO;
    self.multipleTouchEnabled = YES;
    self.userInteractionEnabled = YES;
    self.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(applicationWillResignActive:)
                                                 name:UIApplicationWillResignActiveNotification
                                               object:nil];

    _drivingContainer = [[UIView alloc] initWithFrame:self.bounds];
    _drivingContainer.backgroundColor = UIColor.clearColor;
    _drivingContainer.opaque = NO;
    _drivingContainer.multipleTouchEnabled = YES;
    _drivingContainer.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self addSubview:_drivingContainer];

    _menuContainer = [[UIView alloc] initWithFrame:self.bounds];
    _menuContainer.backgroundColor = UIColor.clearColor;
    _menuContainer.opaque = NO;
    _menuContainer.multipleTouchEnabled = YES;
    _menuContainer.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self addSubview:_menuContainer];

    // Driving controls: steering stick + optional steer arrows + native pedals/boost
    _stickView = [[MC3AnalogStickView alloc] initWithFrame:CGRectMake(0, 0, kStickDiameter, kStickDiameter)];
    _stickView.autoresizingMask = UIViewAutoresizingNone;
    [_drivingContainer addSubview:_stickView];

    for (size_t i = 0; i < kSteerArrowControls.size(); ++i) {
        UIButton* btn = [self makeButtonForSpec:kSteerArrowControls[i]
                                            tag:static_cast<NSInteger>(kSteerArrowControls[i].control)];
        btn.hidden = YES;
        [_drivingContainer addSubview:btn];
        _steerArrowButtons[i] = btn;
    }

    for (size_t i = 0; i < kDrivingControls.size(); ++i) {
        UIButton* btn = [self makeButtonForSpec:kDrivingControls[i]
                                            tag:static_cast<NSInteger>(kDrivingControls[i].control)];
        [_drivingContainer addSubview:btn];
        _drivingButtons[i] = btn;
    }

    _steerToggleButton = [self makeUtilityButtonWithTitle:@"◀▶" width:46 height:34 action:@selector(toggleSteerStyle:)];
    [_drivingContainer addSubview:_steerToggleButton];

    _toMenuButton = [self makeUtilityButtonWithTitle:@"MENU" width:54 height:34 action:@selector(toggleManualMode:)];
    [_drivingContainer addSubview:_toMenuButton];

    // Menu & Garage controls
    for (size_t i = 0; i < kMenuControls.size(); ++i) {
        UIButton* btn = [self makeButtonForSpec:kMenuControls[i]
                                            tag:static_cast<NSInteger>(kMenuControls[i].control)];
        [_menuContainer addSubview:btn];
        _menuButtons[i] = btn;
    }

    _toDrivingButton = [self makeUtilityButtonWithTitle:@"DRIVE" width:58 height:34 action:@selector(toggleManualMode:)];
    [_menuContainer addSubview:_toDrivingButton];

    // Live FPS counter pill (non-interactive, visible in both Driving and Menu modes)
    _fpsLabel = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, 62, 24)];
    _fpsLabel.text = @"-- FPS";
    _fpsLabel.font = [UIFont monospacedDigitSystemFontOfSize:11.5 weight:UIFontWeightBold];
    _fpsLabel.textColor = [UIColor colorWithRed:0.35 green:0.98 blue:0.55 alpha:1.0];
    _fpsLabel.textAlignment = NSTextAlignmentCenter;
    _fpsLabel.backgroundColor = [UIColor colorWithRed:0.04 green:0.06 blue:0.09 alpha:0.52];
    _fpsLabel.layer.cornerRadius = 9.0;
    _fpsLabel.layer.masksToBounds = YES;
    _fpsLabel.layer.borderWidth = 1.0;
    _fpsLabel.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.28].CGColor;
    _fpsLabel.userInteractionEnabled = NO;
    _fpsLabel.autoresizingMask = UIViewAutoresizingNone;
    [self addSubview:_fpsLabel];

    _fpsLastTime = CACurrentMediaTime();
    _fpsLastFrames = gpu::PresentedFrameCount();

    _lastAutoMode = input::GetUiMode();
    _activeMode = _lastAutoMode;
    _manualOverride = NO;
    _useArrowSteering = NO;
    [self applyActiveModeAnimated:NO];

    __weak MC3TouchControlsView* weakSelf = self;
    _modeTimer = [NSTimer scheduledTimerWithTimeInterval:0.15
                                                 repeats:YES
                                                   block:^(NSTimer* _Nonnull timer) {
        (void)timer;
        [weakSelf syncGameUiMode];
    }];
    return self;
}

- (void)applyActiveModeAnimated:(BOOL)animated {
    const BOOL driving = (_activeMode == UiMode::Driving);
    void (^update)(void) = ^{
        _drivingContainer.alpha = driving ? 1.0 : 0.0;
        _menuContainer.alpha = driving ? 0.0 : 1.0;
    };
    _drivingContainer.hidden = NO;
    _menuContainer.hidden = NO;
    _drivingContainer.userInteractionEnabled = driving;
    _menuContainer.userInteractionEnabled = !driving;
    if (animated) {
        [UIView animateWithDuration:0.16
                         animations:update
                         completion:^(BOOL finished) {
            (void)finished;
            _drivingContainer.hidden = !(_activeMode == UiMode::Driving);
            _menuContainer.hidden = (_activeMode == UiMode::Driving);
        }];
    } else {
        update();
        _drivingContainer.hidden = !driving;
        _menuContainer.hidden = driving;
    }
}

- (void)syncGameUiMode {
    const double now = CACurrentMediaTime();
    const double elapsed = now - _fpsLastTime;
    if (elapsed >= 0.45) {
        const uint32_t frames = gpu::PresentedFrameCount();
        const uint32_t delta = frames - _fpsLastFrames;
        const double fps = static_cast<double>(delta) / elapsed;
        _fpsLastTime = now;
        _fpsLastFrames = frames;
        _fpsLabel.text = [NSString stringWithFormat:@"%.0f FPS", fps];
        if (fps >= 50.0) {
            _fpsLabel.textColor = [UIColor colorWithRed:0.35 green:0.98 blue:0.55 alpha:1.0];
        } else if (fps >= 30.0) {
            _fpsLabel.textColor = [UIColor colorWithRed:1.0 green:0.80 blue:0.25 alpha:1.0];
        } else {
            _fpsLabel.textColor = [UIColor colorWithRed:1.0 green:0.38 blue:0.38 alpha:1.0];
        }
    }

    const UiMode autoMode = input::GetUiMode();
    if (autoMode != _lastAutoMode) {
        _lastAutoMode = autoMode;
        _manualOverride = NO;
        if (_activeMode != autoMode) {
            [self releaseAllControls];
            _activeMode = autoMode;
            [self applyActiveModeAnimated:YES];
        }
    }
}

- (void)toggleSteerStyle:(UIButton*)sender {
    (void)sender;
    [_stickView resetStick];
    input::SetVirtualControl(VirtualControl::SteerLeft, false);
    input::SetVirtualControl(VirtualControl::SteerRight, false);
    _useArrowSteering = !_useArrowSteering;
    _stickView.hidden = _useArrowSteering;
    for (UIButton* btn : _steerArrowButtons) {
        btn.hidden = !_useArrowSteering;
    }
    [_steerToggleButton setTitle:(_useArrowSteering ? @"◎" : @"◀▶") forState:UIControlStateNormal];
}

- (void)toggleManualMode:(UIButton*)sender {
    (void)sender;
    [self releaseAllControls];
    _manualOverride = YES;
    _activeMode = (_activeMode == UiMode::Driving) ? UiMode::Menu : UiMode::Driving;
    [self applyActiveModeAnimated:YES];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    const CGRect bounds = self.bounds;
    const CGFloat x0 = CGRectGetMinX(bounds);
    const CGFloat y0 = CGRectGetMinY(bounds);
    const CGFloat w = CGRectGetWidth(bounds);
    const CGFloat h = CGRectGetHeight(bounds);

    _drivingContainer.frame = bounds;
    _menuContainer.frame = bounds;

    _stickView.center = CGPointMake(x0 + w * kStickX, y0 + h * kStickY);
    for (size_t i = 0; i < _steerArrowButtons.size(); ++i) {
        const auto& spec = kSteerArrowControls[i];
        _steerArrowButtons[i].center = CGPointMake(x0 + w * spec.x, y0 + h * spec.y);
    }
    for (size_t i = 0; i < _drivingButtons.size(); ++i) {
        const auto& spec = kDrivingControls[i];
        _drivingButtons[i].center = CGPointMake(x0 + w * spec.x, y0 + h * spec.y);
    }
    _steerToggleButton.center = CGPointMake(x0 + w * kSteerToggleX, y0 + h * kTopBarY);
    _toMenuButton.center = CGPointMake(x0 + w * kModeToggleDrivingX, y0 + h * kTopBarY);

    for (size_t i = 0; i < _menuButtons.size(); ++i) {
        const auto& spec = kMenuControls[i];
        _menuButtons[i].center = CGPointMake(x0 + w * spec.x, y0 + h * spec.y);
    }
    _toDrivingButton.center = CGPointMake(x0 + w * kModeToggleMenuX, y0 + h * kTopBarY);
    _fpsLabel.center = CGPointMake(x0 + w * kFpsPillX, y0 + h * kTopBarY);
}

- (void)controlDown:(UIButton*)sender {
    const NSInteger raw = sender.tag;
    if (raw < 0 || static_cast<size_t>(raw) >= static_cast<size_t>(VirtualControl::Count)) return;
    input::SetVirtualControl(static_cast<VirtualControl>(raw), true);
    sender.alpha = 0.72;
    sender.transform = CGAffineTransformMakeScale(0.94, 0.94);
}

- (void)controlUp:(UIButton*)sender {
    const NSInteger raw = sender.tag;
    if (raw < 0 || static_cast<size_t>(raw) >= static_cast<size_t>(VirtualControl::Count)) return;
    input::SetVirtualControl(static_cast<VirtualControl>(raw), false);
    sender.alpha = 1.0;
    sender.transform = CGAffineTransformIdentity;
}

- (void)releaseAllControls {
    [_stickView resetStick];
    for (size_t i = 0; i < static_cast<size_t>(VirtualControl::Count); ++i) {
        input::SetVirtualControl(static_cast<VirtualControl>(i), false);
    }
    auto resetButtons = [](const auto& arr) {
        for (UIButton* btn : arr) {
            btn.alpha = 1.0;
            btn.transform = CGAffineTransformIdentity;
        }
    };
    resetButtons(_drivingButtons);
    resetButtons(_steerArrowButtons);
    resetButtons(_menuButtons);
}

- (void)applicationWillResignActive:(NSNotification*)notification {
    (void)notification;
    [self releaseAllControls];
}

- (void)touchesCancelled:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)event {
    [self releaseAllControls];
    [super touchesCancelled:touches withEvent:event];
}

- (void)dealloc {
    [_modeTimer invalidate];
    _modeTimer = nil;
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [self releaseAllControls];
#if !__has_feature(objc_arc)
    [super dealloc];
#endif
}

@end

namespace app {

UIView* CreateTouchControlsOverlay(CGRect frame) {
    return [[MC3TouchControlsView alloc] initWithFrame:frame];
}

}  // namespace app
#endif  // TARGET_OS_IPHONE
