#include <TargetConditionals.h>
#if TARGET_OS_IPHONE
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>

#include <algorithm>
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
    const char* key;
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
    {"drv_gas",   VirtualControl::TriggerR,  "GAS",   0.928, 0.785, 68, 114, 18, ButtonStyle::Gas},
    {"drv_brake", VirtualControl::TriggerL,  "BRAKE", 0.816, 0.835, 70,  80, 16, ButtonStyle::Brake},
    {"drv_nos",   VirtualControl::FaceX,     "NOS",   0.822, 0.585, 60,  60,  0, ButtonStyle::Nitro},
    {"drv_drift", VirtualControl::FaceA,     "DRIFT", 0.928, 0.525, 62,  54, 16, ButtonStyle::Drift},
    {"drv_spec",  VirtualControl::ThumbL,    "SPEC",  0.716, 0.695, 56,  42, 14, ButtonStyle::Special},
    {"drv_2w",    VirtualControl::FaceB,     "2W",    0.716, 0.865, 54,  42, 14, ButtonStyle::Neutral},
    // Minimal top utility pills (clear of top-right timer/POS)
    {"drv_pause", VirtualControl::Start,     "⏸",     0.048, 0.095, 42,  34, 12, ButtonStyle::TopPill},
    {"drv_map",   VirtualControl::MenuBack,  "MAP",   0.114, 0.095, 48,  34, 12, ButtonStyle::TopPill},
    {"drv_cam",   VirtualControl::ShoulderR, "CAM",   0.184, 0.095, 48,  34, 12, ButtonStyle::TopPill},
    {"drv_rear",  VirtualControl::FaceY,     "REAR",  0.256, 0.095, 52,  34, 12, ButtonStyle::TopPill},
    {"drv_flash", VirtualControl::ShoulderL, "FLASH", 0.334, 0.095, 56,  34, 12, ButtonStyle::TopPill},
    {"drv_song",  VirtualControl::DpadRight, "♫",     0.406, 0.095, 40,  34, 12, ButtonStyle::TopPill},
}};

// Optional digital steering pedals (when toggled from analog stick)
constexpr std::array<ControlSpec, 2> kSteerArrowControls{{
    {"drv_left",  VirtualControl::SteerLeft,  "◀", 0.075, 0.775, 76, 72, 18, ButtonStyle::Neutral},
    {"drv_right", VirtualControl::SteerRight, "▶", 0.195, 0.775, 76, 72, 18, ButtonStyle::Neutral},
}};

// Clean native Menu & Garage navigation HUD (shown in Main Menu, 619 Customs Garage, Cutscenes, Pause):
constexpr std::array<ControlSpec, 13> kMenuControls{{
    // Navigation arrows (bottom-left)
    {"menu_up",    VirtualControl::DpadUp,    "▲",      0.135, 0.645, 50, 48, 13, ButtonStyle::Neutral},
    {"menu_down",  VirtualControl::DpadDown,  "▼",      0.135, 0.885, 50, 48, 13, ButtonStyle::Neutral},
    {"menu_left",  VirtualControl::DpadLeft,  "◀",      0.068, 0.765, 50, 48, 13, ButtonStyle::Neutral},
    {"menu_right", VirtualControl::DpadRight, "▶",      0.202, 0.765, 50, 48, 13, ButtonStyle::Neutral},
    // Primary menu actions (bottom-right)
    {"menu_ok",    VirtualControl::Confirm,   "OK",     0.895, 0.855, 96, 52, 16, ButtonStyle::Confirm},
    {"menu_back",  VirtualControl::FaceB,     "BACK",   0.895, 0.695, 96, 46, 15, ButtonStyle::Cancel},
    {"menu_opts",  VirtualControl::FaceX,     "OPTS",   0.762, 0.855, 68, 44, 14, ButtonStyle::Neutral},
    {"menu_view",  VirtualControl::FaceY,     "VIEW",   0.762, 0.700, 68, 44, 14, ButtonStyle::Neutral},
    // Top bar (Garage tabs, camera zoom, Start)
    {"menu_tabl",  VirtualControl::ShoulderL, "◀ TAB",  0.072, 0.095, 60, 34, 12, ButtonStyle::TopPill},
    {"menu_tabr",  VirtualControl::ShoulderR, "TAB ▶",  0.158, 0.095, 60, 34, 12, ButtonStyle::TopPill},
    {"menu_zmin",  VirtualControl::TriggerL,  "ZOOM-",  0.248, 0.095, 62, 34, 12, ButtonStyle::TopPill},
    {"menu_zmout", VirtualControl::TriggerR,  "ZOOM+",  0.340, 0.095, 62, 34, 12, ButtonStyle::TopPill},
    {"menu_start", VirtualControl::Start,     "START",  0.440, 0.095, 62, 34, 12, ButtonStyle::TopPill},
}};

constexpr CGFloat kStickX = 0.120;
constexpr CGFloat kStickY = 0.745;
constexpr CGFloat kStickDiameter = 122.0;
constexpr CGFloat kKnobRatio = 46.0 / 122.0;
constexpr CGFloat kStickDeadzone = 0.05;

constexpr CGFloat kSteerToggleX = 0.468;
constexpr CGFloat kModeToggleDrivingX = 0.538;
constexpr CGFloat kModeToggleMenuX = 0.532;
constexpr CGFloat kHudGearX = 0.606;
constexpr CGFloat kFpsPillX = 0.684;
constexpr CGFloat kTopBarY = 0.095;

constexpr CGFloat kMinItemScale = 0.60;
constexpr CGFloat kMaxItemScale = 1.60;
constexpr CGFloat kMinGlobalScale = 0.70;
constexpr CGFloat kMaxGlobalScale = 1.40;
constexpr CGFloat kMinOpacity = 0.25;
constexpr CGFloat kMaxOpacity = 1.00;

NSString* const kHudPrefsKey = @"MC3TouchHudConfig_v1";

CGFloat BaseFontSizeForStyle(ButtonStyle style) {
    switch (style) {
    case ButtonStyle::Gas:     return 16.0;
    case ButtonStyle::Confirm: return 15.0;
    case ButtonStyle::Nitro:
    case ButtonStyle::Cancel:  return 14.0;
    case ButtonStyle::Brake:   return 13.5;
    case ButtonStyle::Drift:   return 13.0;
    case ButtonStyle::Special: return 12.0;
    case ButtonStyle::TopPill: return 11.5;
    case ButtonStyle::Neutral:
    default:                   return 13.0;
    }
}

