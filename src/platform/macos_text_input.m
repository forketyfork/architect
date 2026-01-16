// macOS Accessibility Text Input Helper
//
// This hooks into SDL's window to make it properly respond to accessibility
// text input from external sources (emoji picker, speech-to-text apps).
//
// The approach: Add a custom accessibility element to the window that
// advertises itself as a text field and forwards received text to our app.

#import <AppKit/AppKit.h>
#import <objc/runtime.h>

// Callback function type for delivering text to Zig code
typedef void (*TextInputCallback)(const char* text, void* userdata);

// Constants
static const CGFloat kTextViewAlpha = 0.01;  // Nearly transparent but still functional for text input
static const unsigned short kKeyCodeV = 9;   // macOS virtual key code for 'V' key

// Forward declaration
@class AccessibleTextInputView;

// Global state
static TextInputCallback g_callback = NULL;
static void* g_userdata = NULL;
static AccessibleTextInputView* g_textView = NULL;
static id g_textDidChangeObserver = nil;
static id g_windowDidBecomeKeyObserver = nil;
static NSWindow* g_window = NULL;

// Custom NSTextView subclass that captures external text input
// SDL receives keyboard events through its own mechanism
@interface AccessibleTextInputView : NSTextView <NSTextViewDelegate>
@end

@implementation AccessibleTextInputView

- (BOOL)acceptsFirstResponder {
    return YES;
}

// Intercept Cmd+V for paste - external apps like Superwhisper simulate this
// after putting text on the pasteboard. SDL receives other keys through its own mechanism.
- (void)keyDown:(NSEvent*)event {
    NSEventModifierFlags cmdOnly = event.modifierFlags & NSEventModifierFlagDeviceIndependentFlagsMask;
    if (cmdOnly == NSEventModifierFlagCommand && event.keyCode == kKeyCodeV) {
        [self paste:nil];
    }
}

// Paste from pasteboard - handles both manual Cmd+V and apps like Superwhisper
- (void)paste:(id)sender {
    NSPasteboard* pb = [NSPasteboard generalPasteboard];
    NSString* text = [pb stringForType:NSPasteboardTypeString];
    if (text && text.length > 0 && g_callback) {
        g_callback([text UTF8String], g_userdata);
    }
}

// Prevent NSTextView from handling editing commands - SDL handles these
- (void)deleteBackward:(id)sender {}
- (void)deleteForward:(id)sender {}
- (void)deleteWordBackward:(id)sender {}
- (void)deleteWordForward:(id)sender {}

// Pass mouse events through to SDL's view underneath
- (NSView*)hitTest:(NSPoint)point {
    return nil;  // Make this view "transparent" to mouse clicks
}

- (BOOL)acceptsMouseMovedEvents {
    return NO;
}




// Override insertText to capture text input from external sources
- (void)insertText:(id)string replacementRange:(NSRange)replacementRange {
    NSString* text = nil;
    if ([string isKindOfClass:[NSAttributedString class]]) {
        text = [(NSAttributedString*)string string];
    } else if ([string isKindOfClass:[NSString class]]) {
        text = (NSString*)string;
    }

    if (text && text.length > 0 && g_callback) {
        g_callback([text UTF8String], g_userdata);
    }

    [self setString:@""];
}

// Accessibility attributes to make this view discoverable by apps like Superwhisper
- (BOOL)isAccessibilityElement {
    return YES;
}

- (NSAccessibilityRole)accessibilityRole {
    return NSAccessibilityTextAreaRole;
}

- (NSString*)accessibilityRoleDescription {
    return @"text input";
}

- (BOOL)isAccessibilityEnabled {
    return YES;
}

- (BOOL)isAccessibilityFocused {
    return [[self window] firstResponder] == self;
}

- (id)accessibilityValue {
    return @"";
}

- (void)accessibilitySetValue:(id)value forAttribute:(NSAccessibilityAttributeName)attribute {
    if ([attribute isEqualToString:NSAccessibilityValueAttribute]) {
        NSString* text = nil;
        if ([value isKindOfClass:[NSString class]]) {
            text = (NSString*)value;
        } else if ([value isKindOfClass:[NSAttributedString class]]) {
            text = [(NSAttributedString*)value string];
        }

        if (text && text.length > 0 && g_callback) {
            g_callback([text UTF8String], g_userdata);
        }
        return;
    }
    [super accessibilitySetValue:value forAttribute:attribute];
}

