#import <AppKit/AppKit.h>
#import <Carbon/Carbon.h>
#include <errno.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <unistd.h>

// Carbon's registered hotkeys work across applications without an event tap
// or Accessibility/Input Monitoring permission. Key 50 is ^ on this Mac's
// German keyboard, and the grave-accent key on a US keyboard.
static const UInt32 shortcut_key = 50;
static const UInt32 shortcut_modifiers = cmdKey;
static const OSType shortcut_signature = 0x42465253; // BFRS
static NSURL *picker_bundle;
static BOOL shortcut_down, launching, toggle_pending, trigger_once;

static BOOL toggle_visible_picker(void) {
    char directory[PATH_MAX];
    snprintf(directory, sizeof directory, "/tmp/bifrost-%u", getuid());
    struct stat info;
    if (lstat(directory, &info) || !S_ISDIR(info.st_mode) || info.st_uid != getuid() ||
        (info.st_mode & 0777) != 0700) return NO;
    struct sockaddr_un address = {.sun_family = AF_UNIX};
    address.sun_len = sizeof address;
    snprintf(address.sun_path, sizeof address.sun_path, "%s/command", directory);
    int sender = socket(AF_UNIX, SOCK_DGRAM, 0);
    if (sender < 0) return NO;
    ssize_t sent = sendto(sender, "toggle", 6, MSG_DONTWAIT, (struct sockaddr *)&address, sizeof address);
    close(sender);
    return sent == 6;
}

static void toggle_picker(void) {
    if (toggle_visible_picker()) {
        if (trigger_once) exit(0);
        return;
    }
    if (launching) { toggle_pending = !toggle_pending; return; }
    launching = YES;
    NSWorkspaceOpenConfiguration *configuration = NSWorkspaceOpenConfiguration.configuration;
    configuration.createsNewApplicationInstance = YES;
    configuration.activates = NO;
    configuration.arguments = @[@"toggle"];
    // Optional startup diagnostics; a normal login helper passes no overrides.
    NSMutableDictionary *environment = [NSMutableDictionary dictionary];
    for (NSString *name in @[@"BIFROST_TIMING", @"BIFROST_LAUNCH_DIR"]) {
        const char *value = getenv(name.UTF8String);
        if (value && *value) environment[name] = [NSString stringWithUTF8String:value];
    }
    if (environment.count) configuration.environment = environment;
    [NSWorkspace.sharedWorkspace openApplicationAtURL:picker_bundle configuration:configuration
        completionHandler:^(NSRunningApplication *app, NSError *error) {
            (void)app;
            dispatch_async(dispatch_get_main_queue(), ^{
                launching = NO;
                if (error) {
                    fprintf(stderr, "bifrost-hotkey: cannot launch Bifrost: %s\n", error.localizedDescription.UTF8String);
                    toggle_pending = NO;
                }
                if (trigger_once) exit(error ? 1 : 0);
                if (toggle_pending) { toggle_pending = NO; toggle_picker(); }
            });
        }];
}

static OSStatus hotkey_event(EventHandlerCallRef handler, EventRef event, void *context) {
    (void)handler; (void)context;
    EventHotKeyID identity;
    OSStatus result = GetEventParameter(event, kEventParamDirectObject, typeEventHotKeyID,
        NULL, sizeof identity, NULL, &identity);
    if (result != noErr || identity.signature != shortcut_signature || identity.id != 1)
        return eventNotHandledErr;
    if (GetEventKind(event) == kEventHotKeyReleased) shortcut_down = NO;
    else if (!shortcut_down) { shortcut_down = YES; toggle_picker(); }
    return noErr;
}

int main(int argc, const char **argv) {
    @autoreleasepool {
        BOOL check = argc == 2 && !strcmp(argv[1], "--check");
        trigger_once = argc >= 2 && !strcmp(argv[1], "--trigger");
        if (argc > (trigger_once ? 3 : 2)) {
            fprintf(stderr, "Usage: bifrost-hotkey [Bifrost.app | --check | --trigger Bifrost.app]\n");
            return 1;
        }
        NSString *path = nil;
        if (trigger_once && argc == 3) path = [NSString stringWithUTF8String:argv[2]];
        else if (!check && !trigger_once && argc == 2) path = [NSString stringWithUTF8String:argv[1]];
        else path = [NSBundle.mainBundle.bundleURL.URLByDeletingLastPathComponent.path stringByAppendingPathComponent:@"Bifrost.app"];
        picker_bundle = [NSURL fileURLWithPath:path];
        if (!check && ![[NSBundle bundleWithURL:picker_bundle].bundleIdentifier isEqual:@"org.bifrost.picker"]) {
            fprintf(stderr, "bifrost-hotkey: expected the installed Bifrost.app at %s\n", path.UTF8String);
            return 1;
        }
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
        if (trigger_once) { toggle_picker(); [NSApp run]; return 0; }
        EventTypeSpec events[] = {{kEventClassKeyboard, kEventHotKeyPressed}, {kEventClassKeyboard, kEventHotKeyReleased}};
        EventHandlerRef handler = NULL;
        OSStatus result = InstallApplicationEventHandler(hotkey_event, 2, events, NULL, &handler);
        EventHotKeyRef hotkey = NULL;
        if (result == noErr) result = RegisterEventHotKey(shortcut_key, shortcut_modifiers,
            (EventHotKeyID){shortcut_signature, 1}, GetApplicationEventTarget(), 0, &hotkey);
        if (result != noErr) {
            fprintf(stderr, "bifrost-hotkey: cannot register Command+^ (macOS error %d); clear any conflicting shortcut.\n", (int)result);
            if (handler) RemoveEventHandler(handler);
            return 1;
        }
        fprintf(stderr, "bifrost-hotkey: registered Command+^ (PID %d)\n", getpid());
        fflush(stderr);
        if (!check) [NSApp run];
        UnregisterEventHotKey(hotkey);
        RemoveEventHandler(handler);
        return 0;
    }
}
