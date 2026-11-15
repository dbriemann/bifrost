package main

import "core:c"
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import rl "../build/rl"

Options :: struct {
    command: string,
    filter: Filter,
    demo: bool,
    frames: int,
    screenshot: string,
}
Reply :: struct { ok: bool, error: string }
Request :: struct { token, id: string }

cstr :: proc(s: string) -> cstring { return strings.clone_to_cstring(s, context.temp_allocator) }
env :: proc(key: string) -> string { return os.get_env(key, context.temp_allocator) }
fail :: proc(message: string) { fmt.eprintln("bifrost:", message); os.exit(1) }

bridge :: proc(method: string, request: Request) -> (string, bool) {
    encoded, err := json.marshal(request, allocator = context.temp_allocator)
    if err != nil { return "Cannot encode bridge request", false }
    raw := bf_call(cstr(method), cstr(string(encoded)))
    if raw == nil { return strings.clone(string(bf_error())), false }
    defer bf_free(rawptr(raw))
    return strings.clone(string(raw)), true
}

parse_options :: proc() -> Options {
    options := Options{command = "toggle", filter = {-1, -1, ""}}
    args := os.args[1:]
    for i := 0; i < len(args); i += 1 {
        a := args[i]
        switch a {
        case "toggle", "hide", "doctor", "list": options.command = a
        case "--demo": options.demo = true
        case "--workspace", "--monitor", "--app", "--frames", "--screenshot":
            if i+1 >= len(args) { fail(fmt.tprintf("%s needs a value", a)) }
            i += 1
            value := args[i]
            switch a {
            case "--app": options.filter.app = value
            case "--screenshot": options.screenshot = value
            case "--frames":
                n, ok := strconv.parse_int(value)
                if !ok || n <= 0 { fail("--frames must be a positive integer") }
                options.frames = n
            case "--workspace", "--monitor":
                n := -1
                if value == "current" { n = -2 }
                else if value != "all" {
                    parsed, ok := strconv.parse_int(value)
                    if !ok || parsed < 0 { fail("scope must be all, current, or a zero-based index") }
                    n = parsed
                }
                if a == "--workspace" { options.filter.workspace = n }
                else { options.filter.monitor = n }
            }
        case "--help", "-h":
            fmt.println(`Bifrost — Odin/raylib window picker for GNOME Wayland
Usage: bifrost [toggle|hide|doctor|list] [options]
  --workspace all|current|INDEX   Include windows on this workspace (zero-based)
  --monitor all|current|INDEX     Include windows on this monitor (zero-based)
  --app DESKTOP_ID                Include one application
  --demo                         UI preview without the GNOME extension
  --frames N --screenshot FILE    Bounded demo rendering / PNG capture
Keys: 1–9, 0, a–z select; arrows navigate; Enter selects; Esc goes back/cancels.
PageUp/PageDown change overflow pages. Drag application tiles to save their order.
A second invocation closes the visible picker. Configuration: $XDG_STATE_HOME/bifrost/order.json`)
            os.exit(0)
        case: fail(fmt.tprintf("unknown argument: %s (see --help)", a))
        }
    }
    if !options.demo && (options.frames > 0 || options.screenshot != "") {
        fail("--frames and --screenshot are preview options; use --demo")
    }
    return options
}

state_path :: proc() -> string {
    root := env("XDG_STATE_HOME")
    if root == "" { root = fmt.tprintf("%s/.local/state", env("HOME")) }
    return strings.clone(fmt.tprintf("%s/bifrost/order.json", root))
}

load_order :: proc(path: string) -> Order {
    result := Order{version = 1}
    if !os.exists(path) { return result }
    bytes, err := os.read_entire_file(path, context.allocator)
    if err != nil { fail("cannot read saved application order") }
    defer delete(bytes)
    if json.unmarshal(bytes, &result) != nil || result.version != 1 {
        fail(fmt.tprintf("invalid saved order at %s; move it aside to reset", path))
    }
    seen := make(map[string]bool)
    defer delete(seen)
    for id in result.ids {
        if id == "" || seen[id] { fail("saved order contains duplicate or empty identities") }
        seen[id] = true
    }
    return result
}