- (void)setAccessibilityValue:(id)accessibilityValue {
    if (accessibilityValue && g_callback) {
        NSString* text = nil;
        if ([accessibilityValue isKindOfClass:[NSString class]]) {
            text = (NSString*)accessibilityValue;
        } else if ([accessibilityValue isKindOfClass:[NSAttributedString class]]) {
            text = [(NSAttributedString*)accessibilityValue string];
        }
        if (text && text.length > 0) {
            g_callback([text UTF8String], g_userdata);
            return;
        }
    }
    [super setAccessibilityValue:accessibilityValue];
}

@end

// C interface for Zig

void macos_text_input_init(void* nswindow, TextInputCallback callback, void* userdata) {
    if (!nswindow || !callback) return;

    @autoreleasepool {
        g_callback = callback;
        g_userdata = userdata;

        NSWindow* window = (__bridge NSWindow*)nswindow;
        g_window = window;
        NSView* contentView = [window contentView];
        if (!contentView) {
            NSLog(@"[AccessibleTextInput] ERROR: No content view found");
            return;
        }

        // Create the accessible text view that covers the entire window
        // This ensures it's the target for accessibility-based text input
        NSRect frame = contentView.bounds;
        g_textView = [[AccessibleTextInputView alloc] initWithFrame:frame];

        // Configure the text view
        [g_textView setEditable:YES];
        [g_textView setSelectable:YES];
        [g_textView setRichText:NO];
        [g_textView setImportsGraphics:NO];
        [g_textView setAllowsUndo:NO];
        [g_textView setInsertionPointColor:[NSColor clearColor]];  // Hide cursor

        [g_textView setAlphaValue:kTextViewAlpha];
        [g_textView setBackgroundColor:[NSColor clearColor]];
        [g_textView setDrawsBackground:NO];

        // Auto-resize with the window
        [g_textView setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];

        // Add to the window's content view
        [contentView addSubview:g_textView positioned:NSWindowAbove relativeTo:nil];

        // Make it the first responder so external input sources can find it
        [window makeFirstResponder:g_textView];

        // Reclaim first responder when window becomes key again
        g_windowDidBecomeKeyObserver = [[NSNotificationCenter defaultCenter]
            addObserverForName:NSWindowDidBecomeKeyNotification
            object:window
            queue:[NSOperationQueue mainQueue]
            usingBlock:^(NSNotification* note) {
                if (g_textView && g_window) {
                    [g_window makeFirstResponder:g_textView];
                }
            }];

        // Observe text changes as a fallback
        g_textDidChangeObserver = [[NSNotificationCenter defaultCenter]
            addObserverForName:NSTextDidChangeNotification
            object:g_textView
            queue:[NSOperationQueue mainQueue]
            usingBlock:^(NSNotification* note) {
                NSString* text = [g_textView string];
                if (text && text.length > 0 && g_callback) {
                    g_callback([text UTF8String], g_userdata);
                    [g_textView setString:@""];
                }
            }];


    }
}

void macos_text_input_deinit(void) {
    @autoreleasepool {
        if (g_windowDidBecomeKeyObserver) {
            [[NSNotificationCenter defaultCenter] removeObserver:g_windowDidBecomeKeyObserver];
            g_windowDidBecomeKeyObserver = nil;
        }

        if (g_textDidChangeObserver) {
            [[NSNotificationCenter defaultCenter] removeObserver:g_textDidChangeObserver];
            g_textDidChangeObserver = nil;
        }

        if (g_textView) {
            [g_textView removeFromSuperview];
            g_textView = nil;
        }

        g_callback = NULL;
        g_userdata = NULL;
    }
}

void macos_text_input_focus(void) {
    @autoreleasepool {
        if (g_textView && [g_textView window]) {
            [[g_textView window] makeFirstResponder:g_textView];
        }
    }
}

void macos_text_input_unfocus(void) {
    @autoreleasepool {
        if (g_textView && [g_textView window]) {
            // Return focus to the window itself
            [[g_textView window] makeFirstResponder:nil];
        }
    }
}

// Check if the accessible text view is currently focused
int macos_text_input_is_focused(void) {
    @autoreleasepool {
        if (g_textView && [g_textView window]) {
            return [[g_textView window] firstResponder] == g_textView ? 1 : 0;
        }
        return 0;
    }
}

