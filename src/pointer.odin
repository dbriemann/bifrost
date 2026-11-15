package main

// Shared by drawing and hit testing so enlarged tiles keep their drop targets.
GRID_X :: 24
GRID_Y :: 88
CELL_WIDTH :: 220
CELL_HEIGHT :: 228
TILE_WIDTH :: 204
TILE_HEIGHT :: 216

// Keep a pointer gesture independent of frame rate and rendering. Motion on the
// release frame still counts as dragging; it must never activate a window.
Pointer_Gesture :: struct {
    active, dragging: bool,
    source: int,
    origin_x, origin_y: f32,
}
Pointer_Action_Kind :: enum {None, Select, Reorder}
Pointer_Action :: struct {
    kind: Pointer_Action_Kind,
    source, target: int,
}

pointer_step :: proc(gesture: ^Pointer_Gesture, x, y: f32, target: int,
    pressed, down, released, reorderable, cancel: bool) -> Pointer_Action {
    if cancel { gesture^ = {}; return {} }
    if pressed {
        gesture^ = {}
        if target >= 0 {
            gesture^ = Pointer_Gesture{active=true, source=target, origin_x=x, origin_y=y}
        }
    }
    if !gesture.active { return {} }
    if down || released {
        dx, dy := x - gesture.origin_x, y - gesture.origin_y
        if dx*dx + dy*dy >= 64 { gesture.dragging = true }
    }
    if !released { return {} }
    action := Pointer_Action{}
    if gesture.dragging {
        if reorderable && target >= 0 && target != gesture.source {
            action = {.Reorder, gesture.source, target}
        }
    } else if target == gesture.source {
        action = {.Select, gesture.source, target}
    }
    gesture^ = {}
    return action
}

// Drop targets include the gaps between cells. Ordinary clicks stay limited to
// the drawn tile so clicking the panel's padding cannot activate a window.
pointer_target :: proc(mouse_x, mouse_y: f32, cols, capacity, count, page: int, dropping: bool, source := -1, tile_height := TILE_HEIGHT, cell_height := CELL_HEIGHT) -> int {
    x := mouse_x - GRID_X
    y := mouse_y - GRID_Y
    visible := min(capacity, max(0, count-page*capacity))
    if x < 0 || y < 0 || x >= f32(cols*CELL_WIDTH) || visible == 0 { return -1 }
    column, row := int(x)/CELL_WIDTH, int(y)/cell_height
    if row >= (visible+cols-1)/cols { return -1 }
    local := row*cols+column
    if !dropping && (local >= visible || int(x)%CELL_WIDTH >= TILE_WIDTH || int(y)%cell_height >= tile_height) { return -1 }
    if dropping && source >= 0 {
        // Gaps represent an insertion boundary, whereas dropping on a tile
        // preserves the existing move-onto-that-tile behavior.
        boundary := -1
        if int(y)%cell_height >= tile_height { boundary = min((row+1)*cols, visible) }
        else if int(x)%CELL_WIDTH >= TILE_WIDTH { boundary = min(local+1, visible) }
        else if local >= visible { boundary = visible }
        if boundary >= 0 {
            absolute := page*capacity+boundary
            if source < absolute { return absolute-1 }
            return min(page*capacity+visible-1, absolute)
        }
    }
    return page*capacity + min(local, visible-1)
}
