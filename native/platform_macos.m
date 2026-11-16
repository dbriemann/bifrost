#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <sys/file.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <unistd.h>

// raylib's bundled GLFW exports these public Cocoa/native-handle APIs.
extern int glfwInit(void);
extern int glfwGetPlatform(void);
extern void *glfwGetCurrentContext(void);
extern NSWindow *glfwGetCocoaWindow(void *);
extern void glfwSetWindowSizeLimits(void *, int, int, int, int);
extern void glfwGetFramebufferSize(void *, int *, int *);
extern unsigned char *rlReadScreenPixels(int, int);

@interface BFWindow : NSObject
@property(nonatomic, assign) AXUIElementRef element;
@property(nonatomic) pid_t pid;
@end
@implementation BFWindow
- (void)dealloc { if (_element) CFRelease(_element); }
@end

// Backdrops never become key, consume input, or capture the screen.
@interface BFBackdrop : NSPanel
@end
@implementation BFBackdrop
- (BOOL)canBecomeKeyWindow { return NO; }
- (BOOL)canBecomeMainWindow { return NO; }
@end

static NSString *last_error;
static NSString *token;
static NSMutableDictionary<NSString *, BFWindow *> *targets;
static NSMutableDictionary<NSString *, NSURL *> *applications;
static NSRunningApplication *previous_app;
static AXUIElementRef previous_window;
static NSScreen *picker_screen;
static NSMutableArray<NSWindow *> *backdrops;
static NSMutableDictionary<NSString *, NSString *> *icon_cache;
static NSString *icon_directory;
static int lock_fd = -1, command_fd = -1;
static char socket_path[sizeof(((struct sockaddr_un *)0)->sun_path)];

static void error_set(NSString *message) { last_error = message ?: @"Unknown error"; }
const char *bf_error(void) { return last_error.UTF8String ?: ""; }
void bf_free(void *value) { free(value); }
static char *json_result(id object) {
    NSError *error = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:object options:0 error:&error];
    if (!data) { error_set(error.localizedDescription); return NULL; }
    return strdup([[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding].UTF8String);
}
static char *rejected(NSString *message) { return json_result(@{@"ok": @NO, @"error": message}); }