save_order :: proc(order: Order, path: string) -> bool {
    bytes, err := json.marshal(order, allocator = context.temp_allocator)
    return err == nil && bf_save(cstr(path), cstr(string(bytes))) != 0
}

preview_snapshot :: proc() -> Snapshot {
    windows := []Window{
        {"1", "org.mozilla.firefox.desktop", "Firefox", "Wayland protocol documentation", "firefox", 0, 0},
        {"2", "org.mozilla.firefox.desktop", "Firefox", "Mail — Inbox", "firefox", 0, 0},
        {"3", "org.mozilla.firefox.desktop", "Firefox", "Bifrost project", "firefox", 1, 0},
        {"4", "org.gnome.TextEditor.desktop", "Text Editor", "PLAN.md — Bifrost", "org.gnome.TextEditor", 0, 0},
        {"5", "org.gnome.Ptyxis.desktop", "Terminal", "odin build src", "org.gnome.Ptyxis", 0, 0},
        {"6", "org.gnome.Ptyxis.desktop", "Terminal", "Development shell", "org.gnome.Ptyxis", 1, 0},
        {"7", "org.gnome.Nautilus.desktop", "Files", "Projects", "org.gnome.Nautilus", 0, 0},
        {"8", "org.gnome.Music.desktop", "Music", "Now playing", "org.gnome.Music", 0, 0},
        {"9", "org.gnome.Calendar.desktop", "Calendar", "November", "org.gnome.Calendar", 0, 0},
        {"10", "org.gnome.Settings.desktop", "Settings", "Displays", "org.gnome.Settings", 0, 0},
    }
    heap_windows := make([]Window, len(windows))
    copy(heap_windows, windows)
    return Snapshot{version = 1, token = "demo", generation = "demo", width = 1400, height = 950, windows = heap_windows}
}

// Return a raylib-owned image in both cases so callers can always UnloadImage.
// PNG/JPEG/etc use raylib's in-process decoders, not GdkPixbuf's external service.
load_icon_image :: proc(description, app_id: string) -> rl.Image {
    path := bf_app_icon(cstr(description), cstr(app_id))
    if path == nil { return {} }
    defer bf_free(rawptr(path))
    return decode_icon_image(string(path))
}

decode_icon_image :: proc(filename: string) -> rl.Image {
    if !strings.has_suffix(filename, ".svg") && !strings.has_suffix(filename, ".svgz") {
        image := rl.LoadImage(cstr(filename))
        if image.data != nil { return image }
    }
    width, height: c.int
    pixels := bf_pixels(cstr(filename), &width, &height)
    if pixels == nil { return {} }
    defer bf_free(pixels)
    borrowed := rl.Image{data = pixels, width = width, height = height, mipmaps = 1, format = .UNCOMPRESSED_R8G8B8A8}
    return rl.ImageCopy(borrowed)
}

load_icon :: proc(description, app_id: string) -> rl.Texture2D {
    image := load_icon_image(description, app_id)
    if image.data == nil {
        fmt.eprintf("bifrost: could not load application icon for %s: %s\n",
            app_id, string(bf_error()) if string(bf_error()) != "" else "no usable icon image found")
        return {}
    }
    defer rl.UnloadImage(image)
    texture := rl.LoadTextureFromImage(image)
    rl.SetTextureFilter(texture, .BILINEAR)
    return texture
}

font_codepoints :: proc(snapshot: Snapshot, bold := false) -> [dynamic]rune {
    codepoints := make([dynamic]rune)
    seen := make(map[rune]bool)
    defer delete(seen)
    for cp: rune = 32; cp < 127; cp += 1 { append(&codepoints, cp); seen[cp] = true }
    // The bold face only draws the ASCII brand, selection keys, and counts.
    // Request title characters and UI punctuation only from the regular face.
    // Unused arrows were missing from Noto/Open Sans and caused startup warnings.
    if !bold {
        for w in snapshot.windows {
            for s in ([2]string{w.name, w.title}) { for cp in s {
                if cp >= 32 && !seen[cp] { append(&codepoints, cp); seen[cp] = true }
            } }
        }
        for cp in "…·" { if !seen[cp] { append(&codepoints, cp); seen[cp] = true } }
    }
    return codepoints
}

