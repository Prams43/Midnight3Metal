#include <TargetConditionals.h>
#if TARGET_OS_IPHONE
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>

#include <array>
#include <cstddef>

#include "app/ios_touch_controls.h"
#include "core/input.h"
#import "MC3DebugOverlay.h"

namespace {

using input::VirtualControl;

struct ControlSpec {
    VirtualControl control;
    const char* title;
    CGFloat x;
    CGFloat y;
    CGFloat diameter;
};

// Normalized positions adapt to rotation and different device sizes.
constexpr std::array<ControlSpec, 12> kControls{{
    {VirtualControl::DpadUp, "▲", 0.12, 0.68, 58},
    {VirtualControl::DpadDown, "▼", 0.12, 0.91, 58},
    {VirtualControl::DpadLeft, "◀", 0.045, 0.795, 58},
    {VirtualControl::DpadRight, "▶", 0.195, 0.795, 58},
    {VirtualControl::FaceY, "Y", 0.88, 0.68, 58},
    {VirtualControl::FaceX, "X", 0.805, 0.795, 58},
    {VirtualControl::FaceB, "B", 0.955, 0.795, 58},
    {VirtualControl::Confirm, "A", 0.88, 0.91, 62},
    {VirtualControl::ShoulderL, "L", 0.08, 0.16, 54},
    {VirtualControl::ShoulderR, "R", 0.92, 0.16, 54},
    {VirtualControl::MenuBack, "BACK", 0.38, 0.12, 62},
    {VirtualControl::Start, "START", 0.62, 0.12, 62},
}};

}  // namespace

@interface MC3TouchControlsView : UIView
- (void)controlDown:(UIButton*)sender;
- (void)controlUp:(UIButton*)sender;
- (void)layoutSubviews;
- (void)releaseAllControls;
- (void)applicationWillResignActive:(NSNotification*)notification;
@end

@implementation MC3TouchControlsView {
    std::array<UIButton*, kControls.size()> _buttons;
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

    for (size_t i = 0; i < kControls.size(); ++i) {
        const auto& spec = kControls[i];
        UIButton* button = [UIButton buttonWithType:UIButtonTypeSystem];
        button.tag = static_cast<NSInteger>(i);
        NSString* title = [NSString stringWithUTF8String:spec.title];
        button.accessibilityLabel = title;
        button.titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightBold];
        [button setTitle:title forState:UIControlStateNormal];
        [button setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
        button.backgroundColor = [UIColor colorWithWhite:0.08 alpha:0.48];
        button.layer.cornerRadius = spec.diameter / 2;
        button.layer.borderWidth = 1;
        button.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.65].CGColor;
        button.frame = CGRectMake(0, 0, spec.diameter, spec.diameter);
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
    // Show on debug overlay — visible directly on iPhone without Mac
    NSString* name = [NSString stringWithUTF8String:kControls[static_cast<size_t>(index)].title];
    [MC3DebugOverlay log:[NSString stringWithFormat:@"[BTN] %@ DOWN", name]];
}

- (void)controlUp:(UIButton*)sender {
    const NSInteger index = sender.tag;
    if (index < 0 || static_cast<size_t>(index) >= kControls.size()) return;
    input::SetVirtualControl(kControls[static_cast<size_t>(index)].control, false);
    sender.alpha = 1.0;
    NSString* name = [NSString stringWithUTF8String:kControls[static_cast<size_t>(index)].title];
    [MC3DebugOverlay log:[NSString stringWithFormat:@"[BTN] %@ UP", name]];
}

- (void)releaseAllControls {
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
    [super dealloc];
}

@end

namespace app {

UIView* CreateTouchControlsOverlay(CGRect frame) {
    return [[MC3TouchControlsView alloc] initWithFrame:frame];
}

}  // namespace app
#endif  // TARGET_OS_IPHONE
