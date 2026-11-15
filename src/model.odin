package main

import "core:strings"

KEYS :: "1234567890abcdefghijklmnopqrstuvwxyz"

cycle_selection :: proc(selected, count: int, reverse: bool) -> int {
    if count <= 0 { return 0 }
    step := -1 if reverse else 1
    return (clamp(selected, 0, count-1)+step+count)%count
}

Window :: struct {
    id, app, name, title, icon: string,
    workspace, monitor: int,
}
Snapshot :: struct {
    version: int,
    token, generation: string,
    workspace, monitor, width, height: int,
    windows: []Window,
}
Order :: struct {
    version: int,
    ids: [dynamic]string,
}
Filter :: struct {
    workspace, monitor: int, // -1 = all, -2 = current
    app: string,
}
Group :: struct {
    app, name, icon: string,
    windows: [dynamic]int,
}

observe :: proc(order: ^Order, windows: []Window) -> bool {
    changed := false
    order.version = 1
    for w in windows {
        if w.app == "" { continue }
        found := false
        for id in order.ids { if id == w.app { found = true; break } }
        if !found {
            append(&order.ids, strings.clone(w.app))
            changed = true
        }
    }
    return changed
}

build_groups :: proc(order: Order, snapshot: Snapshot, filter: Filter) -> [dynamic]Group {
    groups := make([dynamic]Group)
    workspace := filter.workspace
    monitor := filter.monitor
    if workspace == -2 { workspace = snapshot.workspace }
    if monitor == -2 { monitor = snapshot.monitor }
    for id in order.ids {
        group := Group{app = id}
        for w, i in snapshot.windows {
            if w.app != id || (filter.app != "" && filter.app != id) { continue }
            if workspace >= 0 && w.workspace >= 0 && w.workspace != workspace { continue }
            if monitor >= 0 && w.monitor != monitor { continue }
            if len(group.windows) == 0 { group.name = w.name; group.icon = w.icon }
            append(&group.windows, i)
        }
        if len(group.windows) > 0 { append(&groups, group) }
    }
    return groups
}

free_groups :: proc(groups: ^[dynamic]Group) {
    for g in groups { delete(g.windows) }
    delete(groups^)
}

// Reorder only visible identities; preserve hidden apps' positions in saved order.
reorder :: proc(order: ^Order, groups: []Group, from, to: int) {
    if from < 0 || to < 0 || from >= len(groups) || to >= len(groups) || from == to { return }
    positions := make([dynamic]int)
    defer delete(positions)
    for id, i in order.ids {
        for g in groups { if id == g.app { append(&positions, i); break } }
    }
    if len(positions) != len(groups) { return }
    value := order.ids[positions[from]]
    if from < to {
        for i := from; i < to; i += 1 { order.ids[positions[i]] = order.ids[positions[i+1]] }
    } else {
        for i := from; i > to; i -= 1 { order.ids[positions[i]] = order.ids[positions[i-1]] }
    }
    order.ids[positions[to]] = value
}

free_order :: proc(order: ^Order) {
    for id in order.ids { delete(id) }
    delete(order.ids)
}
