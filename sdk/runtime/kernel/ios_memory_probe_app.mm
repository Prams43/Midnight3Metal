#import <UIKit/UIKit.h>

extern "C" bool MC3RunIOSMemoryProbe(void);

@interface MC3MemoryProbeViewController : UIViewController
@end

@implementation MC3MemoryProbeViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.systemBackgroundColor;

    UILabel* result = [[UILabel alloc] initWithFrame:CGRectZero];
    result.translatesAutoresizingMaskIntoConstraints = NO;
    result.numberOfLines = 0;
    result.textAlignment = NSTextAlignmentCenter;
    result.font = [UIFont preferredFontForTextStyle:UIFontTextStyleTitle2];
    result.text = @"Running guest-memory probe…";
    [self.view addSubview:result];
    [NSLayoutConstraint activateConstraints:@[
        [result.leadingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.leadingAnchor constant:24],
        [result.trailingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.trailingAnchor constant:-24],
        [result.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor],
    ]];

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        const BOOL passed = MC3RunIOSMemoryProbe();
        dispatch_async(dispatch_get_main_queue(), ^{
            result.text = passed ? @"Guest-memory probe passed\n4 GiB reservation and shared aliases work on this run."
                                 : @"Guest-memory probe failed\nSee the Xcode device console for the failing step.";
            result.textColor = passed ? UIColor.systemGreenColor : UIColor.systemRedColor;
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

