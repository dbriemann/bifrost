package main

import "core:c"
import "core:testing"
import rl "../build/rl"

@(test)
display_scaling_keeps_rendered_labels_and_pointer_targets_consistent :: proc(t: ^testing.T) {
    defer { rl.SetMouseOffset(0, 0); rl.SetMouseScale(1, 1) }
    for dpi in ([6]f32{0.75, 1, 1.25, 1.5, 2, 3}) {
        zoom := picker_scale(DEFAULT_UI_SCALE, dpi, 4000, 2400)
        // A 30-unit label remains 45 framebuffer pixels, including Retina and
        // fractional display scales. Only its native window/cursor units change.
        testing.expect(t, abs(30*zoom*dpi-45) < 0.001)
        testing.expect(t, abs(80*zoom*dpi-120) < 0.001)
        camera := rl.Camera2D{zoom=zoom}
        for index in 0..<12 {
            x := f32(GRID_X+(index%6)*CELL_WIDTH+TILE_WIDTH/2)
            y := f32(GRID_Y+(index/6)*166+154/2)
            rl.SetMouseOffset(c.int(x*zoom), c.int(y*zoom))
            rl.SetMouseScale(1/dpi, 1/dpi) // Callback state must not alter hit targets.
            mouse := ui_mouse_position(camera)
            testing.expect_value(t, pointer_target(mouse.x, mouse.y, 6, 12, 12, 0, false,
                tile_height=154, cell_height=166), index)
        }
    }
}

@(test)
scaled_grids_fit_small_work_areas_and_overflow_pages :: proc(t: ^testing.T) {
    for dpi in ([4]f32{1, 1.25, 2, 3}) {
        for width in ([3]int{240, 472, 1400}) {
            for height in ([3]int{320, 600, 1000}) {
                zoom := picker_scale(3, dpi, width, height)
                testing.expect(t, zoom > 0)
                available_width := int(f32(width-16)/zoom)
                available_height := int(f32(height-16)/zoom)
                for count in ([4]int{0, 7, 37, 73}) {
                    first := grid_layout(count, 222, available_width, available_height)
                    for page in 0..<first.pages {
                        grid := grid_layout(count, 222, available_width, available_height, page)
                        testing.expect(t, f32(grid.width)*zoom <= f32(width-16)+0.001)
                        testing.expect(t, f32(grid.height)*zoom <= f32(height-16)+0.001)
                    }
                }
            }
        }
    }
}

@(test)
ui_scale_accepts_custom_sizes_and_rejects_invalid_values :: proc(t: ^testing.T) {
    testing.expect_value(t, parse_options(nil).scale, f32(DEFAULT_UI_SCALE))
    testing.expect_value(t, parse_options([]string{"--scale", "1.25"}).scale, f32(1.25))
    for value in ([4]string{"0.5", "1", "1.5", "3"}) {
        _, ok := parse_ui_scale(value)
        testing.expect(t, ok, value)
    }
    for value in ([8]string{"", "0", "-1", "0.1", "3.1", "NaN", "Inf", "large"}) {
        _, ok := parse_ui_scale(value)
        testing.expect(t, !ok, value)
    }
}
