package main

import "core:strconv"

DEFAULT_UI_SCALE :: 1.5

parse_ui_scale :: proc(value: string) -> (f32, bool) {
    scale, ok := strconv.parse_f32(value)
    // The range also rejects NaN/infinity and impractically small windows.
    return scale, ok && scale >= 0.5 && scale <= 3
}

// UI dimensions are rendered pixels. GLFW window sizes and cursor positions
// are logical units, so divide by the display's backing scale exactly once.
// Limit the logical size only when a single tile cannot fit the work area.
picker_scale :: proc(pixel_scale, backing_scale: f32, work_width, work_height: int) -> f32 {
    return min(pixel_scale/backing_scale,
        f32(work_width-16)/f32(CELL_WIDTH+48),
        f32(work_height-16)/f32(GRID_Y+222+grid_footer_height(1, true)))
}
