#define _POSIX_C_SOURCE 200809L
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

// Test the actual adapter without requiring a compositor. In this test only,
// provide stand-ins for the original calls; production links them through --wrap.
static int backend = 0x00060003;
static int gets, sets;
static int platform_hint, decoration_hint, initialized, app_id_hint;
int glfwGetPlatform(void) { return backend; }
int glfwPlatformSupported(int platform) {
    assert(platform == 0x00060003);
    return 1;
}
void glfwInitHint(int hint, int value) {
    assert(!initialized);
    if (hint == 0x00050003) { assert(value == 0x00060003); ++platform_hint; }
    else { assert(hint == 0x00053001 && value == 0x00038002); ++decoration_hint; }
}
int glfwInit(void) {
    assert(platform_hint == 1 && decoration_hint == 1);
    initialized = 1;
    return 1;
}
void glfwWindowHintString(int hint, const char *value) {
    assert(initialized && hint == 0x00026001 && !strcmp(value, "org.bifrost.Picker"));
    ++app_id_hint;
}
void __real_glfwGetWindowPos(void *window, int *x, int *y) {
    assert(window == (void *)1);
    ++gets;
    if (x) *x = 123;
    if (y) *y = 456;
}
void __real_glfwSetWindowPos(void *window, int x, int y) {
    assert(window == (void *)1 && x == 12 && y == 34);
    ++sets;
}
void __wrap_glfwGetWindowPos(void *, int *, int *);
void __wrap_glfwSetWindowPos(void *, int, int);
int bf_wayland_prepare(void);
int main(void) {
    assert(!setenv("WAYLAND_DISPLAY", "bifrost-test", 1));
    assert(bf_wayland_prepare() && initialized && app_id_hint == 1);
    puts("Native Wayland selected and unused libdecor disabled before initialization: OK");
    int x = -1, y = -1;
    __wrap_glfwGetWindowPos((void *)1, &x, &y);
    assert(x == 0 && y == 0 && gets == 0);
    __wrap_glfwGetWindowPos((void *)1, NULL, NULL);
    __wrap_glfwSetWindowPos((void *)1, 12, 34);
    assert(sets == 0);
    backend = 0x00060004; // GLFW_PLATFORM_X11: preserve the original behavior.
    __wrap_glfwGetWindowPos((void *)1, &x, &y);
    assert(x == 123 && y == 456 && gets == 1);
    __wrap_glfwSetWindowPos((void *)1, 12, 34);
    assert(sets == 1);
    puts("Wayland position calls bypassed; other backend calls forwarded: OK");
}
