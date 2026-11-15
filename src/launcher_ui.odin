package main

import "core:c"
import "core:fmt"
import "core:unicode/utf8"
import rl "../build/rl"

LAUNCHER_LIST_Y :: 158
LAUNCHER_ROW_HEIGHT :: 48
LAUNCHER_ICON_SIZE :: 24

key_edit :: proc(key: rl.KeyboardKey) -> bool {
    return rl.IsKeyPressed(key) || rl.IsKeyPressedRepeat(key)
}

launcher_visible_rows :: proc(height: c.int) -> int {
    return max(1, min(LAUNCHER_LIMIT, (int(height)-210)/LAUNCHER_ROW_HEIGHT))
}

// A click must begin and end on the same result. Reuse the tile gesture rules
// so dragging, clicking padding, or releasing over another row cannot launch.
launcher_pointer_step :: proc(state: ^Launcher, x, y: f32, width, height: c.int,
    pressed, down, released, pointer_moved: bool) -> int {
    target := -1
    if x >= 28 && x < f32(width-28) && y >= LAUNCHER_LIST_Y {
        offset := int(y-LAUNCHER_LIST_Y)
        row := offset/LAUNCHER_ROW_HEIGHT
        index := state.top+row
        if row < launcher_visible_rows(height) && index < len(state.results) &&
            offset%LAUNCHER_ROW_HEIGHT < LAUNCHER_ROW_HEIGHT-2 {
            target = index
        }
    }
    if target >= 0 && (pointer_moved || pressed) { state.selected = target }
    action := pointer_step(&state.pointer, x, y, target, pressed, down, released, false, false)
    if action.kind == .Select {
        state.selected = action.target
        return state.results[action.target].index
    }
    return -1
}

launcher_input :: proc(state: ^Launcher, width, height: c.int, entering: bool,
    mouse: rl.Vector2, previous_mouse: ^rl.Vector2) -> (back: bool, launch_index: int) {
    launch_index = -1
    if rl.IsKeyPressed(.ESCAPE) { state.pointer = {}; return true, -1 }
    changed := false
    control := rl.IsKeyDown(.LEFT_CONTROL) || rl.IsKeyDown(.RIGHT_CONTROL)
    if key_edit(.BACKSPACE) { changed = launcher_backspace(state) }
    if key_edit(.DELETE) { changed = launcher_delete(state) || changed }
    if control && rl.IsKeyPressed(.U) {
        resize(&state.query, 0); state.cursor = 0; changed = true
    }
    if control && rl.IsKeyPressed(.V) {
        clipboard := rl.GetClipboardText()
        if clipboard != nil { for value in string(clipboard) { changed = launcher_insert(state, value) || changed } }
    }
    if key_edit(.LEFT) { state.cursor = max(0, state.cursor-1) }
    if key_edit(.RIGHT) { state.cursor = min(len(state.query), state.cursor+1) }
    if rl.IsKeyPressed(.HOME) { state.cursor = 0 }
    if rl.IsKeyPressed(.END) { state.cursor = len(state.query) }
    skip_space := entering
    value := rl.GetCharPressed()
    for value != 0 {
        if skip_space && value == ' ' { skip_space = false }
        else {
            skip_space = false
            if !control { changed = launcher_insert(state, value) || changed }
        }
        value = rl.GetCharPressed()
    }
    // Drain the picker shortcut queue: letters/digits only edit the input here.
    for rl.GetKeyPressed() != .KEY_NULL {}
    if changed { launcher_refresh(state) }
    rows := launcher_visible_rows(height)
    moved := false
    if key_edit(.DOWN) { state.selected = min(len(state.results)-1, state.selected+1); moved = true }
    if key_edit(.UP) { state.selected = max(0, state.selected-1); moved = true }
    if key_edit(.TAB) {
        reverse := rl.IsKeyDown(.LEFT_SHIFT) || rl.IsKeyDown(.RIGHT_SHIFT)
        state.selected = cycle_selection(state.selected, len(state.results), reverse)
        moved = true
    }
    state.selected = max(0, state.selected)
    if moved || changed {
        if state.selected < state.top { state.top = state.selected }
        if state.selected >= state.top+rows { state.top = state.selected-rows+1 }
    }
    wheel := int(rl.GetMouseWheelMove())
    state.top = clamp(state.top-wheel, 0, max(0, len(state.results)-rows))
    if wheel != 0 && len(state.results) > 0 {
        state.selected = clamp(state.selected, state.top, min(len(state.results)-1, state.top+rows-1))
    }
    pointer_moved := mouse != previous_mouse^
    previous_mouse^ = mouse
    clicked := launcher_pointer_step(state, mouse.x, mouse.y, width, height,
        rl.IsMouseButtonPressed(.LEFT), rl.IsMouseButtonDown(.LEFT), rl.IsMouseButtonReleased(.LEFT), pointer_moved)
    if clicked >= 0 { return false, clicked }
    if rl.IsKeyPressed(.ENTER) && len(state.results) > 0 {
        return false, state.results[state.selected].index
    }
    return false, -1
}

