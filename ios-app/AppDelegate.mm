#import "AppDelegate.h"
#import "ViewController.h"

@implementation AppDelegate

- (BOOL)application:(UIApplication*)application didFinishLaunchingWithOptions:(NSDictionary*)launchOptions {
    self.window = [[UIWindow alloc] initWithFrame:[[UIScreen mainScreen] bounds]];

    ViewController* viewController = [[ViewController alloc] init];
    self.window.rootViewController = viewController;

    [self.window makeKeyAndVisible];

    return YES;
}

- (void)applicationWillResignActive:(UIApplication*)application {
    // Pause game loop when app moves to background
}

- (void)applicationDidEnterBackground:(UIApplication*)application {
    // Save state if needed
}

- (void)applicationWillEnterForeground:(UIApplication*)application {
    // Prepare to resume
}

- (void)applicationDidBecomeActive:(UIApplication*)application {
    // Resume game loop
}

- (void)applicationWillTerminate:(UIApplication*)application {
    // Cleanup before termination
}

@end