static id ax_value(AXUIElementRef element, CFStringRef attribute) {
    CFTypeRef value = NULL;
    if (AXUIElementCopyAttributeValue(element, attribute, &value) != kAXErrorSuccess) return nil;
    return CFBridgingRelease(value);
}
static NSString *ax_string(AXUIElementRef element, CFStringRef attribute) {
    id value = ax_value(element, attribute);
    return [value isKindOfClass:NSString.class] ? value : @"";
}
static BOOL trusted(void) {
    if (AXIsProcessTrusted()) return YES;
    error_set([NSString stringWithFormat:@"Accessibility permission is required for this build. Run bifrost authorize to open System Settings > Privacy & Security > Accessibility. If Bifrost is already listed, remove it with the minus button, then add %@ with the plus button and enable it. Launch through the installed bifrost command or Finder.", NSBundle.mainBundle.bundlePath]);
    return NO;
}
int bf_request_access(void) {
    [NSApplication sharedApplication];
    NSDictionary *options = @{(__bridge NSString *)kAXTrustedCheckOptionPrompt: @YES};
    if (AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef)options)) return 1;
    trusted();
    [NSWorkspace.sharedWorkspace openURL:[NSURL URLWithString:@"x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"]];
    return 0;
}
static NSInteger screen_for_rect(CGRect bounds) {
    CGFloat top = NSMaxY(NSScreen.screens.firstObject.frame);
    NSRect rect = NSMakeRect(bounds.origin.x, top - CGRectGetMaxY(bounds), bounds.size.width, bounds.size.height);
    CGFloat best = 0;
    NSInteger monitor = -1;
    for (NSUInteger i = 0; i < NSScreen.screens.count; i++) {
        NSRect overlap = NSIntersectionRect(rect, NSScreen.screens[i].frame);
        CGFloat area = overlap.size.width * overlap.size.height;
        if (area > best) { best = area; monitor = (NSInteger)i; }
    }
    return monitor;
}
static NSScreen *pointer_screen(void) {
    for (NSScreen *screen in NSScreen.screens)
        if (NSPointInRect(NSEvent.mouseLocation, screen.frame)) return screen;
    return NSScreen.mainScreen ?: NSScreen.screens.firstObject;
}
static void clear_backdrops(void) {
    for (NSWindow *window in backdrops) [window orderOut:nil];
    backdrops = nil;
}
static NSWindow *picker_window(void) {
    void *context = glfwGetCurrentContext();
    return context ? glfwGetCocoaWindow(context) : nil;
}
static BOOL activate_app(NSRunningApplication *app) {
    if (@available(macOS 14.0, *)) {
        [NSApp yieldActivationToApplication:app];
        return [app activateFromApplication:NSRunningApplication.currentApplication options:0];
    }
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    return [app activateWithOptions:NSApplicationActivateIgnoringOtherApps];
#pragma clang diagnostic pop
}
static void present(BOOL backdrop) {
    NSWindow *window = picker_window();
    if (!window) return;
    if (!picker_screen) picker_screen = pointer_screen();
    NSRect area = picker_screen.visibleFrame, frame = window.frame;
    [window setFrameOrigin:NSMakePoint(NSMidX(area)-frame.size.width/2, NSMidY(area)-frame.size.height/2)];
    window.level = NSFloatingWindowLevel + 1;
    window.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces | NSWindowCollectionBehaviorFullScreenAuxiliary;
    window.hidesOnDeactivate = YES;
    window.animationBehavior = NSWindowAnimationBehaviorNone;
    if (backdrop && !backdrops) {
        backdrops = [NSMutableArray array];
        for (NSScreen *screen in NSScreen.screens) {
            BFBackdrop *panel = [[BFBackdrop alloc] initWithContentRect:screen.frame
                styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered defer:NO];
            panel.level = NSFloatingWindowLevel;
            panel.collectionBehavior = window.collectionBehavior;
            panel.hidesOnDeactivate = YES;
            panel.ignoresMouseEvents = YES;
            panel.opaque = NO;
            panel.backgroundColor = [NSColor colorWithWhite:0 alpha:0.45];
            panel.hasShadow = NO;
            panel.animationBehavior = NSWindowAnimationBehaviorNone;
            [panel orderFront:nil];
            [backdrops addObject:panel];
        }
    } else if (!backdrop) clear_backdrops();
    [NSApp activateIgnoringOtherApps:YES];
    [window makeKeyAndOrderFront:nil];
}