load_font :: proc(snapshot: Snapshot, bold := false) -> rl.Font {
    codepoints := font_codepoints(snapshot, bold)
    defer delete(codepoints)
    paths := []string{env("BIFROST_FONT"), "/usr/share/fonts/google-noto-vf/NotoSans[wght].ttf", "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf", "/usr/share/fonts/dejavu-sans-fonts/DejaVuSans.ttf", "/usr/share/fonts/TTF/DejaVuSans.ttf"}
    if bold {
        paths = []string{env("BIFROST_BOLD_FONT"), "/usr/share/fonts/open-sans/OpenSans-Bold.ttf", "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf", "/usr/share/fonts/dejavu-sans-fonts/DejaVuSans-Bold.ttf", "/usr/share/fonts/TTF/DejaVuSans-Bold.ttf", "/usr/share/fonts/gnu-free/FreeSansBold.ttf"}
    }
    for path in paths {
        if path != "" && os.exists(path) {
            font := rl.LoadFontEx(cstr(path), 128, raw_data(codepoints), c.int(len(codepoints)))
            if font.texture.id != 0 { rl.SetTextureFilter(font.texture, .BILINEAR); return font }
        }
    }
    return rl.GetFontDefault()
}

text :: proc(font: rl.Font, value: string, x, y, size: f32, color: rl.Color, max_width: f32 = 10000, centered := false) {
    shown := value
    if rl.MeasureTextEx(font, cstr(shown), size, 0).x > max_width {
        shown = "…"
        for _, index in value {
            candidate := fmt.tprintf("%s…", value[:index])
            if rl.MeasureTextEx(font, cstr(candidate), size, 0).x > max_width { break }
            shown = candidate
        }
    }
    offset: f32
    if centered { offset = (max_width - rl.MeasureTextEx(font, cstr(shown), size, 0).x) / 2 }
    rl.DrawTextEx(font, cstr(shown), {x+offset, y}, size, 0, color)
}

// Give large labels two centered lines instead of shrinking the requested size.
name_text :: proc(font: rl.Font, value: string, x, y, width: f32, size: f32 = 30) {
    color := rl.Color{232, 237, 248, 255}
    if rl.MeasureTextEx(font, cstr(value), size, 0).x <= width {
        text(font, value, x, y, size, color, width, centered=true)
        return
    }
    cut, space := 0, 0
    for r, index in value {
        if rl.MeasureTextEx(font, cstr(value[:index]), size, 0).x > width { break }
        cut = index
        if r == ' ' { space = index }
    }
    if space > 0 { cut = space }
    if cut == 0 { text(font, value, x, y, size, color, width, centered=true); return }
    text(font, strings.trim_space(value[:cut]), x, y, size, color, width, centered=true)
    text(font, strings.trim_space(value[cut:]), x, y+size+4, size, color, width, centered=true)
}

// Only reserve a second label line when this view actually needs one. The
// window view also has an application subtitle, placed directly after its title.
name_lines :: proc(font: rl.Font, value: string) -> int {
    return 1 if rl.MeasureTextEx(font, cstr(value), 30, 0).x <= TILE_WIDTH-16 else 2
}

view_tile_height :: proc(font: rl.Font, groups: []Group, snapshot: Snapshot, child: int) -> int {
    lines := 1
    if child < 0 {
        for group in groups { lines = max(lines, name_lines(font, group.name)) }
    } else {
        for index in groups[child].windows { lines = max(lines, name_lines(font, snapshot.windows[index].title)) }
    }
    return 154 + (lines-1)*34 + (34 if child >= 0 else 0)
}

selection_held :: proc() -> bool {
    for key := 48; key <= 90; key += 1 { if rl.IsKeyDown(rl.KeyboardKey(key)) { return true } }
    for key := 320; key <= 329; key += 1 { if rl.IsKeyDown(rl.KeyboardKey(key)) { return true } }
    return false
}

