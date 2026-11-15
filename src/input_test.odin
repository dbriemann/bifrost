package main

import "core:c"
import "core:testing"
import rl "../build/rl"

// Exercise raylib's actual mouse-scale state and camera inverse without a
// compositor. With no input events, offset supplies a known raw cursor position.
@(test)
hover_and_click_targets_stay_aligned_after_resize_and_dpi_scale_resets :: proc(t: ^testing.T) {
    defer { rl.SetMouseOffset(0, 0); rl.SetMouseScale(1, 1) }
    camera := rl.Camera2D{zoom=1.5}
    rl.SetMouseOffset(519, 195)
    rl.SetMouseScale(1/camera.zoom, 1/camera.zoom)
    // Reproduce the resize callback resetting our scale back to 1: the old
    // path thinks the cursor over tile 1 is instead over tile 2.
    rl.SetMouseScale(1, 1)
    stale := rl.GetMousePosition()
    testing.expect_value(t, pointer_target(stale.x, stale.y, 6, 12, 12, 0, false,
        tile_height=154, cell_height=166), 2)
    mouse := ui_mouse_position(camera)
    testing.expect_value(t, pointer_target(mouse.x, mouse.y, 6, 12, 12, 0, false,
        tile_height=154, cell_height=166), 1)

    for zoom in ([3]f32{1.5, 1, 0.75}) {
        camera.zoom = zoom
        for inherited_scale in ([4]f32{1, 0.5, 0.8, 2.0/3.0}) {
            for index in 0..<12 {
                x := f32(GRID_X+(index%6)*CELL_WIDTH+TILE_WIDTH/2)
                y := f32(GRID_Y+(index/6)*166+154/2)
                rl.SetMouseOffset(c.int(x*zoom), c.int(y*zoom))
                rl.SetMouseScale(inherited_scale, inherited_scale)
                mouse = ui_mouse_position(camera)
                target := pointer_target(mouse.x, mouse.y, 6, 12, 12, 0, false,
                    tile_height=154, cell_height=166)
                testing.expect_value(t, target, index)
                gesture := Pointer_Gesture{}
                pointer_step(&gesture, mouse.x, mouse.y, target, true, true, false, true, false)
                action := pointer_step(&gesture, mouse.x, mouse.y, target, false, false, true, true, false)
                testing.expect_value(t, action.kind, .Select)
                testing.expect_value(t, action.target, index)
            }
        }
    }
    // Search rows use the same conversion as window tiles.
    state := Launcher{results=make([dynamic]Search_Result)}
    defer delete(state.results)
    append(&state.results, Search_Result{index=7}, Search_Result{index=2})
    camera.zoom = 1.5
    rl.SetMouseOffset(75, 315) // UI (50, 210), inside search row 1.
    rl.SetMouseScale(1, 1)
    mouse = ui_mouse_position(camera)
    launcher_pointer_step(&state, mouse.x, mouse.y, 700, 760, true, true, false, true)
    testing.expect_value(t, state.selected, 1)
    testing.expect_value(t, launcher_pointer_step(&state, mouse.x, mouse.y,
        700, 760, false, false, true, false), 2)
}