static char *snapshot(void) {
    if (!trusted()) return NULL;
    if (previous_window) { CFRelease(previous_window); previous_window = NULL; }
    previous_app = NSWorkspace.sharedWorkspace.frontmostApplication;
    if (previous_app && previous_app.processIdentifier != getpid()) {
        AXUIElementRef app = AXUIElementCreateApplication(previous_app.processIdentifier);
        AXUIElementSetMessagingTimeout(app, 0.25);
        CFTypeRef focused = NULL;
        if (AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute, &focused) == kAXErrorSuccess) {
            if (CFGetTypeID(focused) == AXUIElementGetTypeID()) previous_window = (AXUIElementRef)focused;
            else CFRelease(focused);
        }
        CFRelease(app);
    }
    targets = [NSMutableDictionary dictionary];
    token = NSUUID.UUID.UUIDString;
    picker_screen = pointer_screen();
    if (!picker_screen) { error_set(@"No macOS display is available"); return NULL; }
    NSMutableArray *windows = [NSMutableArray array];
    for (NSRunningApplication *running in NSWorkspace.sharedWorkspace.runningApplications) {
        if (running.processIdentifier == getpid() || running.activationPolicy != NSApplicationActivationPolicyRegular || running.terminated) continue;
        NSString *identity = running.bundleIdentifier;
        if (!identity.length) continue; // Stable bundle identities only; never persist PIDs.
        AXUIElementRef app = AXUIElementCreateApplication(running.processIdentifier);
        AXUIElementSetMessagingTimeout(app, 0.25);
        CFTypeRef value = NULL;
        AXError result = AXUIElementCopyAttributeValue(app, kAXWindowsAttribute, &value);
        CFRelease(app);
        if (result != kAXErrorSuccess) {
            fprintf(stderr, "bifrost: cannot enumerate %s windows (Accessibility error %d)\n", identity.UTF8String, result);
            continue;
        }
        if (CFGetTypeID(value) != CFArrayGetTypeID()) { CFRelease(value); continue; }
        CFArrayRef list = (CFArrayRef)value;
        for (CFIndex i = 0; i < CFArrayGetCount(list) && i < 200; i++) {
            AXUIElementRef element = (AXUIElementRef)CFArrayGetValueAtIndex(list, i);
            if (CFGetTypeID(element) != AXUIElementGetTypeID()) continue;
            AXUIElementSetMessagingTimeout(element, 0.25);
            NSString *role = ax_string(element, kAXRoleAttribute);
            NSString *subrole = ax_string(element, kAXSubroleAttribute);
            if (![role isEqualToString:(__bridge NSString *)kAXWindowRole]) continue;
            if (subrole.length && ![subrole isEqualToString:(__bridge NSString *)kAXStandardWindowSubrole] &&
                ![subrole isEqualToString:(__bridge NSString *)kAXDialogSubrole]) continue;
            CGPoint position = {0}; CGSize size = {0};
            id p = ax_value(element, kAXPositionAttribute), s = ax_value(element, kAXSizeAttribute);
            BOOL bounds = p && s && CFGetTypeID((__bridge CFTypeRef)p) == AXValueGetTypeID() &&
                CFGetTypeID((__bridge CFTypeRef)s) == AXValueGetTypeID() &&
                AXValueGetValue((__bridge AXValueRef)p, kAXValueCGPointType, &position) &&
                AXValueGetValue((__bridge AXValueRef)s, kAXValueCGSizeType, &size);
            if (bounds && (size.width <= 0 || size.height <= 0)) continue;
            NSString *wid = NSUUID.UUID.UUIDString;
            BFWindow *target = [BFWindow new];
            target.element = (AXUIElementRef)CFRetain(element);
            target.pid = running.processIdentifier;
            targets[wid] = target;
            NSString *name = running.localizedName ?: identity;
            NSString *title = ax_string(element, kAXTitleAttribute);
            [windows addObject:@{@"id": wid, @"app": identity, @"name": name,
                @"title": title.length ? title : name, @"icon": running.bundleURL.path ?: @"",
                @"workspace": @(-1), @"monitor": @(bounds ? screen_for_rect((CGRect){position,size}) : -1)}];
        }
        CFRelease(list);
    }
    if (!trusted()) return NULL;
    NSRect area = picker_screen.visibleFrame;
    return json_result(@{@"version": @1, @"token": token, @"generation": token,
        @"workspace": @(-1), @"monitor": @([NSScreen.screens indexOfObject:picker_screen]),
        @"width": @((int)area.size.width), @"height": @((int)area.size.height), @"windows": windows});
}

