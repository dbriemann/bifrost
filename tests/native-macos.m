// Compile the production adapter with display calls stubbed, so its actual
// JSON, AppKit icons, persistence, and IPC can be checked without a GUI window.
#include <assert.h>
#include <sys/wait.h>
#include "../native/platform_macos.m"
int glfwInit(void) { return 1; }
int glfwGetPlatform(void) { return 0x00060002; }
void *glfwGetCurrentContext(void) { return NULL; }
NSWindow *glfwGetCocoaWindow(void *window) { (void)window; return nil; }
void glfwGetFramebufferSize(void *window, int *width, int *height) { (void)window; *width = 0; *height = 0; }
unsigned char *rlReadScreenPixels(int width, int height) { (void)width; (void)height; return NULL; }
void glfwSetWindowSizeLimits(void *window, int a, int b, int c, int d) {
    (void)window; assert(a == c && b == d);
}
static NSDictionary *decode(char *response) {
    assert(response);
    NSData *data = [[NSString stringWithUTF8String:response] dataUsingEncoding:NSUTF8StringEncoding];
    bf_free(response);
    NSDictionary *object = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    assert([object isKindOfClass:NSDictionary.class]);
    return object;
}
int main(int argc, char **argv) {
    @autoreleasepool {
        if (argc == 2) { assert(bf_instance(argv[1]) == 0); bf_shutdown(); return 0; }
        // Missing batch attributes are error values, not strings or geometry.
        // Keep the other attributes usable when a provider omits one field.
        AXError unsupported = kAXErrorAttributeUnsupported;
        id missing = CFBridgingRelease(AXValueCreate(kAXValueAXErrorType, &unsupported));
        CGPoint point = {23, 45};
        id position = CFBridgingRelease(AXValueCreate(kAXValueCGPointType, &point));
        NSArray *attributes = @[@"AXWindow", missing, position, NSNull.null, @"Example"];
        assert([window_string(attributes, 0) isEqual:@"AXWindow"]);
        assert([window_string(attributes, 1) isEqual:@""]);
        assert(window_attribute(attributes, 2) == position);
        assert(!window_attribute(attributes, 3) && !window_attribute(attributes, 8));
        assert([window_string(attributes, 4) isEqual:@"Example"]);
        assert([window_string(attributes, 2) isEqual:@""]);
        puts("Batched window attributes preserve missing-field and geometry handling: OK");
        char directory[] = "/tmp/bifrost-macos-test-XXXXXX";
        assert(mkdtemp(directory));
        assert(!setenv("BIFROST_RUNTIME_DIR", directory, 1));
        assert(bf_instance("hide") == 0);
        assert(bf_instance("toggle") == 1);
        for (int i = 0; i < 2; i++) {
            const char *command = i ? "toggle" : "hide";
            pid_t child = fork(); assert(child >= 0);
            if (!child) { execl(argv[0], argv[0], command, NULL); _exit(127); }
            int status = 0; assert(waitpid(child, &status, 0) == child);
            assert(WIFEXITED(status) && WEXITSTATUS(status) == 0);
            char *received = bf_poll(); assert(received && !strcmp(received, command)); bf_free(received);
        }
        assert(!bf_poll());
        puts("Native instance ownership and toggle/hide forwarding: OK");
        bf_shutdown();
        // Recovery after the old owner's socket survives an abrupt exit.
        struct sockaddr_un address = {.sun_family = AF_UNIX};
        snprintf(address.sun_path, sizeof address.sun_path, "%s/command", directory);
        int stale = socket(AF_UNIX, SOCK_DGRAM, 0); assert(stale >= 0);
        assert(!bind(stale, (struct sockaddr *)&address, sizeof address)); close(stale);
        assert(bf_instance("toggle") == 1); bf_shutdown();
        assert(!chmod(directory, 0755));
        assert(bf_instance("toggle") == -1); assert(strstr(bf_error(), "Unsafe"));
        assert(!chmod(directory, 0700));
        puts("Stale command socket recovery and private runtime validation: OK");

        NSString *filename = [[NSString stringWithUTF8String:directory] stringByAppendingPathComponent:@"state/order.json"];
        assert(bf_save(filename.UTF8String, "{\"version\":1,\"ids\":[\"browser\"]}"));
        assert(bf_save(filename.UTF8String, "{\"version\":1,\"ids\":[\"terminal\"]}"));
        NSString *contents = [NSString stringWithContentsOfFile:filename encoding:NSUTF8StringEncoding error:nil];
        assert([contents containsString:@"terminal"] && ![contents containsString:@"browser"]);
        struct stat info; assert(!stat(filename.UTF8String, &info) && (info.st_mode & 0777) == 0600);
        assert(!stat(filename.stringByDeletingLastPathComponent.UTF8String, &info) && (info.st_mode & 0777) == 0700);
        assert(!bf_save("/nonexistent/bifrost-native-test/order.json", "{}"));
        puts("Atomic state replacement, parent creation, and private permissions: OK");

        char *path = bf_icon("tests/fixtures/app.png"); assert(path); bf_free(path);
        assert(!bf_icon("/nonexistent/bifrost.png"));
        assert(!bf_app_icon("", "org.bifrost.nonexistent"));
        int width, height;
        unsigned char *pixels = bf_pixels("tests/fixtures/app.png", &width, &height);
        assert(pixels && width == 2 && height == 1);
        assert(pixels[0] == 233 && pixels[1] == 84 && pixels[2] == 32 && pixels[3] == 255);
        assert(pixels[7] == 128 && abs(pixels[4]-53) <= 1 && abs(pixels[5]-132) <= 1 && abs(pixels[6]-228) <= 1);
        bf_free(pixels);
        assert(!bf_pixels("/nonexistent/bifrost.icns", &width, &height));
        // Create a small app fixture with an actual macOS bundle icon.
        NSString *bundle_path = [[NSString stringWithUTF8String:directory] stringByAppendingPathComponent:@"Fixture.app"];
        NSFileManager *manager = NSFileManager.defaultManager;
        NSString *resources = [bundle_path stringByAppendingPathComponent:@"Contents/Resources"];
        assert([manager createDirectoryAtPath:resources withIntermediateDirectories:YES attributes:nil error:nil]);
        assert([manager copyItemAtPath:@"tests/fixtures/app.png" toPath:[resources stringByAppendingPathComponent:@"icon.png"] error:nil]);
        assert(([@{@"CFBundleIdentifier": @"org.bifrost.fixture", @"CFBundleIconFile": @"icon.png"}
            writeToFile:[bundle_path stringByAppendingPathComponent:@"Contents/Info.plist"] atomically:YES]));
        path = bf_icon(bundle_path.UTF8String); assert(path && access(path, R_OK) == 0);
        pixels = bf_pixels(path, &width, &height); assert(pixels && width == 256 && height == 256);
        bf_free(pixels);
        char *again = bf_icon(bundle_path.UTF8String); assert(again && !strcmp(path, again)); bf_free(again);
        NSString *cached = [NSString stringWithUTF8String:path]; bf_free(path);
        bf_shutdown(); assert(![manager fileExistsAtPath:cached]);
        puts("AppKit bundle icons, straight-alpha RGBA, and session cache cleanup: OK");

        NSDictionary *reply = decode(bf_call("Activate", "{\"token\":\"stale\",\"id\":\"1\"}"));
        assert(![reply[@"ok"] boolValue]);
        reply = decode(bf_call("Activate", "{\"token\":\"demo\",\"id\":\"1\"}"));
        assert(![reply[@"ok"] boolValue] && [reply[@"error"] containsString:@"Preview"]);
        reply = decode(bf_call("Present", "{\"token\":\"demo\"}")); assert(![reply[@"ok"] boolValue]);
        assert(!bf_call("Snapshot", "[]"));
        if (!AXIsProcessTrusted()) {
            assert(!bf_call("Snapshot", "{}"));
            assert(strstr(bf_error(), "Accessibility permission"));
        }
        reply = decode(catalogue());
        assert([reply[@"version"] intValue] == 1 && [reply[@"apps"] count] > 0);
        NSMutableSet *ids = [NSMutableSet set];
        for (NSDictionary *app in reply[@"apps"]) {
            assert([app[@"name"] length] && [app[@"id"] length]);
            assert(![ids containsObject:app[@"id"]]); [ids addObject:app[@"id"]];
            assert([manager fileExistsAtPath:applications[app[@"id"]].path]);
            assert(![app[@"id"] isEqualToString:@"org.bifrost.picker"]);
        }
        puts("Session validation, preview isolation, permissions, and installed application discovery: OK");
        bf_shutdown();
        assert([manager removeItemAtPath:[NSString stringWithUTF8String:directory] error:nil]);
    }
    return 0;
}
