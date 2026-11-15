package main

import "core:testing"

@(test)
drag_moves_between_tiles_without_selecting_a_window :: proc(t: ^testing.T) {
    gesture := Pointer_Gesture{}
    action := pointer_step(&gesture, 60, 130, 0, true, true, false, true, false)
    testing.expect_value(t, action.kind, .None)
    action = pointer_step(&gesture, 210, 135, 1, false, true, false, true, false)
    testing.expect(t, gesture.active && gesture.dragging)
    action = pointer_step(&gesture, 210, 135, 1, false, false, true, true, false)
    testing.expect_value(t, action.kind, .Reorder)
    testing.expect_value(t, action.source, 0)
    testing.expect_value(t, action.target, 1)
    testing.expect(t, !gesture.active)

    windows := test_windows()
    defer delete(windows)
    order := Order{}
    defer free_order(&order)
    observe(&order, windows)
    groups := build_groups(order, Snapshot{windows=windows}, Filter{-1,-1,""})
    defer free_groups(&groups)
    reorder(&order, groups[:], action.source, action.target)
    testing.expect_value(t, order.ids[0], "editor")
    testing.expect_value(t, order.ids[1], "browser")
}

@(test)
release_frame_motion_is_still_a_drag :: proc(t: ^testing.T) {
    gesture := Pointer_Gesture{}
    pointer_step(&gesture, 60, 130, 0, true, true, false, true, false)
    action := pointer_step(&gesture, 210, 135, 1, false, false, true, true, false)
    testing.expect_value(t, action.kind, .Reorder)
    testing.expect_value(t, action.target, 1)
}

@(test)
click_selects_but_dragging_child_windows_does_not :: proc(t: ^testing.T) {
    gesture := Pointer_Gesture{}
    pointer_step(&gesture, 60, 130, 0, true, true, false, false, false)
    action := pointer_step(&gesture, 62, 131, 0, false, false, true, false, false)
    testing.expect_value(t, action.kind, .Select)
    pointer_step(&gesture, 60, 130, 0, true, true, false, false, false)
    action = pointer_step(&gesture, 210, 135, 1, false, false, true, false, false)
    testing.expect_value(t, action.kind, .None)
}

@(test)
cancelled_and_outside_drops_never_select :: proc(t: ^testing.T) {
    gesture := Pointer_Gesture{}
    pointer_step(&gesture, 60, 130, 0, true, true, false, true, false)
    pointer_step(&gesture, 210, 135, 1, false, true, false, true, false)
    action := pointer_step(&gesture, 210, 135, 1, false, true, false, true, true)
    testing.expect_value(t, action.kind, .None)
    testing.expect(t, !gesture.active)
    action = pointer_step(&gesture, 210, 135, 1, false, false, true, true, false)
    testing.expect_value(t, action.kind, .None)
    pointer_step(&gesture, 60, 130, 0, true, true, false, true, false)
    action = pointer_step(&gesture, -20, 130, -1, false, false, true, true, false)
    testing.expect_value(t, action.kind, .None)
}

@(test)
drop_targets_include_gaps_and_trailing_row_space :: proc(t: ^testing.T) {
    // The first tile ends at x=228; the next begins at x=244.
    testing.expect_value(t, pointer_target(236, 130, 3, 9, 5, 0, false), -1)
    testing.expect_value(t, pointer_target(236, 130, 3, 9, 5, 0, true), 0)
    testing.expect_value(t, pointer_target(456, 130, 3, 9, 5, 0, true), 1)
    // The last row contains two tiles; empty trailing cell means append.
    testing.expect_value(t, pointer_target(510, 294, 3, 9, 5, 0, false, tile_height=154, cell_height=166), -1)
    testing.expect_value(t, pointer_target(510, 294, 3, 9, 5, 0, true, tile_height=154, cell_height=166), 4)
    testing.expect_value(t, pointer_target(60, 130, 3, 9, 20, 1, true), 9)
    testing.expect_value(t, pointer_target(10, 130, 3, 9, 5, 0, true), -1)
    testing.expect_value(t, pointer_target(60, 594, 3, 9, 5, 0, true), -1)
}

@(test)
gaps_insert_between_neighbors_in_both_directions :: proc(t: ^testing.T) {
    // Move tile 2 to the gap after tile 0: final index 1.
    testing.expect_value(t, pointer_target(236, 130, 3, 9, 5, 0, true, 2), 1)
    // Tile 0 is already before tile 1: dropping in that gap leaves it there.
    testing.expect_value(t, pointer_target(236, 130, 3, 9, 5, 0, true, 0), 0)
    // Move tile 0 after tile 1 using the following gap.
    testing.expect_value(t, pointer_target(456, 130, 3, 9, 5, 0, true, 0), 1)
    // The gap below the first row is the insertion boundary before tile 3.
    testing.expect_value(t, pointer_target(60, 310, 3, 9, 5, 0, true, 4), 3)
}