run_picker :: proc(options: Options, snapshot: Snapshot, order: ^Order, path: string) {
    groups := build_groups(order^, snapshot, options.filter)
    defer free_groups(&groups)
    if bf_wayland_prepare() == 0 { fail(string(bf_error())) }
    // Draw and hit-test in the same logical grid, then enlarge the entire UI.
    // Reduce the scale only when even a single tile would exceed the work area.
    ui_scale := min(f32(1.5), f32(snapshot.width-16)/f32(CELL_WIDTH+48), f32(snapshot.height-16)/f32(CELL_HEIGHT+142))
    available_width := int(f32(snapshot.width)/ui_scale)
    available_height := int(f32(snapshot.height)/ui_scale)
    cols := max(1, min(6, (available_width - 56) / CELL_WIDTH))
    largest_view := len(groups)
    for group in groups { largest_view = max(largest_view, len(group.windows)) }
    rows := max(1, min(6, (available_height - 170) / CELL_HEIGHT, (largest_view+cols-1)/cols))
    capacity := min(len(KEYS), cols * rows)
    width := c.int(cols * CELL_WIDTH + 48)
    // Keep geometry identical between root/child views and counts.
    height := c.int(rows * CELL_HEIGHT + 142)
    rl.SetTraceLogLevel(.WARNING)
    rl.SetConfigFlags({.WINDOW_UNDECORATED, .WINDOW_HIGHDPI, .VSYNC_HINT})
    rl.InitWindow(c.int(f32(width)*ui_scale), c.int(f32(height)*ui_scale), cstr(fmt.tprintf("Bifrost · %s", snapshot.token)))
    if !rl.IsWindowReady() { fail("raylib could not create its Wayland window") }
    defer rl.CloseWindow()
    if bf_wayland_active() == 0 { fail("picker did not use native Wayland") }
    rl.SetExitKey(.KEY_NULL)
    rl.SetTargetFPS(60)
    rl.SetMouseScale(1/ui_scale, 1/ui_scale)
    camera := rl.Camera2D{zoom = ui_scale}
    font := load_font(snapshot)
    defer if font.texture.id != rl.GetFontDefault().texture.id { rl.UnloadFont(font) }
    key_font := load_font(snapshot, bold=true)
    defer if key_font.texture.id != rl.GetFontDefault().texture.id { rl.UnloadFont(key_font) }
    // Fit the window to the compact view heights, keeping its size stable when
    // opening a group or returning to applications.
    grid_height := 0
    for view := -1; view < len(groups); view += 1 {
        if view >= 0 && len(groups[view].windows) <= 1 { continue }
        items := len(groups) if view < 0 else len(groups[view].windows)
        step := view_tile_height(font, groups[:], snapshot, view) + 12
        view_rows := max(1, min(6, (available_height-170)/step, (items+cols-1)/cols))
        grid_height = max(grid_height, view_rows*step)
    }
    height = c.int(grid_height+142)
    rl.SetWindowSize(c.int(f32(width)*ui_scale), c.int(f32(height)*ui_scale))
    icons := make(map[string]rl.Texture2D)
    for group in groups { icons[group.app] = load_icon(group.icon, group.app) }
    defer { for _, texture in icons { if texture.id != 0 { rl.UnloadTexture(texture) } }; delete(icons) }
    if !options.demo {
        // Flush the mapped native window before asking Shell to find and present it.
        rl.BeginDrawing(); rl.ClearBackground({19, 23, 34, 255}); rl.EndDrawing()
        response, ok := bridge("Present", {token = snapshot.token})
        defer delete(response)
        if !ok { fail(response) }
    }
    child, page, highlighted := -1, 0, 0
    gesture := Pointer_Gesture{}
    armed, done, activated, had_focus := true, false, false, false
    status := ""
    frame := 0
    for !done && !rl.WindowShouldClose() {
        cmd := bf_poll()
        if cmd != nil { bf_free(rawptr(cmd)); break }
        focused := rl.IsWindowFocused()
        if focused { had_focus = true }
        if had_focus && !focused && !options.demo { break }
        if !armed && !selection_held() { armed = true }
        count := len(groups)
        if child >= 0 { count = len(groups[child].windows) }
        tile_height := view_tile_height(font, groups[:], snapshot, child)
        cell_height := tile_height+12
        capacity = min(len(KEYS), cols*max(1, (int(height)-142)/cell_height))
        pages := max(1, (count + capacity - 1) / capacity)
        visible := min(capacity, max(0, count - page*capacity))
        mouse := rl.GetMousePosition()
        pressed := rl.IsMouseButtonPressed(.LEFT)
        down := rl.IsMouseButtonDown(.LEFT)
        released := rl.IsMouseButtonReleased(.LEFT)
        // Treat release-frame motion as a drag before resolving the drop target.
        dropping := gesture.active && child < 0 &&
            (gesture.dragging ||
             (mouse.x-gesture.origin_x)*(mouse.x-gesture.origin_x) +
             (mouse.y-gesture.origin_y)*(mouse.y-gesture.origin_y) >= 64)
        hovered := pointer_target(mouse.x, mouse.y, cols, capacity, count, page, dropping, gesture.source, tile_height=tile_height, cell_height=cell_height)
        escape := rl.IsKeyPressed(.ESCAPE)
        pointer_was_active := gesture.active
        pointer_action := pointer_step(&gesture, mouse.x, mouse.y, hovered,
            pressed, down, released, child < 0, escape)
        choose := -1
        if escape {
            if pointer_was_active { /* Cancelling the drag keeps the picker open. */ }
            else if child >= 0 { child = -1; page = 0; highlighted = 0; status = "" }
            else { done = true }
        }
        if !gesture.active && !escape && pointer_action.kind == .None {
            if rl.IsKeyPressed(.PAGE_DOWN) { page = (page + 1) % pages; highlighted = page*capacity }
            if rl.IsKeyPressed(.PAGE_UP) { page = (page + pages - 1) % pages; highlighted = page*capacity }
            if count > 0 {
                if rl.IsKeyPressed(.RIGHT) { highlighted = min(count-1, highlighted+1) }
                if rl.IsKeyPressed(.LEFT) { highlighted = max(0, highlighted-1) }
                if rl.IsKeyPressed(.DOWN) { highlighted = min(count-1, highlighted+cols) }
                if rl.IsKeyPressed(.UP) { highlighted = max(0, highlighted-cols) }
                page = highlighted / capacity
                if rl.IsKeyPressed(.ENTER) && armed { choose = highlighted }
            }
            key := rl.GetKeyPressed()
            for key != .KEY_NULL {
                index := -1
                n := int(key)
                if n >= 48 && n <= 57 { index = (n - 49 + 10) % 10 }
                if n >= 320 && n <= 329 { index = (n - 321 + 10) % 10 }
                if armed && index >= 0 && index < visible { choose = page*capacity+index }
                key = rl.GetKeyPressed()
            }
            cp := rl.GetCharPressed()
            for cp != 0 {
                if cp >= 'A' && cp <= 'Z' { cp += 'a'-'A' }
                if armed && cp >= 'a' && cp <= 'z' {
                    index := 10 + int(cp-'a')
                    if index < visible { choose = page*capacity+index }
                }
                cp = rl.GetCharPressed()
            }
        }
        switch pointer_action.kind {
        case .Reorder:
            reorder(order, groups[:], pointer_action.source, pointer_action.target)
            free_groups(&groups)
            groups = build_groups(order^, snapshot, options.filter)
            highlighted = pointer_action.target
            if options.demo { status = "Preview order changed (not saved)" }
            else if save_order(order^, path) { status = "Application order saved" }
            else { status = "Could not save order; changes last until exit" }
        case .Select:
            choose = pointer_action.target
        case .None:
        }
        if choose >= 0 && choose < count && !done {
            group := &groups[choose] if child < 0 else &groups[child]
            if child < 0 && len(group.windows) > 1 {
                child = choose; page = 0; highlighted = 0; armed = false; status = ""
            } else {
                index := group.windows[0] if child < 0 else group.windows[choose]
                if options.demo { status = fmt.aprintf("Preview: %s", snapshot.windows[index].title) }
                else {
                    response, ok := bridge("Activate", {snapshot.token, snapshot.windows[index].id})
                    reply: Reply
                    if ok && json.unmarshal_string(response, &reply) == nil && reply.ok { done = true; activated = true }
                    else if !ok { status = response }
                    else { status = reply.error }
                }
                armed = false
            }
        }
        rl.BeginDrawing()
        rl.ClearBackground({19, 23, 34, 255})
        rl.BeginMode2D(camera)
        rl.DrawRectangleRounded({0, 0, f32(width), f32(height)}, 0.06, 12, {19, 23, 34, 255})
        mode := "all windows"
        if options.filter.workspace != -1 { mode = "workspace" }
        if options.filter.monitor != -1 { mode = "monitor" }
        if options.filter.workspace != -1 && options.filter.monitor != -1 { mode = "workspace + monitor" }
        if options.filter.app != "" { mode = "application" }
        rl.DrawTextEx(key_font, "BIFROST", {28, 22}, 26, 2, {119, 144, 178, 255})
        brand_width := rl.MeasureTextEx(key_font, "BIFROST", 26, 2).x
        mode_x := 28 + brand_width + 12
        text(font, fmt.tprintf("(%s)", mode), mode_x, 27, 20,
            {139, 151, 173, 255}, max(0, f32(width)-mode_x-28))
        subheading := ""
        if child >= 0 { subheading = fmt.tprintf("%s · Choose a window · Esc to go back", groups[child].name) }
        if options.demo { subheading = fmt.tprintf("%s%sPreview", subheading, " · " if subheading != "" else "") }
        text(font, subheading, 28, 58, 14, {139, 151, 173, 255}, f32(width-56))
        // Recompute after a view transition in this frame.
        tile_height = view_tile_height(font, groups[:], snapshot, child)
        cell_height = tile_height+12
        capacity = min(len(KEYS), cols*max(1, (int(height)-142)/cell_height))
        count = len(groups)
        if child >= 0 { count = len(groups[child].windows) }
        visible = min(capacity, max(0, count-page*capacity))
        for local in 0..<visible {
            index := page*capacity+local
            group := &groups[index] if child < 0 else &groups[child]
            x := f32(GRID_X + (local%cols)*CELL_WIDTH)
            y := f32(GRID_Y + (local/cols)*cell_height)
            tile := rl.Rectangle{x, y, TILE_WIDTH, f32(tile_height)}
            hot := rl.CheckCollisionPointRec(mouse, tile)
            if hot && !gesture.active { highlighted = index }
            fill := rl.Color{29, 35, 49, 255}
            if highlighted == index && !gesture.dragging { fill = {43, 57, 78, 255} }
            if gesture.dragging && index == gesture.source { fill = {24, 29, 41, 255} }
            rl.DrawRectangleRounded(tile, 0.15, 8, fill)
            stack := min(3, len(group.windows)) if child < 0 else 1
            texture := icons[group.app]
            for layer := stack-1; layer >= 0; layer -= 1 {
                offset := f32(layer*7)
                destination := rl.Rectangle{x+62+offset, y+20-offset, 80, 80}
                if texture.id != 0 {
                    tint := rl.Color{255, 255, 255, 255} if layer == 0 else rl.Color{170, 181, 199, 210}
                    rl.DrawTexturePro(texture, {0, 0, f32(texture.width), f32(texture.height)}, destination, {}, 0, tint)
                } else {
                    rl.DrawRectangleRounded(destination, 0.25, 8, {73, 104, 151, 255})
                    text(font, "APP", destination.x+17, destination.y+25, 20, {239, 242, 249, 255})
                }
            }
            rl.DrawRectangleRounded({x+7, y+7, 52, 54}, 0.2, 6, {9, 14, 24, 245})
            alphabet := string(KEYS)
            text(key_font, alphabet[local:local+1], x+7, y+14, 34, {157, 218, 244, 255}, 52, centered=true)
            if child < 0 && len(group.windows) > 1 {
                text(key_font, fmt.tprintf("%d", len(group.windows)), x+152, y+77, 30, {157, 218, 244, 255}, 48, centered=true)
            }
            title := group.name
            if child >= 0 { title = snapshot.windows[group.windows[index]].title }
            name_text(font, title, x+8, y+112, TILE_WIDTH-16)
            if child >= 0 { text(font, group.name, x+8, y+f32(154+(name_lines(font, title)-1)*34), 22, {139, 151, 173, 255}, TILE_WIDTH-16, centered=true) }
        }
        if gesture.dragging && child < 0 {
            if hovered >= 0 && hovered != gesture.source {
                local := hovered-page*capacity
                x := f32(GRID_X + (local%cols)*CELL_WIDTH)
                y := f32(GRID_Y + (local/cols)*cell_height)
                if gesture.source < hovered { x += TILE_WIDTH+2 } else { x -= 6 }
                rl.DrawRectangle(c.int(x), c.int(y), 4, c.int(tile_height), {157, 218, 244, 255})
            }
            source := groups[gesture.source]
            gx := min(mouse.x+14, f32(width-214))
            gy := min(mouse.y+14, f32(height-186))
            rl.DrawRectangleRounded({gx, gy, 204, 172}, 0.15, 8, {48, 62, 84, 245})
            texture := icons[source.app]
            if texture.id != 0 {
                rl.DrawTexturePro(texture, {0, 0, f32(texture.width), f32(texture.height)},
                    {gx+70, gy+9, 64, 64}, {}, 0, {255, 255, 255, 235})
            } else {
                text(font, "APP", gx+83, gy+28, 20, {239, 242, 249, 255})
            }
            name_text(font, source.name, gx+8, gy+88, 188, 28)
        }
        if count == 0 { text(font, "No matching windows", 30, 112, 22, {139, 151, 173, 255}) }
        footer := "Type a key to switch · Drag to reorder · Esc to cancel"
        if status != "" { footer = status }
        if gesture.dragging && child < 0 { footer = "Release to save position · Esc to cancel drag" }
        text(font, footer, 28, f32(height-35), 13, {139, 170, 192, 255}, f32(width-50))
        if pages > 1 { text(font, fmt.tprintf("Page %d/%d · PgUp/PgDn", page+1, pages), 28, f32(height-57), 12, {139, 151, 173, 255}) }
        rl.EndMode2D()
        rl.EndDrawing()
        frame += 1
        if options.frames > 0 && frame >= options.frames {
            if options.screenshot != "" { rl.TakeScreenshot(cstr(options.screenshot)) }
            done = true
        }
        free_all(context.temp_allocator)
    }
    if !options.demo && !activated {
        response, _ := bridge("Dismiss", {token = snapshot.token})
        delete(response)
    }
}

