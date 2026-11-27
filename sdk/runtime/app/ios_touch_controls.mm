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
    Gas,
    Brake,
    Nitro,
    Drift,
    Special,
    TopPill,
    Confirm,
    Cancel,
};

struct ControlSpec {
    const char* key;
    VirtualControl control;
    const char* title;
    const char* icon;
    const char* editorName;
    CGFloat x;
    CGFloat y;
    CGFloat width;
    CGFloat height;
    CGFloat radius;  // 0 = full capsule/circle
    ButtonStyle style;
};

// Native mobile racing HUD using glossy frosted-silver icons:
// - Bottom-left: glossy analog steering stick (toggleable to left/right steer arrows)
// - Bottom-right: tall GAS pedal, wide BRAKE pedal, NOS flame, DRIFT handbrake, SPEC bolt, 2W balance
// - Top utility strip: Pause, Map, Camera, Rear View, Headlight Flash, Next Track
constexpr std::array<ControlSpec, 12> kDrivingControls{{
    {"drv_gas",   VirtualControl::TriggerR,  "GAS",   "hud_gas",       "GAS PEDAL",  0.930, 0.775, 68, 114, 18, ButtonStyle::Gas},
    {"drv_brake", VirtualControl::TriggerL,  "BRAKE", "hud_brake",     "BRAKE PEDAL",0.822, 0.825, 68,  86, 16, ButtonStyle::Brake},
    {"drv_nos",   VirtualControl::FaceX,     "NOS",   "hud_nos",       "NITRO",      0.822, 0.585, 60,  60,  0, ButtonStyle::Nitro},
    {"drv_drift", VirtualControl::FaceA,     "DRIFT", "hud_drift",     "HANDBRAKE",  0.930, 0.515, 60,  54, 14, ButtonStyle::Drift},
    {"drv_spec",  VirtualControl::ThumbL,    "SPEC",  "hud_spec",      "SPECIAL",    0.722, 0.695, 54,  45, 12, ButtonStyle::Special},
    {"drv_2w",    VirtualControl::FaceB,     "2W",    "hud_2w",        "2-WHEEL",    0.722, 0.860, 54,  45, 12, ButtonStyle::Neutral},
    {"drv_pause", VirtualControl::Start,     "PAUSE", "hud_pause",     "PAUSE",      0.046, 0.095, 40,  40, 10, ButtonStyle::TopPill},
    {"drv_map",   VirtualControl::MenuBack,  "MAP",   "hud_map",       "MAP",        0.108, 0.095, 44,  38, 10, ButtonStyle::TopPill},
    {"drv_cam",   VirtualControl::ShoulderR, "CAM",   "hud_camera",    "CAMERA",     0.172, 0.095, 40,  40, 10, ButtonStyle::TopPill},
    {"drv_rear",  VirtualControl::FaceY,     "REAR",  "hud_rear",      "REAR VIEW",  0.236, 0.095, 44,  38, 10, ButtonStyle::TopPill},
    {"drv_flash", VirtualControl::ShoulderL, "FLASH", "hud_flash",     "HIGH BEAM",  0.302, 0.095, 44,  38, 10, ButtonStyle::TopPill},
    {"drv_song",  VirtualControl::DpadRight, "NEXT",  "hud_next_song", "NEXT TRACK", 0.366, 0.095, 40,  40, 10, ButtonStyle::TopPill},
}};

// Optional digital steering pedals (when toggled from analog stick)
constexpr std::array<ControlSpec, 2> kSteerArrowControls{{
    {"drv_left",  VirtualControl::SteerLeft,  "LEFT",  "hud_left",  "STEER LEFT",  0.075, 0.775, 72, 72, 16, ButtonStyle::Neutral},
    {"drv_right", VirtualControl::SteerRight, "RIGHT", "hud_right", "STEER RIGHT", 0.192, 0.775, 72, 72, 16, ButtonStyle::Neutral},
}};