UIColor* BorderColorForStyle(ButtonStyle style) {
    switch (style) {
    case ButtonStyle::Gas:     return [UIColor colorWithRed:0.25 green:0.95 blue:0.60 alpha:0.85];
    case ButtonStyle::Brake:   return [UIColor colorWithRed:1.0 green:0.34 blue:0.38 alpha:0.85];
    case ButtonStyle::Nitro:   return [UIColor colorWithRed:0.22 green:0.78 blue:1.0 alpha:0.90];
    case ButtonStyle::Drift:   return [UIColor colorWithRed:1.0 green:0.72 blue:0.20 alpha:0.88];
    case ButtonStyle::Special: return [UIColor colorWithRed:0.74 green:0.46 blue:1.0 alpha:0.85];
    case ButtonStyle::Confirm: return [UIColor colorWithRed:0.30 green:0.95 blue:0.62 alpha:0.88];
    case ButtonStyle::Cancel:  return [UIColor colorWithRed:1.0 green:0.38 blue:0.42 alpha:0.85];
    case ButtonStyle::TopPill: return [UIColor colorWithWhite:1.0 alpha:0.35];
    case ButtonStyle::Neutral:
    default:                   return [UIColor colorWithWhite:1.0 alpha:0.45];
    }
}

void ApplyButtonStyle(UIButton* button, ButtonStyle style, CGFloat width, CGFloat height, CGFloat radius) {
    UIColor* bg = [UIColor colorWithRed:0.06 green:0.08 blue:0.11 alpha:0.46];
    UIColor* border = BorderColorForStyle(style);
    UIColor* titleColor = UIColor.whiteColor;
    const CGFloat fontSize = BaseFontSizeForStyle(style);

    switch (style) {
    case ButtonStyle::Gas:
        bg = [UIColor colorWithRed:0.05 green:0.32 blue:0.20 alpha:0.54];
        titleColor = [UIColor colorWithRed:0.85 green:1.0 blue:0.92 alpha:1.0];
        break;
    case ButtonStyle::Brake:
        bg = [UIColor colorWithRed:0.36 green:0.07 blue:0.10 alpha:0.54];
        titleColor = [UIColor colorWithRed:1.0 green:0.88 blue:0.88 alpha:1.0];
        break;
    case ButtonStyle::Nitro:
        bg = [UIColor colorWithRed:0.04 green:0.22 blue:0.38 alpha:0.56];
        titleColor = [UIColor colorWithRed:0.85 green:0.96 blue:1.0 alpha:1.0];
        break;
    case ButtonStyle::Drift:
        bg = [UIColor colorWithRed:0.36 green:0.22 blue:0.04 alpha:0.54];
        titleColor = [UIColor colorWithRed:1.0 green:0.94 blue:0.80 alpha:1.0];
        break;
    case ButtonStyle::Special:
        bg = [UIColor colorWithRed:0.22 green:0.10 blue:0.36 alpha:0.52];
        titleColor = [UIColor colorWithRed:0.94 green:0.88 blue:1.0 alpha:1.0];
        break;
    case ButtonStyle::Confirm:
        bg = [UIColor colorWithRed:0.06 green:0.34 blue:0.22 alpha:0.60];
        break;
    case ButtonStyle::Cancel:
        bg = [UIColor colorWithRed:0.36 green:0.09 blue:0.12 alpha:0.58];
        break;
    case ButtonStyle::TopPill:
        bg = [UIColor colorWithRed:0.05 green:0.07 blue:0.10 alpha:0.44];
        break;
    case ButtonStyle::Neutral:
    default:
        break;
    }

    button.backgroundColor = bg;
    button.titleLabel.font = [UIFont systemFontOfSize:fontSize weight:UIFontWeightHeavy];
    button.titleLabel.adjustsFontSizeToFitWidth = YES;
    button.titleLabel.minimumScaleFactor = 0.65;
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

@interface MC3HudItem : NSObject
@property (nonatomic, copy) NSString* key;
@property (nonatomic, copy) NSString* displayName;
@property (nonatomic, strong) UIView* view;
@property (nonatomic, assign) CGFloat defaultX;
@property (nonatomic, assign) CGFloat defaultY;
@property (nonatomic, assign) CGFloat x;
@property (nonatomic, assign) CGFloat y;
@property (nonatomic, assign) CGFloat scale;
@property (nonatomic, assign) CGFloat baseW;
@property (nonatomic, assign) CGFloat baseH;
@property (nonatomic, assign) CGFloat baseRadius;
@property (nonatomic, assign) ButtonStyle style;
@property (nonatomic, assign) BOOL isDriving;
@property (nonatomic, assign) BOOL isMenu;
@property (nonatomic, assign) BOOL isGlobal;
@property (nonatomic, assign) BOOL isButton;
@property (nonatomic, assign) BOOL isFps;
@end

@implementation MC3HudItem
@end

@interface MC3AnalogStickView : UIView
- (void)resetStick;
@end

@implementation MC3AnalogStickView {
    UIView* _knobView;
    UILabel* _leftHint;
    UILabel* _rightHint;
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

    _leftHint = [[UILabel alloc] initWithFrame:CGRectZero];
    _leftHint.text = @"‹";
    _leftHint.textColor = [UIColor colorWithWhite:1.0 alpha:0.45];
    _leftHint.font = [UIFont systemFontOfSize:18 weight:UIFontWeightBold];
    _leftHint.textAlignment = NSTextAlignmentCenter;
    _leftHint.userInteractionEnabled = NO;
    [self addSubview:_leftHint];

    _rightHint = [[UILabel alloc] initWithFrame:CGRectZero];
    _rightHint.text = @"›";
    _rightHint.textColor = [UIColor colorWithWhite:1.0 alpha:0.45];
    _rightHint.font = [UIFont systemFontOfSize:18 weight:UIFontWeightBold];
    _rightHint.textAlignment = NSTextAlignmentCenter;
    _rightHint.userInteractionEnabled = NO;
    [self addSubview:_rightHint];

    _knobView = [[UIView alloc] initWithFrame:CGRectZero];
    _knobView.backgroundColor = [UIColor colorWithRed:0.20 green:0.75 blue:1.0 alpha:0.40];
    _knobView.layer.borderWidth = 1.5;
    _knobView.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.85].CGColor;
    _knobView.userInteractionEnabled = NO;
    [self addSubview:_knobView];
    [self layoutSubviews];
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    const CGFloat d = MIN(self.bounds.size.width, self.bounds.size.height);
    const CGFloat knobD = MAX(24.0, d * kKnobRatio);
    self.layer.cornerRadius = d * 0.5;
    _leftHint.frame = CGRectMake(6, self.bounds.size.height * 0.5 - 10, 16, 20);
    _rightHint.frame = CGRectMake(self.bounds.size.width - 22, self.bounds.size.height * 0.5 - 10, 16, 20);
    _knobView.bounds = CGRectMake(0, 0, knobD, knobD);
    _knobView.layer.cornerRadius = knobD * 0.5;
    if (!_activeTouch) {
        _knobView.center = CGPointMake(CGRectGetMidX(self.bounds), CGRectGetMidY(self.bounds));
    }
}

