package main

import rl "../build/rl"

ui_mouse_position :: proc(camera: rl.Camera2D) -> rl.Vector2 {
    // GLFW reports Wayland cursor coordinates in window logical units. Raylib's
    // X11-built desktop module overwrites Mouse.scale in framebuffer/content-
    // scale callbacks, including after our initial resize. Normalize it on
    // every sample, then invert the exact camera used to draw the UI.
    rl.SetMouseScale(1, 1)
    return rl.GetScreenToWorld2D(rl.GetMousePosition(), camera)
}
