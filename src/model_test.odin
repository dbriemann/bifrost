package main

import "core:encoding/json"
import "core:testing"

test_windows :: proc() -> []Window {
    result := make([]Window, 4)
    result[0] = Window{id="a1", app="browser", name="Browser", workspace=0, monitor=0}
    result[1] = Window{id="a2", app="browser", name="Browser", workspace=1, monitor=1}
    result[2] = Window{id="b1", app="editor", name="Editor", workspace=0, monitor=1}
    result[3] = Window{id="c1", app="terminal", name="Terminal", workspace=-1, monitor=0}
    return result
}

@(test)
groups_and_two_stage_targets :: proc(t: ^testing.T) {
    windows := test_windows()
    defer delete(windows)
    order := Order{}
    defer free_order(&order)
    testing.expect(t, observe(&order, windows))
    testing.expect(t, !observe(&order, windows))
    testing.expect_value(t, len(order.ids), 3)
    groups := build_groups(order, Snapshot{windows=windows}, Filter{-1,-1,""})
    defer free_groups(&groups)
    testing.expect_value(t, len(groups), 3)
    testing.expect_value(t, len(groups[0].windows), 2)
    testing.expect_value(t, windows[groups[0].windows[1]].id, "a2")
}

@(test)
closed_apps_compact_and_restore_rank :: proc(t: ^testing.T) {
    windows := test_windows()
    defer delete(windows)
    order := Order{}
    defer free_order(&order)
    observe(&order, windows)
    remaining := []Window{windows[0], windows[1], windows[3]}
    groups := build_groups(order, Snapshot{windows=remaining}, Filter{-1,-1,""})
    defer free_groups(&groups)
    testing.expect_value(t, len(groups), 2)
    testing.expect_value(t, groups[1].app, "terminal")
    free_groups(&groups)
    groups = build_groups(order, Snapshot{windows=windows}, Filter{-1,-1,""})
    testing.expect_value(t, groups[1].app, "editor")
}

@(test)
filters_intersect_and_include_sticky_windows :: proc(t: ^testing.T) {
    windows := test_windows()
    defer delete(windows)
    order := Order{}
    defer free_order(&order)
    observe(&order, windows)
    snapshot := Snapshot{windows=windows, workspace=0, monitor=1}
    groups := build_groups(order, snapshot, Filter{-2,-2,""})
    defer free_groups(&groups)
    testing.expect_value(t, len(groups), 1)
    testing.expect_value(t, groups[0].app, "editor")
    free_groups(&groups)
    groups = build_groups(order, snapshot, Filter{-2,0,""})
    testing.expect_value(t, len(groups), 2)
    testing.expect_value(t, groups[1].app, "terminal")
    free_groups(&groups)
    groups = build_groups(order, snapshot, Filter{-1,-1,"browser"})
    testing.expect_value(t, len(groups), 1)
    testing.expect_value(t, len(groups[0].windows), 2)
    free_groups(&groups)
    groups = build_groups(order, snapshot, Filter{-2,-2,"browser"})
    testing.expect_value(t, len(groups), 0)
}

@(test)
reorder_filtered_subset_preserves_hidden_positions :: proc(t: ^testing.T) {
    windows := test_windows()
    defer delete(windows)
    order := Order{}
    defer free_order(&order)
    observe(&order, windows)
    groups := build_groups(order, Snapshot{windows=windows}, Filter{-1,0,""})
    defer free_groups(&groups)
    reorder(&order, groups[:], 1, 0)
    testing.expect_value(t, order.ids[0], "terminal")
    testing.expect_value(t, order.ids[1], "editor")
    testing.expect_value(t, order.ids[2], "browser")
    bytes, err := json.marshal(order)
    defer delete(bytes)
    testing.expect(t, err == nil)
    restored: Order
    defer free_order(&restored)
    testing.expect(t, json.unmarshal(bytes, &restored) == nil)
    testing.expect_value(t, restored.ids[0], "terminal")
    testing.expect_value(t, restored.version, 1)
}

@(test)
new_apps_append_and_focus_order_does_not_change_rank :: proc(t: ^testing.T) {
    windows := test_windows()
    defer delete(windows)
    order := Order{}
    defer free_order(&order)
    observe(&order, windows)
    reversed := []Window{windows[3], windows[2], windows[1], windows[0]}
    testing.expect(t, !observe(&order, reversed))
    more := []Window{Window{app="music", id="m1"}}
    testing.expect(t, observe(&order, more))
    testing.expect_value(t, order.ids[0], "browser")
    testing.expect_value(t, order.ids[3], "music")
}

@(test)
selection_alphabet_covers_digits_then_letters :: proc(t: ^testing.T) {
    alphabet := string(KEYS)
    testing.expect_value(t, len(alphabet), 36)
    testing.expect_value(t, alphabet[:10], "1234567890")
    testing.expect_value(t, alphabet[10:], "abcdefghijklmnopqrstuvwxyz")
}