launcher_draw :: proc(state: Launcher, font: rl.Font, width, height: c.int, icons: map[string]rl.Texture2D) {
    field := rl.Rectangle{28, 88, f32(width-56), 54}
    rl.DrawRectangleRounded(field, 0.12, 8, {29, 35, 49, 255})
    rl.DrawRectangleRoundedLinesEx(field, 0.12, 8, 2, {119, 144, 178, 255})
    available := f32(width-84)
    start := 0
    prefix := utf8.runes_to_string(state.query[:state.cursor], context.temp_allocator)
    for rl.MeasureTextEx(font, cstr(prefix), 26, 0).x > available-8 && start < state.cursor {
        start += 1
        prefix = utf8.runes_to_string(state.query[start:state.cursor], context.temp_allocator)
    }
    visible := utf8.runes_to_string(state.query[start:], context.temp_allocator)
    if len(state.query) == 0 {
        text(font, "Search installed applications…", 42, 100, 26, {139, 151, 173, 255}, available)
    } else { text(font, visible, 42, 100, 26, {239, 242, 249, 255}, available) }
    if int(rl.GetTime()*2)%2 == 0 {
        caret_x := 42 + rl.MeasureTextEx(font, cstr(prefix), 26, 0).x
        rl.DrawRectangle(c.int(caret_x), 99, 2, 32, {157, 218, 244, 255})
    }
    rows := launcher_visible_rows(height)
    for row in 0..<rows {
        index := state.top+row
        if index >= len(state.results) { break }
        app := state.apps[state.results[index].index]
        y := f32(LAUNCHER_LIST_Y + row*LAUNCHER_ROW_HEIGHT)
        if index == state.selected {
            rl.DrawRectangleRounded({28, y, f32(width-56), LAUNCHER_ROW_HEIGHT-2}, 0.12, 8, {43, 57, 78, 255})
        }
        texture := icons[app.id]
        if texture.id != 0 {
            scale := f32(LAUNCHER_ICON_SIZE)/f32(max(texture.width, texture.height))
            icon_width, icon_height := f32(texture.width)*scale, f32(texture.height)*scale
            rl.DrawTexturePro(texture, {0, 0, f32(texture.width), f32(texture.height)},
                {42+(LAUNCHER_ICON_SIZE-icon_width)/2, y+4+(LAUNCHER_ICON_SIZE-icon_height)/2,
                 icon_width, icon_height}, {}, 0, {255, 255, 255, 255})
        } else {
            rl.DrawRectangleRounded({42, y+4, LAUNCHER_ICON_SIZE, LAUNCHER_ICON_SIZE},
                0.25, 8, {73, 104, 151, 255})
            text(font, "?", 42, y+7, 16, {239, 242, 249, 255}, LAUNCHER_ICON_SIZE, centered=true)
        }
        label_x := f32(42+LAUNCHER_ICON_SIZE+12)
        label_width := f32(width)-label_x-42
        text(font, app.name, label_x, y+3, 24, {239, 242, 249, 255}, label_width)
        detail := app.description if app.description != "" else app.id
        text(font, detail, label_x, y+29, 13, {139, 151, 173, 255}, label_width)
    }
    if len(state.results) == 0 && state.error == "" {
        text(font, "No matching applications", 42, LAUNCHER_LIST_Y+12, 22, {139, 151, 173, 255}, available)
    }
    footer := "Tab / Shift+Tab or arrows · Enter/click to start · Esc to return"
    if state.error != "" { footer = state.error }
    text(font, footer, 28, f32(height-35), 13, {139, 170, 192, 255}, f32(width-56))
    text(font, fmt.tprintf("%d results", len(state.results)), 28, f32(height-55), 12,
        {139, 151, 173, 255}, f32(width-56))
}
