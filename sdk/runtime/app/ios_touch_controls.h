#pragma once

#if defined(__APPLE__)
#include <TargetConditionals.h>
#if TARGET_OS_IPHONE
#import <UIKit/UIKit.h>

namespace app {

// Creates a UIKit touch overlay. The caller adds it above the game view and
// owns its placement and lifecycle.
UIView* CreateTouchControlsOverlay(CGRect frame);

}  // namespace app
#endif  // TARGET_OS_IPHONE
#endif  // defined(__APPLE__)