- (void)updateWithPoint:(CGPoint)pt {
    const CGPoint center = CGPointMake(CGRectGetMidX(self.bounds), CGRectGetMidY(self.bounds));
    const CGFloat d = MIN(self.bounds.size.width, self.bounds.size.height);
    const CGFloat knobD = MAX(24.0, d * kKnobRatio);
    const CGFloat maxRadius = MAX(1.0, (d - knobD) * 0.5);
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

@protocol MC3HudEditOverlayDelegate <NSObject>
- (void)hudEditBeganAtPoint:(CGPoint)pt;
- (void)hudEditMovedToPoint:(CGPoint)pt;
- (void)hudEditEnded;
@end

@interface MC3HudEditOverlayView : UIView
@property (nonatomic, weak) id<MC3HudEditOverlayDelegate> delegate;
@end

@implementation MC3HudEditOverlayView {
    UITouch* _dragTouch;
}

- (void)touchesBegan:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)event {
    (void)event;
    if (!_dragTouch) {
        _dragTouch = [touches anyObject];
        if (_dragTouch) {
            [self.delegate hudEditBeganAtPoint:[_dragTouch locationInView:self]];
        }
    }
}

- (void)touchesMoved:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)event {
    (void)event;
    if (_dragTouch && [touches containsObject:_dragTouch]) {
        [self.delegate hudEditMovedToPoint:[_dragTouch locationInView:self]];
    }
}

- (void)touchesEnded:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)event {
    (void)event;
    if (_dragTouch && [touches containsObject:_dragTouch]) {
        _dragTouch = nil;
        [self.delegate hudEditEnded];
    }
}

- (void)touchesCancelled:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)event {
    (void)event;
    if (_dragTouch && [touches containsObject:_dragTouch]) {
        _dragTouch = nil;
        [self.delegate hudEditEnded];
    }
}

@end

@interface MC3TouchControlsView : UIView <MC3HudEditOverlayDelegate>
- (void)controlDown:(UIButton*)sender;
- (void)controlUp:(UIButton*)sender;
- (void)toggleSteerStyle:(UIButton*)sender;
- (void)toggleManualMode:(UIButton*)sender;
- (void)toggleEditMode:(UIButton*)sender;
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
    UIButton* _hudEditButton;
    UILabel* _fpsLabel;

    // Editable HUD items & customization state
    NSMutableArray<MC3HudItem*>* _items;
    MC3HudItem* _selectedItem;
    MC3HudItem* _draggingItem;
    CGPoint _dragOffset;
    BOOL _editMode;
    CGFloat _globalScale;
    CGFloat _hudOpacity;
    BOOL _showFps;

    // Floating in-game HUD editor UI
    MC3HudEditOverlayView* _editOverlay;
    UIView* _editorPanel;
    UILabel* _editorTargetLabel;
    UIButton* _editorModeBtn;
    UIButton* _editorSteerBtn;
    UIButton* _editorFpsBtn;
    UIButton* _editorAllBtn;
    UISlider* _sizeSlider;
    UILabel* _sizeValueLabel;
    UISlider* _opacitySlider;
    UILabel* _opacityValueLabel;

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

