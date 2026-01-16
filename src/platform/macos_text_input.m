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

// Forward declaration
@class AccessibleTextInputView;

// Global state
static TextInputCallback g_callback = NULL;
static void* g_userdata = NULL;
static AccessibleTextInputView* g_textView = NULL;
static id g_textDidChangeObserver = nil;
static id g_windowDidBecomeKeyObserver = nil;
static NSWindow* g_window = NULL;
static NSInteger g_lastPasteboardChangeCount = 0;

// Custom NSTextView subclass that captures external text input but forwards
// regular keyboard events to SDL's view
@interface AccessibleTextInputView : NSTextView <NSTextViewDelegate, NSTextInputClient>
@property (nonatomic, weak) NSView* sdlContentView;
@property (nonatomic, strong) NSTextInputContext* customInputContext;
@end

@implementation AccessibleTextInputView

- (instancetype)initWithFrame:(NSRect)frameRect {
    self = [super initWithFrame:frameRect];
    if (self) {
        // Create input context immediately so the text input system can find us
        self.customInputContext = [[NSTextInputContext alloc] initWithClient:self];
    }
    return self;
}

- (BOOL)acceptsFirstResponder {
    return YES;
}

- (BOOL)becomeFirstResponder {
    return [super becomeFirstResponder];
}

- (BOOL)resignFirstResponder {
    // Always refuse to resign - we want to stay the first responder so external
    // input sources (emoji picker, dictation) can send text to us
    return NO;
}

// Forward keyboard events to SDL's content view for key handling (shortcuts, etc.)
- (void)keyDown:(NSEvent*)event {
    // Intercept Cmd+V (paste) - handle it ourselves since SDL won't receive it properly
    // when we're the first responder. This also enables apps like Superwhisper that
    // simulate Cmd+V after putting text on the pasteboard.
    NSEventModifierFlags cmdOnly = event.modifierFlags & NSEventModifierFlagDeviceIndependentFlagsMask;
    if (cmdOnly == NSEventModifierFlagCommand && event.keyCode == 9) { // 'v' key
        [self paste:nil];
        return;
    }

    if (self.sdlContentView) {
        [self.sdlContentView keyDown:event];
    }
}

- (void)keyUp:(NSEvent*)event {
    if (self.sdlContentView) {
        [self.sdlContentView keyUp:event];
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

- (void)flagsChanged:(NSEvent*)event {
    if (self.sdlContentView) {
        [self.sdlContentView flagsChanged:event];
    }
}

// Pass mouse events through to SDL's view underneath
- (NSView*)hitTest:(NSPoint)point {
    return nil;  // Make this view "transparent" to mouse clicks
}

- (BOOL)acceptsMouseMovedEvents {
    return NO;
}



// Provide our own input context since NSTextView's default one is null in this configuration
- (NSTextInputContext*)inputContext {
    return self.customInputContext;
}

// Override both insertText variants - some apps use the older one without replacementRange
- (void)insertText:(id)string {
    [self insertText:string replacementRange:NSMakeRange(NSNotFound, 0)];
}

// Override insertText to capture all text input (keyboard and external)
// We forward everything through our callback since SDL can't receive insertText
// when we're the first responder
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

    // Clear the text view after processing to keep it empty
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

        // Initialize pasteboard change count to avoid pasting stale content
        g_lastPasteboardChangeCount = [[NSPasteboard generalPasteboard] changeCount];

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
        g_textView.sdlContentView = contentView;

        // Configure the text view
        [g_textView setEditable:YES];
        [g_textView setSelectable:NO];
        [g_textView setRichText:NO];
        [g_textView setImportsGraphics:NO];
        [g_textView setAllowsUndo:NO];

        // Make it nearly transparent but still functional
        // Note: alpha=0 causes inputContext to be null, breaking text input
        [g_textView setAlphaValue:0.01];  // Nearly invisible but functional
        [g_textView setBackgroundColor:[NSColor clearColor]];
        [g_textView setDrawsBackground:NO];


        // Auto-resize with the window
        [g_textView setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];

        // Add to the window's content view
        [contentView addSubview:g_textView positioned:NSWindowAbove relativeTo:nil];

        // Make it the first responder so external input sources can find it
        [window makeFirstResponder:g_textView];

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

        // Reclaim first responder when window becomes key again
        // This is critical for receiving text from emoji picker, dictation, etc.
        g_windowDidBecomeKeyObserver = [[NSNotificationCenter defaultCenter]
            addObserverForName:NSWindowDidBecomeKeyNotification
            object:window
            queue:[NSOperationQueue mainQueue]
            usingBlock:^(NSNotification* note) {
                if (g_textView && g_window) {
                    id firstResponder = [g_window firstResponder];
                    if (firstResponder != g_textView) {
                        [g_window makeFirstResponder:g_textView];
                    }
                    // Activate the input context to signal we're ready for input
                    NSTextInputContext* ctx = [g_textView inputContext];
                    if (ctx) {
                        [ctx activate];
                    }

                    // Check if external input source (emoji picker, etc.) put text on pasteboard
                    NSPasteboard* pb = [NSPasteboard generalPasteboard];
                    NSInteger currentChangeCount = [pb changeCount];
                    if (currentChangeCount != g_lastPasteboardChangeCount) {
                        NSString* pbText = [pb stringForType:NSPasteboardTypeString];
                        g_lastPasteboardChangeCount = currentChangeCount;

                        // Send the pasteboard text through our callback
                        if (pbText && pbText.length > 0 && g_callback) {
                            g_callback([pbText UTF8String], g_userdata);
                        }
                    }
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