main :: proc() {
    options := parse_options()
    defer bf_shutdown()
    if options.command == "hide" && options.demo { return }
    if !options.demo && options.command != "doctor" && options.command != "list" {
        result := bf_instance(cstr(options.command))
        if result < 0 { fail(string(bf_error())) }
        if result == 0 || options.command == "hide" { return }
    }
    snapshot: Snapshot
    if options.demo { snapshot = preview_snapshot() }
    else {
        response, ok := bridge("Snapshot", {})
        if !ok { fail(fmt.tprintf("GNOME bridge unavailable. Install/enable bifrost@dlb.local.\n%s", response)) }
        if json.unmarshal_string(response, &snapshot) != nil || snapshot.version != 1 || snapshot.token == "" {
            fail("unsupported or malformed GNOME bridge snapshot")
        }
        if options.command == "doctor" || options.command == "list" {
            if options.command == "list" { fmt.println(response) }
            else { fmt.printf("GNOME bridge v%d connected; %d eligible windows; pointer monitor %d; native Wayland required.\n", snapshot.version, len(snapshot.windows), snapshot.monitor) }
            dismissed, _ := bridge("Dismiss", {token = snapshot.token}); delete(dismissed)
            return
        }
    }
    if snapshot.width < 240 || snapshot.height < 320 { fail("monitor work area is too small for the picker") }
    path := state_path()
    order := Order{version = 1} if options.demo else load_order(path)
    if observe(&order, snapshot.windows) && !options.demo && !save_order(order, path) {
        fail(fmt.tprintf("could not save application order: %s", string(bf_error())))
    }
    run_picker(options, snapshot, &order, path)
}