// Scan standard application roots without following symlinks or traversing app
// contents. Path identities distinguish apps without a bundle identifier.
static char *catalogue(void) {
    applications = [NSMutableDictionary dictionary];
    NSMutableArray *apps = [NSMutableArray array];
    NSArray *roots = @[@"/Applications", @"/System/Applications", @"/System/Library/CoreServices/Applications",
        [NSHomeDirectory() stringByAppendingPathComponent:@"Applications"]];
    NSFileManager *manager = NSFileManager.defaultManager;
    NSMutableArray<NSURL *> *bundles = [NSMutableArray array];
    for (NSString *root in roots) {
        NSDirectoryEnumerator *enumerator = [manager enumeratorAtURL:[NSURL fileURLWithPath:root]
            includingPropertiesForKeys:@[NSURLIsSymbolicLinkKey] options:NSDirectoryEnumerationSkipsHiddenFiles errorHandler:nil];
        for (NSURL *url in enumerator) {
            NSNumber *symlink = nil;
            [url getResourceValue:&symlink forKey:NSURLIsSymbolicLinkKey error:nil];
            if (symlink.boolValue) { [enumerator skipDescendants]; continue; }
            if (![url.pathExtension.lowercaseString isEqualToString:@"app"]) continue;
            [enumerator skipDescendants];
            [bundles addObject:url];
        }
    }
    for (NSURL *url in bundles) {
        NSBundle *bundle = [NSBundle bundleWithURL:url];
        if (!bundle.executableURL || [bundle.bundleIdentifier isEqualToString:@"org.bifrost.picker"]) continue;
        if ([[bundle objectForInfoDictionaryKey:@"LSBackgroundOnly"] boolValue] ||
            [[bundle objectForInfoDictionaryKey:@"LSUIElement"] boolValue]) continue;
        NSString *identity = bundle.bundleIdentifier ?: url.path;
        if (applications[identity]) continue;
        applications[identity] = url;
        NSString *name = [bundle objectForInfoDictionaryKey:@"CFBundleDisplayName"] ?:
            [bundle objectForInfoDictionaryKey:@"CFBundleName"] ?: url.lastPathComponent.stringByDeletingPathExtension;
        [apps addObject:@{@"id": identity, @"name": name, @"description": url.path,
            @"keywords": @"", @"executable": bundle.executableURL.lastPathComponent ?: @"", @"icon": url.path}];
    }
    return json_result(@{@"version": @1, @"apps": apps});
}

