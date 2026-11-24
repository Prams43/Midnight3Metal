// MC3DebugOverlay - in-app log viewer for Windows-only devs (no Mac/Console.app needed)
// Shows last N log lines on screen. Toggle visibility with a hidden tap zone.
// Add to view hierarchy AFTER all other views so it renders on top.

#pragma once
#import <UIKit/UIKit.h>

@interface MC3DebugOverlay : UIView

// Add a text line to the overlay. Thread-safe.
+ (void)log:(NSString*)line;

// Shared instance — created once, then reused.
+ (instancetype)sharedOverlay;

@end
