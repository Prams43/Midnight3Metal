#import <UIKit/UIKit.h>
#include <cstddef>

extern "C" bool MC3RunIOSMemoryProbe(char* failure, size_t failureCapacity);

@interface MC3MemoryProbeViewController : UIViewController
@end

@implementation MC3MemoryProbeViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.systemBackgroundColor;

    UILabel* result = [[UILabel alloc] initWithFrame:(CGRect){0, 0, 0, 0}];
    result.translatesAutoresizingMaskIntoConstraints = NO;
    result.numberOfLines = 0;
    result.textAlignment = NSTextAlignmentCenter;
    result.font = [UIFont preferredFontForTextStyle:UIFontTextStyleTitle2];
    result.adjustsFontSizeToFitWidth = YES;
    result.minimumScaleFactor = 0.75;
    result.text = @"Running guest-memory probe…";
    [self.view addSubview:result];
    [NSLayoutConstraint activateConstraints:@[
        [result.leadingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.leadingAnchor constant:24],
        [result.trailingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.trailingAnchor constant:-24],
        [result.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor],
    ]];

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        char failure[256] = {0};
        const BOOL passed = MC3RunIOSMemoryProbe(failure, sizeof(failure));
        NSString* failureText = passed
            ? nil
            : (failure[0] != '\0'
                ? [NSString stringWithUTF8String:failure]
                : @"Unknown failure (no diagnostic was returned)");
        dispatch_async(dispatch_get_main_queue(), ^{
            if (passed) {
                result.text = @"Guest-memory probe passed\n4 GiB reservation, shared aliases, and page cycle passed on this run.";
                result.textColor = UIColor.systemGreenColor;
            } else {
                result.text = [NSString stringWithFormat:@"Guest-memory probe failed\n%@", failureText];
                result.textColor = UIColor.systemRedColor;
            }
        });
    });
}

@end

@interface MC3MemoryProbeAppDelegate : UIResponder <UIApplicationDelegate>
@property(nonatomic, strong) UIWindow* window;
@end

@implementation MC3MemoryProbeAppDelegate

- (BOOL)application:(UIApplication*)application didFinishLaunchingWithOptions:(NSDictionary*)options {
    (void)application;
    (void)options;
    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    self.window.rootViewController = [[MC3MemoryProbeViewController alloc] init];
    [self.window makeKeyAndVisible];
    return YES;
}

@end

int main(int argc, char* argv[]) {
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass(MC3MemoryProbeAppDelegate.class));
    }
}