- (UIButton*)makeEditorPillWithTitle:(NSString*)title bg:(UIColor*)bg border:(UIColor*)border action:(SEL)action {
    UIButton* btn = [UIButton buttonWithType:UIButtonTypeCustom];
    [btn setTitle:title forState:UIControlStateNormal];
    [btn setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    btn.titleLabel.font = [UIFont systemFontOfSize:11.0 weight:UIFontWeightBold];
    btn.titleLabel.adjustsFontSizeToFitWidth = YES;
    btn.titleLabel.minimumScaleFactor = 0.75;
    btn.backgroundColor = bg;
    btn.layer.cornerRadius = 8.0;
    btn.layer.borderWidth = 1.0;
    btn.layer.borderColor = border.CGColor;
    [btn addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    return btn;
}

- (MC3HudItem*)registerItemKey:(NSString*)key
                   displayName:(NSString*)name
                          view:(UIView*)view
                             x:(CGFloat)x
                             y:(CGFloat)y
                         baseW:(CGFloat)w
                         baseH:(CGFloat)h
                    baseRadius:(CGFloat)radius
                         style:(ButtonStyle)style
                     isDriving:(BOOL)isDriving
                        isMenu:(BOOL)isMenu
                      isGlobal:(BOOL)isGlobal
                      isButton:(BOOL)isButton
                         isFps:(BOOL)isFps {
    MC3HudItem* item = [[MC3HudItem alloc] init];
    item.key = key;
    item.displayName = name;
    item.view = view;
    item.defaultX = x;
    item.defaultY = y;
    item.x = x;
    item.y = y;
    item.scale = 1.0;
    item.baseW = w;
    item.baseH = h;
    item.baseRadius = radius;
    item.style = style;
    item.isDriving = isDriving;
    item.isMenu = isMenu;
    item.isGlobal = isGlobal;
    item.isButton = isButton;
    item.isFps = isFps;
    [_items addObject:item];
    return item;
}

- (void)buildEditorUi {
    _editOverlay = [[MC3HudEditOverlayView alloc] initWithFrame:self.bounds];
    _editOverlay.backgroundColor = [UIColor colorWithRed:0.02 green:0.04 blue:0.08 alpha:0.28];
    _editOverlay.hidden = YES;
    _editOverlay.userInteractionEnabled = NO;
    _editOverlay.delegate = self;
    _editOverlay.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self addSubview:_editOverlay];

    _editorPanel = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 490, 96)];
    _editorPanel.backgroundColor = [UIColor colorWithRed:0.06 green:0.08 blue:0.12 alpha:0.92];
    _editorPanel.layer.cornerRadius = 14.0;
    _editorPanel.layer.borderWidth = 1.2;
    _editorPanel.layer.borderColor = [UIColor colorWithRed:0.25 green:0.80 blue:1.0 alpha:0.75].CGColor;
    _editorPanel.layer.shadowColor = UIColor.blackColor.CGColor;
    _editorPanel.layer.shadowOpacity = 0.65f;
    _editorPanel.layer.shadowOffset = CGSizeMake(0, 4);
    _editorPanel.layer.shadowRadius = 10.0;
    _editorPanel.hidden = YES;
    [self addSubview:_editorPanel];

    _editorTargetLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _editorTargetLabel.text = @"HUD: ALL";
    _editorTargetLabel.textColor = [UIColor colorWithRed:0.55 green:0.92 blue:1.0 alpha:1.0];
    _editorTargetLabel.font = [UIFont systemFontOfSize:11.5 weight:UIFontWeightHeavy];
    _editorTargetLabel.adjustsFontSizeToFitWidth = YES;
    _editorTargetLabel.minimumScaleFactor = 0.75;
    [_editorPanel addSubview:_editorTargetLabel];

    UIColor* neutralBg = [UIColor colorWithWhite:1.0 alpha:0.12];
    UIColor* neutralBorder = [UIColor colorWithWhite:1.0 alpha:0.30];

    _editorModeBtn = [self makeEditorPillWithTitle:@"DRIVE" bg:neutralBg border:neutralBorder action:@selector(editorToggleMode:)];
    _editorSteerBtn = [self makeEditorPillWithTitle:@"STICK" bg:neutralBg border:neutralBorder action:@selector(editorToggleSteer:)];
    _editorFpsBtn = [self makeEditorPillWithTitle:@"FPS:ON" bg:neutralBg border:neutralBorder action:@selector(editorToggleFps:)];
    UIButton* resetBtn = [self makeEditorPillWithTitle:@"RESET"
                                                    bg:[UIColor colorWithRed:0.45 green:0.12 blue:0.14 alpha:0.75]
                                                border:[UIColor colorWithRed:1.0 green:0.42 blue:0.45 alpha:0.8]
                                                action:@selector(editorResetLayout:)];
    UIButton* doneBtn = [self makeEditorPillWithTitle:@"DONE"
                                                   bg:[UIColor colorWithRed:0.08 green:0.46 blue:0.28 alpha:0.88]
                                               border:[UIColor colorWithRed:0.32 green:0.98 blue:0.65 alpha:0.9]
                                               action:@selector(toggleEditMode:)];
    doneBtn.tag = 999;
    resetBtn.tag = 998;
    [_editorPanel addSubview:_editorModeBtn];
    [_editorPanel addSubview:_editorSteerBtn];
    [_editorPanel addSubview:_editorFpsBtn];
    [_editorPanel addSubview:resetBtn];
    [_editorPanel addSubview:doneBtn];

    _editorAllBtn = [self makeEditorPillWithTitle:@"ALL"
                                               bg:[UIColor colorWithRed:0.12 green:0.36 blue:0.52 alpha:0.85]
                                           border:[UIColor colorWithRed:0.35 green:0.85 blue:1.0 alpha:0.9]
                                           action:@selector(editorSelectAll:)];
    [_editorPanel addSubview:_editorAllBtn];

    _sizeValueLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _sizeValueLabel.text = @"SIZE 100%";
    _sizeValueLabel.textColor = UIColor.whiteColor;
    _sizeValueLabel.font = [UIFont monospacedDigitSystemFontOfSize:10.5 weight:UIFontWeightBold];
    [_editorPanel addSubview:_sizeValueLabel];

    _sizeSlider = [[UISlider alloc] initWithFrame:CGRectZero];
    _sizeSlider.minimumValue = static_cast<float>(kMinGlobalScale);
    _sizeSlider.maximumValue = static_cast<float>(kMaxGlobalScale);
    _sizeSlider.value = 1.0f;
    _sizeSlider.minimumTrackTintColor = [UIColor colorWithRed:0.22 green:0.80 blue:1.0 alpha:1.0];
    [_sizeSlider addTarget:self action:@selector(sizeSliderChanged:) forControlEvents:UIControlEventValueChanged];
    [_editorPanel addSubview:_sizeSlider];

    _opacityValueLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _opacityValueLabel.text = @"ALPHA 100%";
    _opacityValueLabel.textColor = UIColor.whiteColor;
    _opacityValueLabel.font = [UIFont monospacedDigitSystemFontOfSize:10.5 weight:UIFontWeightBold];
    [_editorPanel addSubview:_opacityValueLabel];

    _opacitySlider = [[UISlider alloc] initWithFrame:CGRectZero];
    _opacitySlider.minimumValue = static_cast<float>(kMinOpacity);
    _opacitySlider.maximumValue = static_cast<float>(kMaxOpacity);
    _opacitySlider.value = 1.0f;
    _opacitySlider.minimumTrackTintColor = [UIColor colorWithRed:0.30 green:0.95 blue:0.62 alpha:1.0];
    [_opacitySlider addTarget:self action:@selector(opacitySliderChanged:) forControlEvents:UIControlEventValueChanged];
    [_editorPanel addSubview:_opacitySlider];
}

