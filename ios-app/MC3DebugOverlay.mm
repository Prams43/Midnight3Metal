// MC3DebugOverlay.mm
// In-app log viewer: shows last 20 log lines on screen.
// - Semi-transparent panel, top-left corner (landscape)
// - Tap the top-left 60x60 pt dead zone to toggle visibility
// - Useful when you don't have a Mac to read Console.app / Xcode logs

#import "MC3DebugOverlay.h"
#import <UIKit/UIKit.h>
#import <dispatch/dispatch.h>

static const NSInteger kMaxLines = 20;
static const CGFloat kPanelWidth = 480.0f;
static const CGFloat kPanelHeight = 320.0f;
static const CGFloat kFontSize = 10.5f;

@interface MC3DebugOverlay ()
@property (nonatomic, strong) UILabel* logLabel;
@property (nonatomic, strong) NSMutableArray<NSString*>* lines;
@property (nonatomic, strong) dispatch_queue_t queue;
@property (nonatomic) BOOL panelVisible;
@end

@implementation MC3DebugOverlay

+ (instancetype)sharedOverlay {
    static MC3DebugOverlay* instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[MC3DebugOverlay alloc] initWithFrame:CGRectZero];
    });
    return instance;
}

+ (void)log:(NSString*)line {
    [[MC3DebugOverlay sharedOverlay] appendLine:line];
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;

    self.userInteractionEnabled = YES;
    self.backgroundColor = UIColor.clearColor;

    _lines = [NSMutableArray arrayWithCapacity:kMaxLines + 1];
    _queue = dispatch_queue_create("mc3.debugoverlay", DISPATCH_QUEUE_SERIAL);
    _panelVisible = YES;

    // Semi-transparent background panel
    UIView* panel = [[UIView alloc] initWithFrame:CGRectMake(4, 4, kPanelWidth, kPanelHeight)];
    panel.backgroundColor = [UIColor colorWithRed:0 green:0 blue:0 alpha:0.72];
    panel.layer.cornerRadius = 6;
    panel.layer.borderWidth = 1;
    panel.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.18].CGColor;
    panel.tag = 999;
    [self addSubview:panel];

    // Log label inside panel
    _logLabel = [[UILabel alloc] initWithFrame:CGRectMake(6, 4, kPanelWidth - 12, kPanelHeight - 8)];
    _logLabel.numberOfLines = 0;
    _logLabel.font = [UIFont monospacedSystemFontOfSize:kFontSize weight:UIFontWeightRegular];
    _logLabel.textColor = [UIColor colorWithRed:0.78 green:1.0 blue:0.78 alpha:1.0];
    _logLabel.textAlignment = NSTextAlignmentLeft;
    _logLabel.lineBreakMode = NSLineBreakByTruncatingHead;
    [panel addSubview:_logLabel];

    // Title bar
    UILabel* title = [[UILabel alloc] initWithFrame:CGRectMake(6, 2, kPanelWidth - 12, 14)];
    title.text = @"▶ MC3 DEBUG LOG  (tap top-left to hide/show)";
    title.font = [UIFont monospacedSystemFontOfSize:9 weight:UIFontWeightBold];
    title.textColor = [UIColor colorWithWhite:0.6 alpha:1.0];
    [panel addSubview:title];
    _logLabel.frame = CGRectMake(6, 16, kPanelWidth - 12, kPanelHeight - 20);

    // Invisible tap zone (top-left 60x60) to toggle the panel
    UIButton* toggleBtn = [UIButton buttonWithType:UIButtonTypeCustom];
    toggleBtn.frame = CGRectMake(0, 0, 60, 60);
    toggleBtn.backgroundColor = UIColor.clearColor;
    [toggleBtn addTarget:self action:@selector(togglePanel) forControlEvents:UIControlEventTouchUpInside];
    [self addSubview:toggleBtn];

    return self;
}

- (void)togglePanel {
    UIView* panel = [self viewWithTag:999];
    _panelVisible = !_panelVisible;
    [UIView animateWithDuration:0.2 animations:^{
        panel.alpha = self->_panelVisible ? 1.0 : 0.0;
    }];
}

- (void)appendLine:(NSString*)line {
    dispatch_async(_queue, ^{
        [self->_lines addObject:line];
        if ((NSInteger)self->_lines.count > kMaxLines)
            [self->_lines removeObjectAtIndex:0];
        NSString* text = [self->_lines componentsJoinedByString:@"\n"];
        dispatch_async(dispatch_get_main_queue(), ^{
            self->_logLabel.text = text;
        });
    });
}

// Let touches pass through to views underneath except for the toggle button area
- (UIView*)hitTest:(CGPoint)point withEvent:(UIEvent*)event {
    UIView* hit = [super hitTest:point withEvent:event];
    // Only intercept the toggle button (60x60 top-left), pass everything else through
    if (hit == self) return nil;
    return hit;
}

@end