char *bf_call(const char *method, const char *input) {
    @autoreleasepool {
        error_set(@"");
        NSData *data = [[NSString stringWithUTF8String:input ?: "{}"] dataUsingEncoding:NSUTF8StringEncoding];
        id request = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        if (![request isKindOfClass:NSDictionary.class]) { error_set(@"Invalid native request"); return NULL; }
        NSString *operation = [NSString stringWithUTF8String:method ?: ""];
        if ([operation isEqualToString:@"Snapshot"]) return snapshot();
        BOOL preview = [request[@"token"] isEqual:@"demo"];
        if ((!token || ![request[@"token"] isEqual:token]) && !preview) return rejected(@"Picker session has expired");
        if ([operation isEqualToString:@"Present"]) {
            if (!picker_window()) return rejected(@"Picker window is unavailable");
            present(!preview && [request[@"backdrop"] boolValue]);
            return json_result(@{@"ok": @YES});
        }
        if (preview) return rejected(@"Preview cannot control applications");
        if ([operation isEqualToString:@"Applications"]) return catalogue();
        if ([operation isEqualToString:@"Activate"]) {
            if (!trusted()) return rejected(last_error);
            BFWindow *target = targets[request[@"id"]];
            NSRunningApplication *app = target ? [NSRunningApplication runningApplicationWithProcessIdentifier:target.pid] : nil;
            if (!app || app.terminated || !ax_string(target.element, kAXRoleAttribute).length)
                return rejected(@"The selected window is no longer available");
            if ([ax_value(target.element, kAXMinimizedAttribute) boolValue] &&
                AXUIElementSetAttributeValue(target.element, kAXMinimizedAttribute, kCFBooleanFalse) != kAXErrorSuccess)
                return rejected(@"The application rejected unminimizing this window");
            [app unhide];
            AXError raised = AXUIElementPerformAction(target.element, kAXRaiseAction);
            if (raised != kAXErrorSuccess) return rejected([NSString stringWithFormat:@"The application rejected window selection (Accessibility error %d)", raised]);
            // Some apps expose raise but not writable main/focused attributes.
            AXUIElementSetAttributeValue(target.element, kAXMainAttribute, kCFBooleanTrue);
            AXUIElementSetAttributeValue(target.element, kAXFocusedAttribute, kCFBooleanTrue);
            if (!activate_app(app)) { present(backdrops != nil); return rejected(@"The application rejected activation"); }
            clear_backdrops();
            return json_result(@{@"ok": @YES});
        }
        if ([operation isEqualToString:@"Launch"]) {
            NSURL *url = applications[request[@"id"]];
            if (!url || ![NSFileManager.defaultManager fileExistsAtPath:url.path]) return rejected(@"The selected application is no longer available");
            __block BOOL finished = NO;
            __block NSError *launch_error = nil;
            NSWorkspaceOpenConfiguration *config = NSWorkspaceOpenConfiguration.configuration;
            if (@available(macOS 14.0, *)) {
                NSString *identity = [NSBundle bundleWithURL:url].bundleIdentifier;
                if (identity) [NSApp yieldActivationToApplicationWithBundleIdentifier:identity];
            }
            [NSWorkspace.sharedWorkspace openApplicationAtURL:url configuration:config
                completionHandler:^(NSRunningApplication *app, NSError *error) {
                    (void)app;
                    // Serialize result access onto the thread pumping this loop.
                    dispatch_async(dispatch_get_main_queue(), ^{ launch_error = error; finished = YES; });
                }];
            NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:10];
            while (!finished && deadline.timeIntervalSinceNow > 0)
                [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
            if (!finished) return rejected(@"Timed out waiting for macOS to launch the application");
            if (launch_error) return rejected(launch_error.localizedDescription);
            clear_backdrops();
            return json_result(@{@"ok": @YES});
        }
        if ([operation isEqualToString:@"Dismiss"]) {
            clear_backdrops();
            if (NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier == getpid() && previous_app && !previous_app.terminated) {
                activate_app(previous_app);
                if (previous_window && AXIsProcessTrusted()) AXUIElementPerformAction(previous_window, kAXRaiseAction);
            }
            token = nil; targets = nil; applications = nil;
            return json_result(@{@"ok": @YES});
        }
        error_set(@"Unknown native operation"); return NULL;
    }
}