- (void)layoutEditorPanel {
    const CGRect bounds = self.bounds;
    const CGFloat maxW = MIN(520.0, MAX(310.0, CGRectGetWidth(bounds) - 24.0));
    const CGFloat panelH = 92.0;
    const CGFloat panelY = MAX(10.0, CGRectGetHeight(bounds) * 0.19);
    _editorPanel.frame = CGRectMake(CGRectGetMidX(bounds) - maxW * 0.5, panelY, maxW, panelH);

    const CGFloat pad = 10.0;
    const CGFloat innerW = maxW - pad * 2.0;
    const CGFloat row1Y = 9.0;
    const CGFloat row1H = 28.0;
    const CGFloat gap = 6.0;

    const CGFloat doneW = 54.0;
    const CGFloat resetW = 54.0;
    const CGFloat fpsW = 58.0;
    const CGFloat steerW = 58.0;
    const CGFloat modeW = 56.0;
    const CGFloat rightTotal = doneW + resetW + fpsW + steerW + modeW + gap * 4.0;
    const CGFloat labelW = MAX(68.0, innerW - rightTotal - gap);

    _editorTargetLabel.frame = CGRectMake(pad, row1Y, labelW, row1H);
    CGFloat rx = maxW - pad - doneW;
    UIView* doneBtn = [_editorPanel viewWithTag:999];
    UIView* resetBtn = [_editorPanel viewWithTag:998];
    doneBtn.frame = CGRectMake(rx, row1Y, doneW, row1H);
    rx -= gap + resetW;
    resetBtn.frame = CGRectMake(rx, row1Y, resetW, row1H);
    rx -= gap + fpsW;
    _editorFpsBtn.frame = CGRectMake(rx, row1Y, fpsW, row1H);
    rx -= gap + steerW;
    _editorSteerBtn.frame = CGRectMake(rx, row1Y, steerW, row1H);
    rx -= gap + modeW;
    _editorModeBtn.frame = CGRectMake(rx, row1Y, modeW, row1H);

    const CGFloat row2Y = 48.0;
    const CGFloat row2H = 34.0;
    const CGFloat allW = 36.0;
    const CGFloat halfW = (innerW - allW - gap * 2.0) * 0.5;

    _editorAllBtn.frame = CGRectMake(pad, row2Y + 3.0, allW, 28.0);
    const CGFloat s1X = pad + allW + gap;
    _sizeValueLabel.frame = CGRectMake(s1X, row2Y - 4.0, halfW, 14.0);
    _sizeSlider.frame = CGRectMake(s1X, row2Y + 10.0, halfW, row2H - 10.0);

    const CGFloat s2X = s1X + halfW + gap;
    _opacityValueLabel.frame = CGRectMake(s2X, row2Y - 4.0, halfW, 14.0);
    _opacitySlider.frame = CGRectMake(s2X, row2Y + 10.0, halfW, row2H - 10.0);
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

    _items = [NSMutableArray array];
    _globalScale = 1.0;
    _hudOpacity = 1.0;
    _showFps = YES;
    _editMode = NO;

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
    [self registerItemKey:@"drv_stick" displayName:@"STEER STICK" view:_stickView
                        x:kStickX y:kStickY baseW:kStickDiameter baseH:kStickDiameter baseRadius:0.0
                    style:ButtonStyle::Neutral isDriving:YES isMenu:NO isGlobal:NO isButton:NO isFps:NO];

    for (size_t i = 0; i < kSteerArrowControls.size(); ++i) {
        const auto& spec = kSteerArrowControls[i];
        UIButton* btn = [self makeButtonForSpec:spec tag:static_cast<NSInteger>(spec.control)];
        btn.hidden = YES;
        [_drivingContainer addSubview:btn];
        _steerArrowButtons[i] = btn;
        [self registerItemKey:[NSString stringWithUTF8String:spec.key]
                  displayName:(i == 0 ? @"STEER LEFT" : @"STEER RIGHT")
                         view:btn x:spec.x y:spec.y baseW:spec.width baseH:spec.height baseRadius:spec.radius
                        style:spec.style isDriving:YES isMenu:NO isGlobal:NO isButton:YES isFps:NO];
    }

    for (size_t i = 0; i < kDrivingControls.size(); ++i) {
        const auto& spec = kDrivingControls[i];
        UIButton* btn = [self makeButtonForSpec:spec tag:static_cast<NSInteger>(spec.control)];
        [_drivingContainer addSubview:btn];
        _drivingButtons[i] = btn;
        NSString* disp = [NSString stringWithUTF8String:spec.title];
        if (spec.control == VirtualControl::Start) disp = @"PAUSE";
        else if (spec.control == VirtualControl::DpadRight) disp = @"NEXT SONG";
        [self registerItemKey:[NSString stringWithUTF8String:spec.key]
                  displayName:disp
                         view:btn x:spec.x y:spec.y baseW:spec.width baseH:spec.height baseRadius:spec.radius
                        style:spec.style isDriving:YES isMenu:NO isGlobal:NO isButton:YES isFps:NO];
    }

    _steerToggleButton = [self makeUtilityButtonWithTitle:@"◀▶" width:44 height:34 action:@selector(toggleSteerStyle:)];
    [_drivingContainer addSubview:_steerToggleButton];
    [self registerItemKey:@"drv_steer_tog" displayName:@"STEER MODE" view:_steerToggleButton
                        x:kSteerToggleX y:kTopBarY baseW:44 baseH:34 baseRadius:12.0
                    style:ButtonStyle::TopPill isDriving:YES isMenu:NO isGlobal:NO isButton:YES isFps:NO];

    _toMenuButton = [self makeUtilityButtonWithTitle:@"MENU" width:52 height:34 action:@selector(toggleManualMode:)];
    [_drivingContainer addSubview:_toMenuButton];
    [self registerItemKey:@"drv_menu_tog" displayName:@"MENU BTN" view:_toMenuButton
                        x:kModeToggleDrivingX y:kTopBarY baseW:52 baseH:34 baseRadius:12.0
                    style:ButtonStyle::TopPill isDriving:YES isMenu:NO isGlobal:NO isButton:YES isFps:NO];

    // Menu & Garage controls
    for (size_t i = 0; i < kMenuControls.size(); ++i) {
        const auto& spec = kMenuControls[i];
        UIButton* btn = [self makeButtonForSpec:spec tag:static_cast<NSInteger>(spec.control)];
        [_menuContainer addSubview:btn];
        _menuButtons[i] = btn;
        [self registerItemKey:[NSString stringWithUTF8String:spec.key]
                  displayName:[NSString stringWithUTF8String:spec.title]
                         view:btn x:spec.x y:spec.y baseW:spec.width baseH:spec.height baseRadius:spec.radius
                        style:spec.style isDriving:NO isMenu:YES isGlobal:NO isButton:YES isFps:NO];
    }

    _toDrivingButton = [self makeUtilityButtonWithTitle:@"DRIVE" width:56 height:34 action:@selector(toggleManualMode:)];
    [_menuContainer addSubview:_toDrivingButton];
    [self registerItemKey:@"menu_drv_tog" displayName:@"DRIVE BTN" view:_toDrivingButton
                        x:kModeToggleMenuX y:kTopBarY baseW:56 baseH:34 baseRadius:12.0
                    style:ButtonStyle::TopPill isDriving:NO isMenu:YES isGlobal:NO isButton:YES isFps:NO];

    // Persistent HUD Settings button (visible in both Driving and Menu modes)
    _hudEditButton = [self makeUtilityButtonWithTitle:@"⚙" width:38 height:34 action:@selector(toggleEditMode:)];
    _hudEditButton.accessibilityLabel = @"HUD Settings";
    [self addSubview:_hudEditButton];
    [self registerItemKey:@"hud_gear" displayName:@"HUD BTN" view:_hudEditButton
                        x:kHudGearX y:kTopBarY baseW:38 baseH:34 baseRadius:12.0
                    style:ButtonStyle::TopPill isDriving:NO isMenu:NO isGlobal:YES isButton:YES isFps:NO];

    // Live FPS counter pill (visible in both Driving and Menu modes, toggleable & draggable)
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
    [self registerItemKey:@"hud_fps" displayName:@"FPS PILL" view:_fpsLabel
                        x:kFpsPillX y:kTopBarY baseW:62 baseH:24 baseRadius:9.0
                    style:ButtonStyle::TopPill isDriving:NO isMenu:NO isGlobal:YES isButton:NO isFps:YES];

    [self buildEditorUi];

    _fpsLastTime = CACurrentMediaTime();
    _fpsLastFrames = gpu::PresentedFrameCount();

    _lastAutoMode = input::GetUiMode();
    _activeMode = _lastAutoMode;
    _manualOverride = NO;
    _useArrowSteering = NO;

    [self loadHudPreferences];
    [self applySteerStyleVisibility];
    [self applyActiveModeAnimated:NO];
    [self updateFpsVisibility];

    __weak MC3TouchControlsView* weakSelf = self;
    _modeTimer = [NSTimer scheduledTimerWithTimeInterval:0.15
                                                 repeats:YES
                                                   block:^(NSTimer* _Nonnull timer) {
        (void)timer;
        [weakSelf syncGameUiMode];
    }];
    return self;
}

