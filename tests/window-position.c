#include <assert.h>
#include <stdio.h>

// Test the actual adapter without requiring a compositor. In this test only,
// provide stand-ins for the original calls; production links them through --wrap.
static int backend = 0x00060003;
static int gets, sets;
int glfwGetPlatform(void) { return backend; }
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
int main(void) {
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