int bf_instance(const char *request) {
    char directory[PATH_MAX], lock_path[PATH_MAX];
    const char *override = getenv("BIFROST_RUNTIME_DIR");
    if (override && *override) strlcpy(directory, override, sizeof directory);
    else snprintf(directory, sizeof directory, "/tmp/bifrost-%u", getuid());
    if (directory[0] != '/' || strlen(directory) + 9 >= sizeof socket_path) {
        error_set(@"Bifrost runtime path must be absolute and fit a Unix socket address"); return -1;
    }
    if (mkdir(directory, 0700) && errno != EEXIST) { error_set(@"Cannot create private runtime directory"); return -1; }
    struct stat info;
    if (lstat(directory, &info) || !S_ISDIR(info.st_mode) || info.st_uid != getuid() || (info.st_mode & 0777) != 0700) {
        error_set(@"Unsafe Bifrost runtime directory (expected a private, user-owned directory)"); return -1;
    }
    snprintf(lock_path, sizeof lock_path, "%s/lock", directory);
    snprintf(socket_path, sizeof socket_path, "%s/command", directory);
    lock_fd = open(lock_path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0600);
    if (lock_fd < 0) { error_set(@"Cannot open instance lock"); return -1; }
    struct sockaddr_un address = {.sun_family = AF_UNIX};
    strlcpy(address.sun_path, socket_path, sizeof address.sun_path);
    address.sun_len = sizeof address;
    if (flock(lock_fd, LOCK_EX | LOCK_NB)) {
        if (errno != EWOULDBLOCK) { error_set(@"Cannot acquire instance lock"); return -1; }
        close(lock_fd); lock_fd = -1;
        int sender = socket(AF_UNIX, SOCK_DGRAM, 0);
        // Owner may be between locking and binding; retry only that startup race.
        ssize_t sent = -1;
        for (int i = 0; sender >= 0 && i < 50; i++) {
            sent = sendto(sender, request, strlen(request), 0, (struct sockaddr *)&address, sizeof address);
            if (sent >= 0 || (errno != ENOENT && errno != ECONNREFUSED)) break;
            usleep(10000);
        }
        if (sender >= 0) close(sender);
        if (sent < 0) { error_set(@"Cannot contact the visible picker; try again"); return -1; }
        return 0;
    }
    if (!strcmp(request, "hide")) { close(lock_fd); lock_fd = -1; return 0; }
    unlink(socket_path); // Stale socket is removed only while holding the lock.
    command_fd = socket(AF_UNIX, SOCK_DGRAM, 0);
    if (command_fd < 0 || bind(command_fd, (struct sockaddr *)&address, sizeof address) ||
        fcntl(command_fd, F_SETFL, O_NONBLOCK) < 0 || fcntl(command_fd, F_SETFD, FD_CLOEXEC) < 0) {
        error_set(@"Cannot create the picker command socket"); return -1;
    }
    return 1;
}
char *bf_poll(void) {
    if (command_fd < 0) return NULL;
    char command[64];
    ssize_t size = recv(command_fd, command, sizeof command - 1, 0);
    if (size <= 0) return NULL;
    command[size] = 0;
    return strdup(command);
}
int bf_display_prepare(void) {
    [NSApplication sharedApplication];
    [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
    if (!glfwInit()) { error_set(@"GLFW could not connect to the macOS window server"); return 0; }
    return 1;
}
int bf_display_active(void) { return glfwGetPlatform() == 0x00060002; } // GLFW_PLATFORM_COCOA
void bf_window_size_limits(int width, int height) {
    glfwSetWindowSizeLimits(glfwGetCurrentContext(), width, height, width, height);
}
void *bf_screen_pixels(int *width, int *height) {
    void *window = glfwGetCurrentContext();
    if (!window) return NULL;
    glfwGetFramebufferSize(window, width, height);
    if (*width <= 0 || *height <= 0) return NULL;
    // Capture only our OpenGL framebuffer. No desktop capture permission.
    return rlReadScreenPixels(*width, *height);
}

char *bf_icon(const char *description) {
    @autoreleasepool {
        if (!description || !*description) return NULL;
        NSString *path = [NSString stringWithUTF8String:description];
        if (![NSFileManager.defaultManager fileExistsAtPath:path]) return NULL;
        if (![path.pathExtension.lowercaseString isEqualToString:@"app"]) return strdup(path.UTF8String);
        if (!icon_cache) icon_cache = [NSMutableDictionary dictionary];
        if (icon_cache[path]) return strdup(icon_cache[path].UTF8String);
        if (!icon_directory) {
            char directory[] = "/tmp/bifrost-icons-XXXXXX";
            if (!mkdtemp(directory)) { error_set(@"Cannot create icon cache"); return NULL; }
            icon_directory = [NSString stringWithUTF8String:directory];
        }
        NSImage *image = [NSWorkspace.sharedWorkspace iconForFile:path];
        NSBitmapImageRep *bitmap = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:256 pixelsHigh:256
            bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO colorSpaceName:NSDeviceRGBColorSpace bytesPerRow:0 bitsPerPixel:0];
        [NSGraphicsContext saveGraphicsState];
        [NSGraphicsContext setCurrentContext:[NSGraphicsContext graphicsContextWithBitmapImageRep:bitmap]];
        [image drawInRect:NSMakeRect(0,0,256,256) fromRect:NSZeroRect operation:NSCompositingOperationCopy fraction:1];
        [NSGraphicsContext restoreGraphicsState];
        NSString *output = [icon_directory stringByAppendingPathComponent:[NSUUID.UUID.UUIDString stringByAppendingString:@".png"]];
        if (![[bitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:output atomically:YES]) {
            error_set(@"Cannot rasterize application icon"); return NULL;
        }
        icon_cache[path] = output;
        return strdup(output.UTF8String);
    }
}
char *bf_app_icon(const char *description, const char *app_id) {
    error_set(@"");
    char *path = bf_icon(description);
    if (path) return path;
    NSURL *url = app_id && *app_id ? [NSWorkspace.sharedWorkspace URLForApplicationWithBundleIdentifier:[NSString stringWithUTF8String:app_id]] : nil;
    return url ? bf_icon(url.path.UTF8String) : NULL;
}
void *bf_pixels(const char *path, int *width, int *height) {
    @autoreleasepool {
        NSImage *image = path ? [[NSImage alloc] initWithContentsOfFile:[NSString stringWithUTF8String:path]] : nil;
        CGImageRef source = [image CGImageForProposedRect:NULL context:nil hints:nil];
        if (!source) { error_set(@"macOS could not decode the icon image"); return NULL; }
        size_t w = CGImageGetWidth(source), h = CGImageGetHeight(source);
        double scale = fmin(1.0, 256.0 / fmax(w,h));
        w = fmax(1, lround(w*scale)); h = fmax(1, lround(h*scale));
        unsigned char *pixels = calloc(w*h, 4);
        CGColorSpaceRef colors = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
        CGContextRef context = pixels ? CGBitmapContextCreate(pixels, w, h, 8, w*4, colors, kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big) : NULL;
        CGColorSpaceRelease(colors);
        if (!context) { free(pixels); error_set(@"Cannot allocate icon pixels"); return NULL; }
        CGContextDrawImage(context, CGRectMake(0,0,w,h), source);
        CGContextRelease(context);
        // raylib consumes straight-alpha RGBA, whereas CoreGraphics premultiplies.
        for (size_t i = 0; i < w*h; i++) {
            unsigned char *p = pixels + i*4;
            if (p[3] && p[3] != 255) for (int c = 0; c < 3; c++) p[c] = (unsigned char)fmin(255, (p[c]*255 + p[3]/2)/p[3]);
        }
        *width = (int)w; *height = (int)h;
        return pixels;
    }
}
int bf_save(const char *path, const char *text) {
    @autoreleasepool {
        NSString *filename = [NSString stringWithUTF8String:path];
        NSError *error = nil;
        if (![NSFileManager.defaultManager createDirectoryAtPath:filename.stringByDeletingLastPathComponent
            withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions: @0700} error:&error]) {
            error_set(error.localizedDescription); return 0;
        }
        NSString *pattern = [filename stringByAppendingString:@".XXXXXX"];
        char *temporary = strdup(pattern.fileSystemRepresentation);
        int fd = mkstemp(temporary);
        if (fd < 0) { free(temporary); error_set(@"Cannot create state file"); return 0; }
        size_t left = strlen(text);
        const char *cursor = text;
        BOOL ok = YES;
        while (left) {
            ssize_t written = write(fd, cursor, left);
            if (written < 0 && errno == EINTR) continue;
            if (written <= 0) { ok = NO; break; }
            cursor += written; left -= (size_t)written;
        }
        if (fsync(fd)) ok = NO;
        if (close(fd)) ok = NO;
        if (ok && rename(temporary, path)) ok = NO;
        if (!ok) { unlink(temporary); error_set(@"Cannot atomically save application order"); }
        free(temporary);
        return ok;
    }
}
void bf_shutdown(void) {
    clear_backdrops();
    targets = nil; applications = nil; token = nil; previous_app = nil;
    if (previous_window) { CFRelease(previous_window); previous_window = NULL; }
    if (icon_directory) [NSFileManager.defaultManager removeItemAtPath:icon_directory error:nil];
    icon_directory = nil; icon_cache = nil;
    if (command_fd >= 0) { close(command_fd); command_fd = -1; unlink(socket_path); }
    if (lock_fd >= 0) { close(lock_fd); lock_fd = -1; }
    last_error = nil;
}