- (void)loadHudPreferences {
    NSDictionary* saved = [[NSUserDefaults standardUserDefaults] dictionaryForKey:kHudPrefsKey];
    if (![saved isKindOfClass:[NSDictionary class]]) return;

    NSNumber* gs = saved[@"globalScale"];
    if ([gs isKindOfClass:[NSNumber class]] && std::isfinite(gs.doubleValue)) {
        _globalScale = std::clamp<CGFloat>(gs.doubleValue, kMinGlobalScale, kMaxGlobalScale);
    }
    NSNumber* op = saved[@"opacity"];
    if ([op isKindOfClass:[NSNumber class]] && std::isfinite(op.doubleValue)) {
        _hudOpacity = std::clamp<CGFloat>(op.doubleValue, kMinOpacity, kMaxOpacity);
    }
    NSNumber* fps = saved[@"showFps"];
    if ([fps isKindOfClass:[NSNumber class]]) {
        _showFps = fps.boolValue;
    }
    NSNumber* arrows = saved[@"arrowSteering"];
    if ([arrows isKindOfClass:[NSNumber class]]) {
        _useArrowSteering = arrows.boolValue;
    }

    NSDictionary* itemsMap = saved[@"items"];
    if ([itemsMap isKindOfClass:[NSDictionary class]]) {
        for (MC3HudItem* item in _items) {
            NSDictionary* entry = itemsMap[item.key];
            if (![entry isKindOfClass:[NSDictionary class]]) continue;
            NSNumber* nx = entry[@"x"];
            NSNumber* ny = entry[@"y"];
            NSNumber* ns = entry[@"s"];
            if ([nx isKindOfClass:[NSNumber class]] && std::isfinite(nx.doubleValue)) {
                item.x = std::clamp<CGFloat>(nx.doubleValue, 0.02, 0.98);
            }
            if ([ny isKindOfClass:[NSNumber class]] && std::isfinite(ny.doubleValue)) {
                item.y = std::clamp<CGFloat>(ny.doubleValue, 0.03, 0.97);
            }
            if ([ns isKindOfClass:[NSNumber class]] && std::isfinite(ns.doubleValue)) {
                item.scale = std::clamp<CGFloat>(ns.doubleValue, kMinItemScale, kMaxItemScale);
            }
        }
    }
}

- (void)saveHudPreferences {
    NSMutableDictionary* itemsMap = [NSMutableDictionary dictionaryWithCapacity:_items.count];
    for (MC3HudItem* item in _items) {
        itemsMap[item.key] = @{
            @"x": @(item.x),
            @"y": @(item.y),
            @"s": @(item.scale),
        };
    }
    NSDictionary* cfg = @{
        @"globalScale": @(_globalScale),
        @"opacity": @(_hudOpacity),
        @"showFps": @(_showFps),
        @"arrowSteering": @(_useArrowSteering),
        @"items": itemsMap,
    };
    [[NSUserDefaults standardUserDefaults] setObject:cfg forKey:kHudPrefsKey];
}

- (void)applySteerStyleVisibility {
    _stickView.hidden = _useArrowSteering;
    for (UIButton* btn : _steerArrowButtons) {
        btn.hidden = !_useArrowSteering;
    }
    [_steerToggleButton setTitle:(_useArrowSteering ? @"◎" : @"◀▶") forState:UIControlStateNormal];
}

- (void)updateFpsVisibility {
    _fpsLabel.hidden = !_showFps;
}

- (void)applyHudOpacity {
    const BOOL driving = (_activeMode == UiMode::Driving);
    _drivingContainer.alpha = driving ? _hudOpacity : 0.0;
    _menuContainer.alpha = driving ? 0.0 : _hudOpacity;
    _hudEditButton.alpha = _editMode ? 1.0 : _hudOpacity;
    _fpsLabel.alpha = _hudOpacity;
}