// Clean native Menu & Garage navigation HUD
constexpr std::array<ControlSpec, 13> kMenuControls{{
    {"menu_up",    VirtualControl::DpadUp,    "UP",    "hud_up",       "UP",        0.135, 0.640, 50, 50, 12, ButtonStyle::Neutral},
    {"menu_down",  VirtualControl::DpadDown,  "DOWN",  "hud_down",     "DOWN",      0.135, 0.885, 50, 50, 12, ButtonStyle::Neutral},
    {"menu_left",  VirtualControl::DpadLeft,  "LEFT",  "hud_left",     "LEFT",      0.068, 0.762, 50, 50, 12, ButtonStyle::Neutral},
    {"menu_right", VirtualControl::DpadRight, "RIGHT", "hud_right",    "RIGHT",     0.202, 0.762, 50, 50, 12, ButtonStyle::Neutral},
    {"menu_ok",    VirtualControl::Confirm,   "OK",    "hud_ok",       "CONFIRM",   0.895, 0.855, 84, 54, 14, ButtonStyle::Confirm},
    {"menu_back",  VirtualControl::FaceB,     "BACK",  "hud_back",     "BACK",      0.895, 0.695, 84, 50, 14, ButtonStyle::Cancel},
    {"menu_opts",  VirtualControl::FaceX,     "OPTS",  "hud_opts",     "OPTIONS",   0.765, 0.855, 56, 46, 12, ButtonStyle::Neutral},
    {"menu_view",  VirtualControl::FaceY,     "VIEW",  "hud_view",     "VIEW",      0.765, 0.700, 56, 46, 12, ButtonStyle::Neutral},
    {"menu_tabl",  VirtualControl::ShoulderL, "TAB-",  "hud_tab_l",    "PREV TAB",  0.066, 0.095, 48, 40, 10, ButtonStyle::TopPill},
    {"menu_tabr",  VirtualControl::ShoulderR, "TAB+",  "hud_tab_r",    "NEXT TAB",  0.136, 0.095, 48, 40, 10, ButtonStyle::TopPill},
    {"menu_zmin",  VirtualControl::TriggerL,  "ZOOM-", "hud_zoom_out", "ZOOM OUT",  0.210, 0.095, 48, 40, 10, ButtonStyle::TopPill},
    {"menu_zmout", VirtualControl::TriggerR,  "ZOOM+", "hud_zoom_in",  "ZOOM IN",   0.282, 0.095, 48, 40, 10, ButtonStyle::TopPill},
    {"menu_start", VirtualControl::Start,     "START", "hud_drive",    "START",     0.354, 0.095, 48, 40, 10, ButtonStyle::TopPill},
}};

constexpr CGFloat kStickX = 0.120;
constexpr CGFloat kStickY = 0.745;
constexpr CGFloat kStickDiameter = 122.0;
constexpr CGFloat kKnobRatio = 52.0 / 122.0;
constexpr CGFloat kStickDeadzone = 0.05;

constexpr CGFloat kSteerToggleX = 0.432;
constexpr CGFloat kModeToggleDrivingX = 0.498;
constexpr CGFloat kModeToggleMenuX = 0.432;
constexpr CGFloat kHudGearX = 0.562;
constexpr CGFloat kFpsPillX = 0.642;
constexpr CGFloat kTopBarY = 0.095;

constexpr CGFloat kDefaultMinimapX = 0.140;
constexpr CGFloat kDefaultMinimapY = 0.780;
constexpr CGFloat kMinimapBoxW = 104.0;
constexpr CGFloat kMinimapBoxH = 104.0;

constexpr CGFloat kMinItemScale = 0.60;
constexpr CGFloat kMaxItemScale = 1.60;
constexpr CGFloat kMinGlobalScale = 0.70;
constexpr CGFloat kMaxGlobalScale = 1.40;
constexpr CGFloat kMinOpacity = 0.25;
constexpr CGFloat kMaxOpacity = 1.00;

NSString* const kHudPrefsKey = @"MC3TouchHudConfig_v1";

UIImage* LoadHudIcon(const char* name) {
    if (!name || !*name) return nil;
    NSString* ns = [NSString stringWithUTF8String:name];
    NSString* path = [[NSBundle mainBundle] pathForResource:ns ofType:@"png"];
    if (!path) return nil;
    return [UIImage imageWithContentsOfFile:path];
}

