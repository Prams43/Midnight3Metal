#include <TargetConditionals.h>
#if TARGET_OS_IPHONE
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>

#include <array>
#include <cmath>
#include <cstddef>

#include "app/ios_touch_controls.h"
#include "core/input.h"

namespace {

using input::VirtualControl;

struct ControlSpec {
    VirtualControl control;
    const char* title;
    CGFloat x;
    CGFloat y;
    CGFloat width;
    CGFloat height;
};

// PS2/Xbox-style landscape layout:
// - Bottom-left: virtual left analog stick (for smooth car steering & weight transfer)
// - Lower-left-inner: compact D-pad (for menu navigation, horn, headlights, music skip)
// - Top-left: L2 (Left Trigger = Brake/Reverse) & L1 (White = Left Shoulder)
// - Top-right: R1 (Black = Right Shoulder) & R2 (Right Trigger = Gas/Accelerate)
// - Top-center: BACK & START
// - Bottom-right: Y, X, B, A diamond
constexpr std::array<ControlSpec, 14> kControls{{
    // Compact D-pad beside the analog stick
    {VirtualControl::DpadUp,    "▲",     0.275, 0.70, 38, 38},
    {VirtualControl::DpadDown,  "▼",     0.275, 0.89, 38, 38},
    {VirtualControl::DpadLeft,  "◀",     0.228, 0.795, 38, 38},
    {VirtualControl::DpadRight, "▶",     0.322, 0.795, 38, 38},
    // Face buttons (Xbox diamond)
    {VirtualControl::FaceY,     "Y",     0.875, 0.65, 56, 56},
    {VirtualControl::FaceX,     "X",     0.805, 0.775, 56, 56},
    {VirtualControl::FaceB,     "B",     0.945, 0.775, 56, 56},
    {VirtualControl::Confirm,   "A",     0.875, 0.90, 60, 60},
    // PS2-style shoulder & trigger buttons (L2/L1 left, R1/R2 right)
    {VirtualControl::TriggerL,  "L2",    0.065, 0.14, 60, 44},
    {VirtualControl::ShoulderL, "L1",    0.150, 0.14, 58, 42},
    {VirtualControl::ShoulderR, "R1",    0.850, 0.14, 58, 42},
    {VirtualControl::TriggerR,  "R2",    0.935, 0.14, 60, 44},
    // System buttons
    {VirtualControl::MenuBack,  "BACK",  0.42,  0.11, 56, 36},
    {VirtualControl::Start,     "START", 0.58,  0.11, 56, 36},
}};

constexpr CGFloat kStickX = 0.115;
constexpr CGFloat kStickY = 0.76;
constexpr CGFloat kStickDiameter = 124.0;
constexpr CGFloat kKnobDiameter = 48.0;
constexpr CGFloat kStickDeadzone = 0.06;

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
    self.backgroundColor = [UIColor colorWithWhite:0.08 alpha:0.28];
    self.opaque = NO;
    self.multipleTouchEnabled = NO;
    self.userInteractionEnabled = YES;
    self.layer.cornerRadius = frame.size.width * 0.5;
    self.layer.borderWidth = 1.5;
    self.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.55].CGColor;

    _knobView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, kKnobDiameter, kKnobDiameter)];
    _knobView.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.42];
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
- (void)layoutSubviews;
- (void)releaseAllControls;
- (void)applicationWillResignActive:(NSNotification*)notification;
@end

@implementation MC3TouchControlsView {
    std::array<UIButton*, kControls.size()> _buttons;
    MC3AnalogStickView* _stickView;
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

    _stickView = [[MC3AnalogStickView alloc] initWithFrame:CGRectMake(0, 0, kStickDiameter, kStickDiameter)];
    _stickView.center = CGPointMake(frame.size.width * kStickX, frame.size.height * kStickY);
    _stickView.autoresizingMask = UIViewAutoresizingNone;
    [self addSubview:_stickView];

    for (size_t i = 0; i < kControls.size(); ++i) {
        const auto& spec = kControls[i];
        UIButton* button = [UIButton buttonWithType:UIButtonTypeSystem];
        button.tag = static_cast<NSInteger>(i);
        NSString* title = [NSString stringWithUTF8String:spec.title];
        button.accessibilityLabel = title;
        button.titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightBold];
        [button setTitle:title forState:UIControlStateNormal];
        [button setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
        button.backgroundColor = [UIColor colorWithWhite:0.08 alpha:0.44];
        button.layer.cornerRadius = MIN(spec.width, spec.height) * 0.5;
        button.layer.borderWidth = 1;
        button.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.65].CGColor;
        button.frame = CGRectMake(0, 0, spec.width, spec.height);
        button.center = CGPointMake(frame.size.width * spec.x, frame.size.height * spec.y);
        button.autoresizingMask = UIViewAutoresizingNone;
        [button addTarget:self action:@selector(controlDown:) forControlEvents:UIControlEventTouchDown];
        [button addTarget:self action:@selector(controlUp:) forControlEvents:UIControlEventTouchUpInside |
                                                               UIControlEventTouchUpOutside |
                                                               UIControlEventTouchCancel];
        [self addSubview:button];
        _buttons[i] = button;
    }
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    const CGRect bounds = self.bounds;
    _stickView.center = CGPointMake(CGRectGetMinX(bounds) + CGRectGetWidth(bounds) * kStickX,
                                    CGRectGetMinY(bounds) + CGRectGetHeight(bounds) * kStickY);
    for (size_t i = 0; i < _buttons.size(); ++i) {
        const auto& spec = kControls[i];
        _buttons[i].center = CGPointMake(CGRectGetMinX(bounds) + CGRectGetWidth(bounds) * spec.x,
                                         CGRectGetMinY(bounds) + CGRectGetHeight(bounds) * spec.y);
    }
}

- (void)controlDown:(UIButton*)sender {
    const NSInteger index = sender.tag;
    if (index < 0 || static_cast<size_t>(index) >= kControls.size()) return;
    input::SetVirtualControl(kControls[static_cast<size_t>(index)].control, true);
    sender.alpha = 0.82;
}

- (void)controlUp:(UIButton*)sender {
    const NSInteger index = sender.tag;
    if (index < 0 || static_cast<size_t>(index) >= kControls.size()) return;
    input::SetVirtualControl(kControls[static_cast<size_t>(index)].control, false);
    sender.alpha = 1.0;
}

- (void)releaseAllControls {
    [_stickView resetStick];
    for (size_t i = 0; i < _buttons.size(); ++i) {
        input::SetVirtualControl(kControls[i].control, false);
        _buttons[i].alpha = 1.0;
    }
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