- (void)applyActiveModeAnimated:(BOOL)animated {
    const BOOL driving = (_activeMode == UiMode::Driving);
    void (^update)(void) = ^{
        _drivingContainer.alpha = driving ? _hudOpacity : 0.0;
        _menuContainer.alpha = driving ? 0.0 : _hudOpacity;
        _hudEditButton.alpha = _editMode ? 1.0 : _hudOpacity;
        _fpsLabel.alpha = _hudOpacity;
    };
    _drivingContainer.hidden = NO;
    _menuContainer.hidden = NO;
    _drivingContainer.userInteractionEnabled = !_editMode && driving;
    _menuContainer.userInteractionEnabled = !_editMode && !driving;
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

- (BOOL)isItemVisibleInActiveMode:(MC3HudItem*)item {
    if (item.isFps) return _showFps;
    if (item.isGlobal) return YES;
    const BOOL driving = (_activeMode == UiMode::Driving);
    if (item.isDriving && !driving) return NO;
    if (item.isMenu && driving) return NO;
    if (item.view == _stickView && _useArrowSteering) return NO;
    for (UIButton* arrow : _steerArrowButtons) {
        if (item.view == arrow && !_useArrowSteering) return NO;
    }
    return YES;
}

- (void)applyLayoutForItem:(MC3HudItem*)item inBounds:(CGRect)bounds {
    const CGFloat x0 = CGRectGetMinX(bounds);
    const CGFloat y0 = CGRectGetMinY(bounds);
    const CGFloat bw = CGRectGetWidth(bounds);
    const CGFloat bh = CGRectGetHeight(bounds);
    if (bw <= 1.0 || bh <= 1.0) return;

    const CGFloat effScale = std::clamp<CGFloat>(_globalScale * item.scale, 0.50, 2.00);
    const CGFloat w = std::round(item.baseW * effScale);
    const CGFloat h = std::round(item.baseH * effScale);
    const CGFloat halfW = w * 0.5;
    const CGFloat halfH = h * 0.5;

    CGFloat cx = x0 + bw * item.x;
    CGFloat cy = y0 + bh * item.y;
    cx = std::clamp<CGFloat>(cx, x0 + halfW + 4.0, x0 + bw - halfW - 4.0);
    cy = std::clamp<CGFloat>(cy, y0 + halfH + 4.0, y0 + bh - halfH - 4.0);

    item.view.bounds = CGRectMake(0, 0, w, h);
    item.view.center = CGPointMake(cx, cy);
    item.view.layer.cornerRadius = (item.baseRadius > 0.0) ? (item.baseRadius * effScale) : (MIN(w, h) * 0.5);

    if (item.isButton) {
        UIButton* btn = (UIButton*)item.view;
        const CGFloat fontScale = std::clamp<CGFloat>(effScale, 0.72, 1.38);
        btn.titleLabel.font = [UIFont systemFontOfSize:(BaseFontSizeForStyle(item.style) * fontScale)
                                                weight:UIFontWeightHeavy];
    } else if (item.isFps) {
        const CGFloat fontScale = std::clamp<CGFloat>(effScale, 0.75, 1.35);
        _fpsLabel.font = [UIFont monospacedDigitSystemFontOfSize:(11.5 * fontScale) weight:UIFontWeightBold];
    }
}

- (void)refreshSelectionHighlight {
    for (MC3HudItem* item in _items) {
        const BOOL selected = _editMode && (item == _selectedItem);
        if (selected) {
            item.view.layer.borderWidth = 2.6;
            item.view.layer.borderColor = [UIColor colorWithRed:0.20 green:0.92 blue:1.0 alpha:1.0].CGColor;
        } else if (_editMode) {
            item.view.layer.borderWidth = 1.6;
            item.view.layer.borderColor = [UIColor colorWithRed:1.0 green:0.84 blue:0.28 alpha:0.75].CGColor;
        } else if (item.isFps) {
            item.view.layer.borderWidth = 1.0;
            item.view.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.28].CGColor;
        } else if (item.view == _stickView) {
            item.view.layer.borderWidth = 1.5;
            item.view.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.45].CGColor;
        } else {
            item.view.layer.borderWidth = (item.style == ButtonStyle::TopPill) ? 1.0 : 1.5;
            item.view.layer.borderColor = BorderColorForStyle(item.style).CGColor;
        }
    }
}

- (void)syncEditorControls {
    [_editorModeBtn setTitle:(_activeMode == UiMode::Driving ? @"DRIVE" : @"MENU") forState:UIControlStateNormal];
    [_editorSteerBtn setTitle:(_useArrowSteering ? @"ARROWS" : @"STICK") forState:UIControlStateNormal];
    [_editorFpsBtn setTitle:(_showFps ? @"FPS:ON" : @"FPS:OFF") forState:UIControlStateNormal];

    if (_selectedItem) {
        _editorTargetLabel.text = [NSString stringWithFormat:@"%@", _selectedItem.displayName];
        _sizeSlider.minimumValue = static_cast<float>(kMinItemScale);
        _sizeSlider.maximumValue = static_cast<float>(kMaxItemScale);
        _sizeSlider.value = static_cast<float>(_selectedItem.scale);
        _sizeValueLabel.text = [NSString stringWithFormat:@"BTN SIZE %.0f%%", _selectedItem.scale * 100.0];
        _editorAllBtn.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.12];
    } else {
        _editorTargetLabel.text = @"ALL CONTROLS";
        _sizeSlider.minimumValue = static_cast<float>(kMinGlobalScale);
        _sizeSlider.maximumValue = static_cast<float>(kMaxGlobalScale);
        _sizeSlider.value = static_cast<float>(_globalScale);
        _sizeValueLabel.text = [NSString stringWithFormat:@"ALL SIZE %.0f%%", _globalScale * 100.0];
        _editorAllBtn.backgroundColor = [UIColor colorWithRed:0.12 green:0.40 blue:0.58 alpha:0.90];
    }
    _opacitySlider.value = static_cast<float>(_hudOpacity);
    _opacityValueLabel.text = [NSString stringWithFormat:@"OPACITY %.0f%%", _hudOpacity * 100.0];
}