CGFloat BaseFontSizeForStyle(ButtonStyle style) {
    switch (style) {
    case ButtonStyle::Gas:     return 14.0;
    case ButtonStyle::Confirm: return 13.5;
    case ButtonStyle::Nitro:
    case ButtonStyle::Cancel:  return 13.0;
    case ButtonStyle::Brake:   return 12.5;
    case ButtonStyle::Drift:   return 12.0;
    case ButtonStyle::Special: return 11.5;
    case ButtonStyle::TopPill: return 10.5;
    case ButtonStyle::Neutral:
    default:                   return 12.0;
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

BOOL ApplyButtonVisuals(UIButton* button, const char* iconName, NSString* fallbackTitle,
                        ButtonStyle style, CGFloat width, CGFloat height, CGFloat radius) {
    UIImage* iconImg = LoadHudIcon(iconName);
    button.exclusiveTouch = NO;
    button.imageView.contentMode = UIViewContentModeScaleAspectFit;
    if (iconImg) {
        [button setBackgroundImage:iconImg forState:UIControlStateNormal];
        [button setTitle:@"" forState:UIControlStateNormal];
        button.backgroundColor = UIColor.clearColor;
        button.layer.cornerRadius = (radius > 0.0) ? radius : (MIN(width, height) * 0.5);
        button.layer.borderWidth = 0.0;
        button.layer.borderColor = UIColor.clearColor.CGColor;
        button.layer.shadowOpacity = 0.0f;
        return YES;
    }

    // Fallback glass style if running outside app bundle (e.g. unit compile check)
    UIColor* bg = [UIColor colorWithRed:0.06 green:0.08 blue:0.11 alpha:0.50];
    button.backgroundColor = bg;
    [button setTitle:fallbackTitle forState:UIControlStateNormal];
    [button setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    button.titleLabel.font = [UIFont systemFontOfSize:BaseFontSizeForStyle(style) weight:UIFontWeightHeavy];
    button.titleLabel.adjustsFontSizeToFitWidth = YES;
    button.titleLabel.minimumScaleFactor = 0.65;
    button.layer.cornerRadius = (radius > 0.0) ? radius : (MIN(width, height) * 0.5);
    button.layer.borderWidth = (style == ButtonStyle::TopPill) ? 1.0 : 1.5;
    button.layer.borderColor = BorderColorForStyle(style).CGColor;
    return NO;
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
@property (nonatomic, assign) BOOL hasIcon;
@property (nonatomic, assign) BOOL isDriving;
@property (nonatomic, assign) BOOL isMenu;
@property (nonatomic, assign) BOOL isGlobal;
@property (nonatomic, assign) BOOL isButton;
@property (nonatomic, assign) BOOL isFps;
@property (nonatomic, assign) BOOL isMinimap;
@end

@implementation MC3HudItem
@end

@interface MC3AnalogStickView : UIView
- (void)resetStick;
@end

@implementation MC3AnalogStickView {
    UIImageView* _ringImageView;
    UIImageView* _knobImageView;
    UITouch* _activeTouch;
    BOOL _hasImages;
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;
    self.backgroundColor = UIColor.clearColor;
    self.opaque = NO;
    self.multipleTouchEnabled = NO;
    self.exclusiveTouch = NO;
    self.userInteractionEnabled = YES;

    UIImage* ringImg = LoadHudIcon("hud_stick_ring");
    UIImage* knobImg = LoadHudIcon("hud_stick_knob");
    _hasImages = (ringImg != nil && knobImg != nil);

    _ringImageView = [[UIImageView alloc] initWithFrame:self.bounds];
    _ringImageView.contentMode = UIViewContentModeScaleAspectFit;
    _ringImageView.userInteractionEnabled = NO;
    if (_hasImages) {
        _ringImageView.image = ringImg;
    } else {
        self.backgroundColor = [UIColor colorWithRed:0.05 green:0.07 blue:0.10 alpha:0.32];
        self.layer.borderWidth = 1.5;
        self.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.45].CGColor;
    }
    [self addSubview:_ringImageView];

    _knobImageView = [[UIImageView alloc] initWithFrame:CGRectZero];
    _knobImageView.contentMode = UIViewContentModeScaleAspectFit;
    _knobImageView.userInteractionEnabled = NO;
    if (_hasImages) {
        _knobImageView.image = knobImg;
    } else {
        _knobImageView.backgroundColor = [UIColor colorWithRed:0.85 green:0.90 blue:0.95 alpha:0.75];
        _knobImageView.layer.borderWidth = 1.5;
        _knobImageView.layer.borderColor = UIColor.whiteColor.CGColor;
    }
    [self addSubview:_knobImageView];
    [self layoutSubviews];
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    const CGFloat d = MIN(self.bounds.size.width, self.bounds.size.height);
    const CGFloat knobD = MAX(28.0, d * kKnobRatio);
    self.layer.cornerRadius = d * 0.5;
    _ringImageView.frame = self.bounds;
    _knobImageView.bounds = CGRectMake(0, 0, knobD, knobD);
    if (!_hasImages) _knobImageView.layer.cornerRadius = knobD * 0.5;
    if (!_activeTouch) {
        _knobImageView.center = CGPointMake(CGRectGetMidX(self.bounds), CGRectGetMidY(self.bounds));
    }
}

- (void)updateWithPoint:(CGPoint)pt {
    const CGPoint center = CGPointMake(CGRectGetMidX(self.bounds), CGRectGetMidY(self.bounds));
    const CGFloat d = MIN(self.bounds.size.width, self.bounds.size.height);
    const CGFloat knobD = MAX(28.0, d * kKnobRatio);
    const CGFloat maxRadius = MAX(1.0, (d - knobD) * 0.5);
    CGFloat dx = pt.x - center.x;
    CGFloat dy = pt.y - center.y;
    const CGFloat dist = std::hypot(dx, dy);
    if (dist > maxRadius) {
        const CGFloat scale = maxRadius / dist;
        dx *= scale;
        dy *= scale;
    }
    _knobImageView.center = CGPointMake(center.x + dx, center.y + dy);

    CGFloat nx = dx / maxRadius;
    CGFloat ny = -dy / maxRadius;
    if (std::fabs(nx) < kStickDeadzone) nx = 0.0;
    if (std::fabs(ny) < kStickDeadzone) ny = 0.0;
    input::SetVirtualLeftStick(static_cast<float>(nx), static_cast<float>(ny));
}

- (void)resetStick {
    _activeTouch = nil;
    _knobImageView.center = CGPointMake(CGRectGetMidX(self.bounds), CGRectGetMidY(self.bounds));
    _knobImageView.alpha = 1.0;
    input::SetVirtualLeftStick(0.0f, 0.0f);
}

- (void)touchesBegan:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)event {
    (void)event;
    if (!_activeTouch) {
        _activeTouch = [touches anyObject];
        if (_activeTouch) {
            _knobImageView.alpha = 0.88;
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
    UILabel* _minimapPreviewLabel;

    NSMutableArray<MC3HudItem*>* _items;
    MC3HudItem* _minimapItem;
    MC3HudItem* _selectedItem;
    MC3HudItem* _draggingItem;
    CGPoint _dragOffset;
    BOOL _editMode;
    CGFloat _globalScale;
    CGFloat _hudOpacity;
    BOOL _showFps;
    BOOL _showMinimap;
    BOOL _minimapCustom;

    // Floating in-game HUD & Minimap editor UI (English)
    MC3HudEditOverlayView* _editOverlay;
    UIView* _editorPanel;
    UILabel* _editorTargetLabel;
    UIButton* _editorModeBtn;
    UIButton* _editorSteerBtn;
    UIButton* _editorMapBtn;
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

- (UIButton*)makeButtonForSpec:(const ControlSpec&)spec tag:(NSInteger)tag outHasIcon:(BOOL*)outHasIcon {
    UIButton* button = [UIButton buttonWithType:UIButtonTypeCustom];
    button.tag = tag;
    NSString* title = [NSString stringWithUTF8String:spec.title];
    button.accessibilityLabel = [NSString stringWithUTF8String:spec.editorName];
    const BOOL hasIcon = ApplyButtonVisuals(button, spec.icon, title, spec.style, spec.width, spec.height, spec.radius);
    if (outHasIcon) *outHasIcon = hasIcon;
    button.frame = CGRectMake(0, 0, spec.width, spec.height);
    button.autoresizingMask = UIViewAutoresizingNone;
    [button addTarget:self action:@selector(controlDown:) forControlEvents:UIControlEventTouchDown];
    [button addTarget:self action:@selector(controlUp:) forControlEvents:UIControlEventTouchUpInside |
                                                           UIControlEventTouchUpOutside |
                                                           UIControlEventTouchCancel];
    return button;
}

- (UIButton*)makeUtilityButtonWithTitle:(NSString*)title icon:(const char*)iconName
                                  width:(CGFloat)w height:(CGFloat)h action:(SEL)action outHasIcon:(BOOL*)outHasIcon {
    UIButton* button = [UIButton buttonWithType:UIButtonTypeCustom];
    button.accessibilityLabel = title;
    const BOOL hasIcon = ApplyButtonVisuals(button, iconName, title, ButtonStyle::TopPill, w, h, 10.0);
    if (outHasIcon) *outHasIcon = hasIcon;
    button.frame = CGRectMake(0, 0, w, h);
    button.autoresizingMask = UIViewAutoresizingNone;
    [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    return button;
}

- (UIButton*)makeEditorPillWithTitle:(NSString*)title bg:(UIColor*)bg border:(UIColor*)border action:(SEL)action {
    UIButton* btn = [UIButton buttonWithType:UIButtonTypeCustom];
    [btn setTitle:title forState:UIControlStateNormal];
    [btn setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    btn.titleLabel.font = [UIFont systemFontOfSize:10.5 weight:UIFontWeightBold];
    btn.titleLabel.adjustsFontSizeToFitWidth = YES;
    btn.titleLabel.minimumScaleFactor = 0.72;
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
                       hasIcon:(BOOL)hasIcon
                     isDriving:(BOOL)isDriving
                        isMenu:(BOOL)isMenu
                      isGlobal:(BOOL)isGlobal
                      isButton:(BOOL)isButton
                         isFps:(BOOL)isFps
                     isMinimap:(BOOL)isMinimap {
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
    item.hasIcon = hasIcon;
    item.isDriving = isDriving;
    item.isMenu = isMenu;
    item.isGlobal = isGlobal;
    item.isButton = isButton;
    item.isFps = isFps;
    item.isMinimap = isMinimap;
    [_items addObject:item];
    return item;
}

- (void)buildEditorUi {
    _editOverlay = [[MC3HudEditOverlayView alloc] initWithFrame:self.bounds];
    _editOverlay.backgroundColor = [UIColor colorWithRed:0.02 green:0.04 blue:0.08 alpha:0.30];
    _editOverlay.hidden = YES;
    _editOverlay.userInteractionEnabled = NO;
    _editOverlay.delegate = self;
    _editOverlay.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self addSubview:_editOverlay];

    _editorPanel = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 540, 94)];
    _editorPanel.backgroundColor = [UIColor colorWithRed:0.06 green:0.08 blue:0.12 alpha:0.93];
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
    _editorTargetLabel.text = @"ALL CONTROLS";
    _editorTargetLabel.textColor = [UIColor colorWithRed:0.55 green:0.92 blue:1.0 alpha:1.0];
    _editorTargetLabel.font = [UIFont systemFontOfSize:11.0 weight:UIFontWeightHeavy];
    _editorTargetLabel.adjustsFontSizeToFitWidth = YES;
    _editorTargetLabel.minimumScaleFactor = 0.72;
    [_editorPanel addSubview:_editorTargetLabel];

    UIColor* neutralBg = [UIColor colorWithWhite:1.0 alpha:0.12];
    UIColor* neutralBorder = [UIColor colorWithWhite:1.0 alpha:0.30];

    _editorModeBtn = [self makeEditorPillWithTitle:@"DRIVE" bg:neutralBg border:neutralBorder action:@selector(editorToggleMode:)];
    _editorSteerBtn = [self makeEditorPillWithTitle:@"STICK" bg:neutralBg border:neutralBorder action:@selector(editorToggleSteer:)];
    _editorMapBtn = [self makeEditorPillWithTitle:@"MAP:ON" bg:neutralBg border:neutralBorder action:@selector(editorToggleMinimap:)];
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
    [_editorPanel addSubview:_editorMapBtn];
    [_editorPanel addSubview:_editorFpsBtn];
    [_editorPanel addSubview:resetBtn];
    [_editorPanel addSubview:doneBtn];

    _editorAllBtn = [self makeEditorPillWithTitle:@"ALL"
                                               bg:[UIColor colorWithRed:0.12 green:0.36 blue:0.52 alpha:0.85]
                                           border:[UIColor colorWithRed:0.35 green:0.85 blue:1.0 alpha:0.9]
                                           action:@selector(editorSelectAll:)];
    [_editorPanel addSubview:_editorAllBtn];

    _sizeValueLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _sizeValueLabel.text = @"ALL SIZE 100%";
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
    _opacityValueLabel.text = @"OPACITY 100%";
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
    const CGFloat maxW = MIN(560.0, MAX(320.0, CGRectGetWidth(bounds) - 20.0));
    const CGFloat panelH = 92.0;
    const CGFloat panelY = MAX(10.0, CGRectGetHeight(bounds) * 0.19);
    _editorPanel.frame = CGRectMake(CGRectGetMidX(bounds) - maxW * 0.5, panelY, maxW, panelH);

    const CGFloat pad = 9.0;
    const CGFloat innerW = maxW - pad * 2.0;
    const CGFloat row1Y = 9.0;
    const CGFloat row1H = 28.0;
    const CGFloat gap = 5.0;

    const CGFloat doneW = 48.0;
    const CGFloat resetW = 48.0;
    const CGFloat fpsW = 54.0;
    const CGFloat mapW = 58.0;
    const CGFloat steerW = 52.0;
    const CGFloat modeW = 48.0;
    const CGFloat rightTotal = doneW + resetW + fpsW + mapW + steerW + modeW + gap * 5.0;
    const CGFloat labelW = MAX(60.0, innerW - rightTotal - gap);

    _editorTargetLabel.frame = CGRectMake(pad, row1Y, labelW, row1H);
    CGFloat rx = maxW - pad - doneW;
    UIView* doneBtn = [_editorPanel viewWithTag:999];
    UIView* resetBtn = [_editorPanel viewWithTag:998];
    doneBtn.frame = CGRectMake(rx, row1Y, doneW, row1H);
    rx -= gap + resetW;
    resetBtn.frame = CGRectMake(rx, row1Y, resetW, row1H);
    rx -= gap + fpsW;
    _editorFpsBtn.frame = CGRectMake(rx, row1Y, fpsW, row1H);
    rx -= gap + mapW;
    _editorMapBtn.frame = CGRectMake(rx, row1Y, mapW, row1H);
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
    _showMinimap = YES;
    _minimapCustom = NO;
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

    // Draggable in-game Xbox Minimap preview box (visible ONLY while HUD Editor is open)
    _minimapPreviewLabel = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, kMinimapBoxW, kMinimapBoxH)];
    _minimapPreviewLabel.text = @"MINIMAP\nDRAG TO MOVE";
    _minimapPreviewLabel.numberOfLines = 2;
    _minimapPreviewLabel.textAlignment = NSTextAlignmentCenter;
    _minimapPreviewLabel.font = [UIFont systemFontOfSize:10.5 weight:UIFontWeightHeavy];
    _minimapPreviewLabel.textColor = [UIColor colorWithRed:0.62 green:0.95 blue:1.0 alpha:1.0];
    _minimapPreviewLabel.backgroundColor = [UIColor colorWithRed:0.06 green:0.24 blue:0.36 alpha:0.45];
    _minimapPreviewLabel.layer.cornerRadius = kMinimapBoxW * 0.5;
    _minimapPreviewLabel.layer.masksToBounds = YES;
    _minimapPreviewLabel.layer.borderWidth = 2.0;
    _minimapPreviewLabel.layer.borderColor = [UIColor colorWithRed:0.28 green:0.88 blue:1.0 alpha:0.9].CGColor;
    _minimapPreviewLabel.userInteractionEnabled = NO;
    _minimapPreviewLabel.hidden = YES;
    [self addSubview:_minimapPreviewLabel];
    _minimapItem = [self registerItemKey:@"hud_minimap" displayName:@"MINIMAP" view:_minimapPreviewLabel
                                       x:kDefaultMinimapX y:kDefaultMinimapY
                                   baseW:kMinimapBoxW baseH:kMinimapBoxH baseRadius:0.0
                                   style:ButtonStyle::Neutral hasIcon:NO
                               isDriving:NO isMenu:NO isGlobal:YES isButton:NO isFps:NO isMinimap:YES];

    // Driving controls: glossy analog steering stick + optional steer arrows + glossy pedals/actions
    _stickView = [[MC3AnalogStickView alloc] initWithFrame:CGRectMake(0, 0, kStickDiameter, kStickDiameter)];
    _stickView.autoresizingMask = UIViewAutoresizingNone;
    [_drivingContainer addSubview:_stickView];
    [self registerItemKey:@"drv_stick" displayName:@"STEER STICK" view:_stickView
                        x:kStickX y:kStickY baseW:kStickDiameter baseH:kStickDiameter baseRadius:0.0
                    style:ButtonStyle::Neutral hasIcon:YES isDriving:YES isMenu:NO isGlobal:NO isButton:NO isFps:NO isMinimap:NO];

    for (size_t i = 0; i < kSteerArrowControls.size(); ++i) {
        const auto& spec = kSteerArrowControls[i];
        BOOL hasIcon = NO;
        UIButton* btn = [self makeButtonForSpec:spec tag:static_cast<NSInteger>(spec.control) outHasIcon:&hasIcon];
        btn.hidden = YES;
        [_drivingContainer addSubview:btn];
        _steerArrowButtons[i] = btn;
        [self registerItemKey:[NSString stringWithUTF8String:spec.key]
                  displayName:[NSString stringWithUTF8String:spec.editorName]
                         view:btn x:spec.x y:spec.y baseW:spec.width baseH:spec.height baseRadius:spec.radius
                        style:spec.style hasIcon:hasIcon isDriving:YES isMenu:NO isGlobal:NO isButton:YES isFps:NO isMinimap:NO];
    }

    for (size_t i = 0; i < kDrivingControls.size(); ++i) {
        const auto& spec = kDrivingControls[i];
        BOOL hasIcon = NO;
        UIButton* btn = [self makeButtonForSpec:spec tag:static_cast<NSInteger>(spec.control) outHasIcon:&hasIcon];
        [_drivingContainer addSubview:btn];
        _drivingButtons[i] = btn;
        [self registerItemKey:[NSString stringWithUTF8String:spec.key]
                  displayName:[NSString stringWithUTF8String:spec.editorName]
                         view:btn x:spec.x y:spec.y baseW:spec.width baseH:spec.height baseRadius:spec.radius
                        style:spec.style hasIcon:hasIcon isDriving:YES isMenu:NO isGlobal:NO isButton:YES isFps:NO isMinimap:NO];
    }

    BOOL steerIcon = NO;
    _steerToggleButton = [self makeUtilityButtonWithTitle:@"STEER" icon:"hud_steer_mode" width:44 height:38
                                                   action:@selector(toggleSteerStyle:) outHasIcon:&steerIcon];
    [_drivingContainer addSubview:_steerToggleButton];
    [self registerItemKey:@"drv_steer_tog" displayName:@"STEER MODE" view:_steerToggleButton
                        x:kSteerToggleX y:kTopBarY baseW:44 baseH:38 baseRadius:10.0
                    style:ButtonStyle::TopPill hasIcon:steerIcon isDriving:YES isMenu:NO isGlobal:NO isButton:YES isFps:NO isMinimap:NO];

    BOOL menuBtnIcon = NO;
    _toMenuButton = [self makeUtilityButtonWithTitle:@"MENU" icon:"hud_menu" width:44 height:38
                                              action:@selector(toggleManualMode:) outHasIcon:&menuBtnIcon];
    [_drivingContainer addSubview:_toMenuButton];
    [self registerItemKey:@"drv_menu_tog" displayName:@"MENU MODE" view:_toMenuButton
                        x:kModeToggleDrivingX y:kTopBarY baseW:44 baseH:38 baseRadius:10.0
                    style:ButtonStyle::TopPill hasIcon:menuBtnIcon isDriving:YES isMenu:NO isGlobal:NO isButton:YES isFps:NO isMinimap:NO];

    // Menu & Garage controls
    for (size_t i = 0; i < kMenuControls.size(); ++i) {
        const auto& spec = kMenuControls[i];
        BOOL hasIcon = NO;
        UIButton* btn = [self makeButtonForSpec:spec tag:static_cast<NSInteger>(spec.control) outHasIcon:&hasIcon];
        [_menuContainer addSubview:btn];
        _menuButtons[i] = btn;
        [self registerItemKey:[NSString stringWithUTF8String:spec.key]
                  displayName:[NSString stringWithUTF8String:spec.editorName]
                         view:btn x:spec.x y:spec.y baseW:spec.width baseH:spec.height baseRadius:spec.radius
                        style:spec.style hasIcon:hasIcon isDriving:NO isMenu:YES isGlobal:NO isButton:YES isFps:NO isMinimap:NO];
    }

    BOOL driveBtnIcon = NO;
    _toDrivingButton = [self makeUtilityButtonWithTitle:@"DRIVE" icon:"hud_steer_mode" width:44 height:38
                                                 action:@selector(toggleManualMode:) outHasIcon:&driveBtnIcon];
    [_menuContainer addSubview:_toDrivingButton];
    [self registerItemKey:@"menu_drv_tog" displayName:@"DRIVE MODE" view:_toDrivingButton
                        x:kModeToggleMenuX y:kTopBarY baseW:44 baseH:38 baseRadius:10.0
                    style:ButtonStyle::TopPill hasIcon:driveBtnIcon isDriving:NO isMenu:YES isGlobal:NO isButton:YES isFps:NO isMinimap:NO];

    // Persistent HUD Editor button (visible in both Driving and Menu modes)
    BOOL gearIcon = NO;
    _hudEditButton = [self makeUtilityButtonWithTitle:@"HUD" icon:"hud_gear" width:40 height:40
                                               action:@selector(toggleEditMode:) outHasIcon:&gearIcon];
    _hudEditButton.accessibilityLabel = @"HUD Editor";
    [self addSubview:_hudEditButton];
    [self registerItemKey:@"hud_gear" displayName:@"HUD EDITOR" view:_hudEditButton
                        x:kHudGearX y:kTopBarY baseW:40 baseH:40 baseRadius:10.0
                    style:ButtonStyle::TopPill hasIcon:gearIcon isDriving:NO isMenu:NO isGlobal:YES isButton:YES isFps:NO isMinimap:NO];

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
    [self registerItemKey:@"hud_fps" displayName:@"FPS COUNTER" view:_fpsLabel
                        x:kFpsPillX y:kTopBarY baseW:62 baseH:24 baseRadius:9.0
                    style:ButtonStyle::TopPill hasIcon:NO isDriving:NO isMenu:NO isGlobal:YES isButton:NO isFps:YES isMinimap:NO];

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
    [self pushMinimapConfigToGpu];

    __weak MC3TouchControlsView* weakSelf = self;
    _modeTimer = [NSTimer scheduledTimerWithTimeInterval:0.15
                                                 repeats:YES
                                                   block:^(NSTimer* _Nonnull timer) {
        (void)timer;
        [weakSelf syncGameUiMode];
    }];
    return self;
}

- (void)pushMinimapConfigToGpu {
    gpu::MinimapConfig cfg{};
    cfg.visible = (_showMinimap == YES);
    cfg.custom = (_minimapCustom == YES);
    cfg.norm_x = static_cast<float>(std::clamp<CGFloat>(_minimapItem.x, 0.08, 0.92));
    cfg.norm_y = static_cast<float>(std::clamp<CGFloat>(_minimapItem.y, 0.12, 0.88));
    gpu::SetMinimapConfig(cfg);
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
    NSNumber* mmVis = saved[@"minimapVisible"];
    if ([mmVis isKindOfClass:[NSNumber class]]) {
        _showMinimap = mmVis.boolValue;
    }
    NSNumber* mmCust = saved[@"minimapCustom"];
    if ([mmCust isKindOfClass:[NSNumber class]]) {
        _minimapCustom = mmCust.boolValue;
    }
    NSNumber* mmX = saved[@"minimapX"];
    if ([mmX isKindOfClass:[NSNumber class]] && std::isfinite(mmX.doubleValue)) {
        _minimapItem.x = std::clamp<CGFloat>(mmX.doubleValue, 0.08, 0.92);
    }
    NSNumber* mmY = saved[@"minimapY"];
    if ([mmY isKindOfClass:[NSNumber class]] && std::isfinite(mmY.doubleValue)) {
        _minimapItem.y = std::clamp<CGFloat>(mmY.doubleValue, 0.12, 0.88);
    }

    NSDictionary* itemsMap = saved[@"items"];
    if ([itemsMap isKindOfClass:[NSDictionary class]]) {
        for (MC3HudItem* item in _items) {
            if (item.isMinimap) continue;
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
        @"minimapVisible": @(_showMinimap),
        @"minimapCustom": @(_minimapCustom),
        @"minimapX": @(_minimapItem.x),
        @"minimapY": @(_minimapItem.y),
        @"items": itemsMap,
    };
    [[NSUserDefaults standardUserDefaults] setObject:cfg forKey:kHudPrefsKey];
}

- (void)applySteerStyleVisibility {
    _stickView.hidden = _useArrowSteering;
    for (UIButton* btn : _steerArrowButtons) {
        btn.hidden = !_useArrowSteering;
    }
}

- (void)updateFpsVisibility {
    _fpsLabel.hidden = !_showFps;
}

- (void)updateMinimapPreviewVisibility {
    _minimapPreviewLabel.hidden = !(_editMode && _showMinimap);
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
    if (item.isMinimap) return _editMode && _showMinimap;
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

    const CGFloat effScale = item.isMinimap ? 1.0 : std::clamp<CGFloat>(_globalScale * item.scale, 0.50, 2.00);
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

    if (item.isButton && !item.hasIcon) {
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
            item.view.layer.borderWidth = item.isMinimap ? 2.0 : 1.5;
            item.view.layer.borderColor = item.isMinimap
                ? [UIColor colorWithRed:0.28 green:0.88 blue:1.0 alpha:0.90].CGColor
                : [UIColor colorWithRed:1.0 green:0.84 blue:0.28 alpha:0.75].CGColor;
        } else if (item.hasIcon) {
            item.view.layer.borderWidth = 0.0;
            item.view.layer.borderColor = UIColor.clearColor.CGColor;
        } else if (item.isFps) {
            item.view.layer.borderWidth = 1.0;
            item.view.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.28].CGColor;
        } else {
            item.view.layer.borderWidth = (item.style == ButtonStyle::TopPill) ? 1.0 : 1.5;
            item.view.layer.borderColor = BorderColorForStyle(item.style).CGColor;
        }
    }
}

- (void)syncEditorControls {
    [_editorModeBtn setTitle:(_activeMode == UiMode::Driving ? @"DRIVE" : @"MENU") forState:UIControlStateNormal];
    [_editorSteerBtn setTitle:(_useArrowSteering ? @"ARROWS" : @"STICK") forState:UIControlStateNormal];
    [_editorMapBtn setTitle:(_showMinimap ? @"MAP:ON" : @"MAP:OFF") forState:UIControlStateNormal];
    [_editorFpsBtn setTitle:(_showFps ? @"FPS:ON" : @"FPS:OFF") forState:UIControlStateNormal];

    if (_selectedItem && _selectedItem.isMinimap) {
        _editorTargetLabel.text = @"MINIMAP";
        _sizeSlider.enabled = NO;
        _sizeValueLabel.text = @"DRAG TO MOVE";
        _editorAllBtn.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.12];
    } else if (_selectedItem) {
        _editorTargetLabel.text = _selectedItem.displayName;
        _sizeSlider.enabled = YES;
        _sizeSlider.minimumValue = static_cast<float>(kMinItemScale);
        _sizeSlider.maximumValue = static_cast<float>(kMaxItemScale);
        _sizeSlider.value = static_cast<float>(_selectedItem.scale);
        _sizeValueLabel.text = [NSString stringWithFormat:@"BTN SIZE %.0f%%", _selectedItem.scale * 100.0];
        _editorAllBtn.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.12];
    } else {
        _editorTargetLabel.text = @"ALL CONTROLS";
        _sizeSlider.enabled = YES;
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
    [self updateMinimapPreviewVisibility];

    const BOOL driving = (_activeMode == UiMode::Driving);
    _drivingContainer.userInteractionEnabled = !enabled && driving;
    _menuContainer.userInteractionEnabled = !enabled && !driving;

    if (enabled) {
        [self bringSubviewToFront:_minimapPreviewLabel];
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

- (void)editorToggleMinimap:(UIButton*)sender {
    (void)sender;
    _showMinimap = !_showMinimap;
    [self updateMinimapPreviewVisibility];
    if (_selectedItem.isMinimap && !_showMinimap) {
        _selectedItem = nil;
    }
    [self pushMinimapConfigToGpu];
    [self saveHudPreferences];
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
    _showMinimap = YES;
    _minimapCustom = NO;
    for (MC3HudItem* item in _items) {
        item.x = item.defaultX;
        item.y = item.defaultY;
        item.scale = 1.0;
    }
    _selectedItem = nil;
    [self updateFpsVisibility];
    [self updateMinimapPreviewVisibility];
    [self pushMinimapConfigToGpu];
    [self applyHudOpacity];
    [self setNeedsLayout];
    [self layoutIfNeeded];
    [self saveHudPreferences];
    [self syncEditorControls];
    [self refreshSelectionHighlight];
}

- (void)sizeSliderChanged:(UISlider*)slider {
    if (_selectedItem && !_selectedItem.isMinimap) {
        _selectedItem.scale = std::clamp<CGFloat>(slider.value, kMinItemScale, kMaxItemScale);
        [self applyLayoutForItem:_selectedItem inBounds:self.bounds];
        _sizeValueLabel.text = [NSString stringWithFormat:@"BTN SIZE %.0f%%", _selectedItem.scale * 100.0];
    } else if (!_selectedItem) {
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
    if (_draggingItem.isMinimap) {
        _minimapCustom = YES;
        [self pushMinimapConfigToGpu];
    }
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
    sender.transform = CGAffineTransformMakeScale(0.93, 0.93);
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