- (void)setEditModeEnabled:(BOOL)enabled {
    if (_editMode == enabled) return;
    _editMode = enabled;
    [self releaseAllControls];
    _selectedItem = nil;
    _draggingItem = nil;

    _editOverlay.hidden = !enabled;
    _editOverlay.userInteractionEnabled = enabled;
    _editorPanel.hidden = !enabled;

    const BOOL driving = (_activeMode == UiMode::Driving);
    _drivingContainer.userInteractionEnabled = !enabled && driving;
    _menuContainer.userInteractionEnabled = !enabled && !driving;

    if (enabled) {
        [self bringSubviewToFront:_editOverlay];
        [self bringSubviewToFront:_editorPanel];
        [self layoutEditorPanel];
        [self syncEditorControls];
    } else {
        [self saveHudPreferences];
    }
    [self applyHudOpacity];
    [self refreshSelectionHighlight];
}

- (void)toggleEditMode:(UIButton*)sender {
    (void)sender;
    [self setEditModeEnabled:!_editMode];
}

- (void)editorToggleMode:(UIButton*)sender {
    (void)sender;
    _selectedItem = nil;
    _manualOverride = YES;
    _activeMode = (_activeMode == UiMode::Driving) ? UiMode::Menu : UiMode::Driving;
    [self applyActiveModeAnimated:YES];
    [self syncEditorControls];
    [self refreshSelectionHighlight];
}

- (void)editorToggleSteer:(UIButton*)sender {
    (void)sender;
    [self toggleSteerStyle:nil];
    if (_selectedItem && ![self isItemVisibleInActiveMode:_selectedItem]) {
        _selectedItem = nil;
    }
    [self syncEditorControls];
    [self refreshSelectionHighlight];
}

- (void)editorToggleFps:(UIButton*)sender {
    (void)sender;
    _showFps = !_showFps;
    [self updateFpsVisibility];
    if (_selectedItem.isFps && !_showFps) {
        _selectedItem = nil;
    }
    [self saveHudPreferences];
    [self syncEditorControls];
    [self refreshSelectionHighlight];
}

- (void)editorSelectAll:(UIButton*)sender {
    (void)sender;
    _selectedItem = nil;
    [self syncEditorControls];
    [self refreshSelectionHighlight];
}

- (void)editorResetLayout:(UIButton*)sender {
    (void)sender;
    _globalScale = 1.0;
    _hudOpacity = 1.0;
    _showFps = YES;
    for (MC3HudItem* item in _items) {
        item.x = item.defaultX;
        item.y = item.defaultY;
        item.scale = 1.0;
    }
    _selectedItem = nil;
    [self updateFpsVisibility];
    [self applyHudOpacity];
    [self setNeedsLayout];
    [self layoutIfNeeded];
    [self saveHudPreferences];
    [self syncEditorControls];
    [self refreshSelectionHighlight];
}

- (void)sizeSliderChanged:(UISlider*)slider {
    if (_selectedItem) {
        _selectedItem.scale = std::clamp<CGFloat>(slider.value, kMinItemScale, kMaxItemScale);
        [self applyLayoutForItem:_selectedItem inBounds:self.bounds];
        _sizeValueLabel.text = [NSString stringWithFormat:@"BTN SIZE %.0f%%", _selectedItem.scale * 100.0];
    } else {
        _globalScale = std::clamp<CGFloat>(slider.value, kMinGlobalScale, kMaxGlobalScale);
        for (MC3HudItem* item in _items) {
            [self applyLayoutForItem:item inBounds:self.bounds];
        }
        _sizeValueLabel.text = [NSString stringWithFormat:@"ALL SIZE %.0f%%", _globalScale * 100.0];
    }
}

- (void)opacitySliderChanged:(UISlider*)slider {
    _hudOpacity = std::clamp<CGFloat>(slider.value, kMinOpacity, kMaxOpacity);
    [self applyHudOpacity];
    _opacityValueLabel.text = [NSString stringWithFormat:@"OPACITY %.0f%%", _hudOpacity * 100.0];
}

#pragma mark - MC3HudEditOverlayDelegate

- (void)hudEditBeganAtPoint:(CGPoint)pt {
    MC3HudItem* hit = nil;
    CGFloat bestDist = 1e9;
    for (MC3HudItem* item in _items) {
        if (![self isItemVisibleInActiveMode:item]) continue;
        CGRect f = item.view.frame;
        CGRect hitRect = CGRectInset(f, -8.0, -8.0);
        if (CGRectContainsPoint(hitRect, pt)) {
            const CGFloat d = std::hypot(pt.x - CGRectGetMidX(f), pt.y - CGRectGetMidY(f));
            if (d < bestDist) {
                bestDist = d;
                hit = item;
            }
        }
    }
    _selectedItem = hit;
    _draggingItem = hit;
    if (hit) {
        _dragOffset = CGPointMake(hit.view.center.x - pt.x, hit.view.center.y - pt.y);
    }
    [self syncEditorControls];
    [self refreshSelectionHighlight];
}

- (void)hudEditMovedToPoint:(CGPoint)pt {
    if (!_draggingItem) return;
    const CGRect bounds = self.bounds;
    const CGFloat bw = CGRectGetWidth(bounds);
    const CGFloat bh = CGRectGetHeight(bounds);
    if (bw <= 1.0 || bh <= 1.0) return;

    const CGFloat halfW = CGRectGetWidth(_draggingItem.view.bounds) * 0.5;
    const CGFloat halfH = CGRectGetHeight(_draggingItem.view.bounds) * 0.5;
    const CGFloat cx = std::clamp<CGFloat>(pt.x + _dragOffset.x, halfW + 4.0, bw - halfW - 4.0);
    const CGFloat cy = std::clamp<CGFloat>(pt.y + _dragOffset.y, halfH + 4.0, bh - halfH - 4.0);
    _draggingItem.x = cx / bw;
    _draggingItem.y = cy / bh;
    _draggingItem.view.center = CGPointMake(cx, cy);
}

- (void)hudEditEnded {
    if (_draggingItem) {
        _draggingItem = nil;
        [self saveHudPreferences];
    }
}

#pragma mark - Runtime HUD sync & input

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

    if (_editMode) return;

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
    [self applySteerStyleVisibility];
    [self saveHudPreferences];
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
    _drivingContainer.frame = bounds;
    _menuContainer.frame = bounds;
    _editOverlay.frame = bounds;
    for (MC3HudItem* item in _items) {
        [self applyLayoutForItem:item inBounds:bounds];
    }
    if (_editMode) {
        [self layoutEditorPanel];
    }
}

- (void)controlDown:(UIButton*)sender {
    if (_editMode) return;
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
