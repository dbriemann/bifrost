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

load_icon :: proc(description: string) -> rl.Texture2D {
    path := bf_icon(cstr(description))
    if path == nil { return {} }
    defer bf_free(rawptr(path))
    width, height: c.int
    pixels := bf_pixels(path, &width, &height)
    if pixels == nil { return {} }
    defer bf_free(pixels)
    image := rl.Image{data = pixels, width = width, height = height, mipmaps = 1, format = .UNCOMPRESSED_R8G8B8A8}
    texture := rl.LoadTextureFromImage(image)
    rl.SetTextureFilter(texture, .BILINEAR)
    return texture
}

load_font :: proc(snapshot: Snapshot) -> rl.Font {
    codepoints := make([dynamic]rune)
    seen := make(map[rune]bool)
    defer delete(codepoints)
    defer delete(seen)
    for cp: rune = 32; cp < 127; cp += 1 { append(&codepoints, cp); seen[cp] = true }
    for w in snapshot.windows {
        for s in ([2]string{w.name, w.title}) { for cp in s {
            if !seen[cp] { append(&codepoints, cp); seen[cp] = true }
        } }
    }
    for cp in "…·←→–" { if !seen[cp] { append(&codepoints, cp); seen[cp] = true } }
    for path in ([5]string{env("BIFROST_FONT"), "/usr/share/fonts/google-noto-vf/NotoSans[wght].ttf", "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf", "/usr/share/fonts/dejavu-sans-fonts/DejaVuSans.ttf", "/usr/share/fonts/TTF/DejaVuSans.ttf"}) {
        if path != "" && os.exists(path) {
            font := rl.LoadFontEx(cstr(path), 40, raw_data(codepoints), c.int(len(codepoints)))
            if font.texture.id != 0 { rl.SetTextureFilter(font.texture, .BILINEAR); return font }
        }
    }
    return rl.GetFontDefault()
}

text :: proc(font: rl.Font, value: string, x, y, size: f32, color: rl.Color, max_width: f32 = 10000) {
    shown := value
    if rl.MeasureTextEx(font, cstr(shown), size, 0).x > max_width {
        for _, index in value {
            candidate := fmt.tprintf("%s…", value[:index])
            if rl.MeasureTextEx(font, cstr(candidate), size, 0).x > max_width { break }
            shown = candidate
        }
    }
    rl.DrawTextEx(font, cstr(shown), {x, y}, size, 0, color)
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
    cols := max(1, min(6, (snapshot.width - 56) / 148))
    largest_view := len(groups)
    for group in groups { largest_view = max(largest_view, len(group.windows)) }
    rows := max(1, min(6, (snapshot.height - 170) / 156, (largest_view+cols-1)/cols))
    capacity := min(len(KEYS), cols * rows)
    width := c.int(cols * 148 + 48)
    // Keep geometry identical between root/child views and counts.
    height := c.int(rows * 156 + 142)
    rl.SetTraceLogLevel(.WARNING)
    rl.SetConfigFlags({.WINDOW_UNDECORATED, .WINDOW_HIGHDPI, .VSYNC_HINT})
    rl.InitWindow(width, height, cstr(fmt.tprintf("Bifrost · %s", snapshot.token)))
    if !rl.IsWindowReady() { fail("raylib could not create its Wayland window") }
    defer rl.CloseWindow()
    if bf_wayland_active() == 0 { fail("picker did not use native Wayland") }
    rl.SetExitKey(.KEY_NULL)
    rl.SetTargetFPS(60)
    font := load_font(snapshot)
    defer if font.texture.id != rl.GetFontDefault().texture.id { rl.UnloadFont(font) }
    icons := make(map[string]rl.Texture2D)
    for group in groups { icons[group.app] = load_icon(group.icon) }
    defer { for _, texture in icons { if texture.id != 0 { rl.UnloadTexture(texture) } }; delete(icons) }
    if !options.demo {
        // Flush the mapped native window before asking Shell to find and present it.
        rl.BeginDrawing(); rl.ClearBackground({19, 23, 34, 255}); rl.EndDrawing()
        response, ok := bridge("Present", {token = snapshot.token})
        defer delete(response)
        if !ok { fail(response) }
    }
    child, page, highlighted, drag := -1, 0, 0, -1
    drag_origin: rl.Vector2
    dragging, armed, done, activated, had_focus := false, true, false, false, false
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
        pages := max(1, (count + capacity - 1) / capacity)
        visible := min(capacity, max(0, count - page*capacity))
        hovered := -1
        mouse := rl.GetMousePosition()
        for i in 0..<visible {
            x := f32(24 + (i % cols)*148)
            y := f32(88 + (i / cols)*156)
            if rl.CheckCollisionPointRec(mouse, {x, y, 136, 144}) { hovered = page*capacity+i }
        }
        if rl.IsMouseButtonPressed(.LEFT) {
            drag = hovered; drag_origin = mouse; dragging = false
        }
        if drag >= 0 && child < 0 && rl.IsMouseButtonDown(.LEFT) {
            dx, dy := mouse.x-drag_origin.x, mouse.y-drag_origin.y
            if dx*dx + dy*dy > 64 { dragging = true }
        }
        choose := -1
        if rl.IsKeyPressed(.ESCAPE) {
            if drag >= 0 { drag = -1; dragging = false }
            else if child >= 0 { child = -1; page = 0; highlighted = 0; status = "" }
            else { done = true }
        }
        if drag < 0 {
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
        if rl.IsMouseButtonReleased(.LEFT) && drag >= 0 {
            if dragging && hovered >= 0 && hovered != drag && child < 0 {
                reorder(order, groups[:], drag, hovered)
                free_groups(&groups)
                groups = build_groups(order^, snapshot, options.filter)
                if !options.demo && !save_order(order^, path) { status = "Could not save order; changes last until exit" }
            } else if !dragging && hovered == drag { choose = hovered }
            drag = -1; dragging = false
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
        rl.DrawRectangleRounded({0, 0, f32(width), f32(height)}, 0.06, 12, {19, 23, 34, 255})
        heading := "Applications" if child < 0 else groups[child].name
        text(font, heading, 28, 22, 26, {239, 242, 249, 255}, f32(width-150))
        text(font, "BIFROST", f32(width-118), 28, 14, {119, 144, 178, 255})
        subheading := "All windows" if options.filter == (Filter{-1, -1, ""}) else "Filtered windows"
        if child >= 0 { subheading = "Choose a window · Esc to go back" }
        if options.demo { subheading = fmt.tprintf("%s · Preview", subheading) }
        text(font, subheading, 28, 58, 14, {139, 151, 173, 255})
        // Recompute after a view transition in this frame.
        count = len(groups)
        if child >= 0 { count = len(groups[child].windows) }
        visible = min(capacity, max(0, count-page*capacity))
        for local in 0..<visible {
            index := page*capacity+local
            group := &groups[index] if child < 0 else &groups[child]
            x := f32(24 + (local%cols)*148)
            y := f32(88 + (local/cols)*156)
            tile := rl.Rectangle{x, y, 136, 144}
            hot := rl.CheckCollisionPointRec(mouse, tile)
            if hot { highlighted = index }
            fill := rl.Color{29, 35, 49, 255}
            if highlighted == index { fill = {43, 57, 78, 255} }
            if dragging && hot { fill = {47, 84, 100, 255} }
            rl.DrawRectangleRounded(tile, 0.15, 8, fill)
            stack := min(3, len(group.windows)) if child < 0 else 1
            texture := icons[group.app]
            for layer := stack-1; layer >= 0; layer -= 1 {
                offset := f32(layer*7)
                destination := rl.Rectangle{x+27+offset, y+12-offset, 80, 80}
                if texture.id != 0 {
                    tint := rl.Color{255, 255, 255, 255} if layer == 0 else rl.Color{170, 181, 199, 210}
                    rl.DrawTexturePro(texture, {0, 0, f32(texture.width), f32(texture.height)}, destination, {}, 0, tint)
                } else {
                    rl.DrawRectangleRounded(destination, 0.25, 8, {73, 104, 151, 255})
                    text(font, "APP", destination.x+17, destination.y+25, 20, {239, 242, 249, 255})
                }
            }
            rl.DrawRectangleRounded({x+7, y+7, 26, 27}, 0.2, 6, {9, 14, 24, 245})
            alphabet := string(KEYS)
            text(font, alphabet[local:local+1], x+15, y+10, 17, {157, 218, 244, 255})
            if child < 0 && len(group.windows) > 1 {
                text(font, fmt.tprintf("%d", len(group.windows)), x+111, y+79, 15, {157, 218, 244, 255})
            }
            title := group.name
            if child >= 0 { title = snapshot.windows[group.windows[index]].title }
            text(font, title, x+9, y+108, 15, {232, 237, 248, 255}, 118)
            if child >= 0 { text(font, group.name, x+9, y+127, 11, {139, 151, 173, 255}, 118) }
        }
        if count == 0 { text(font, "No matching windows", 30, 112, 22, {139, 151, 173, 255}) }
        footer := "Type a key to switch · Drag to reorder · Esc to cancel"
        if status != "" { footer = status }
        text(font, footer, 28, f32(height-35), 13, {139, 170, 192, 255}, f32(width-50))
        if pages > 1 { text(font, fmt.tprintf("Page %d/%d · PgUp/PgDn", page+1, pages), 28, f32(height-57), 12, {139, 151, 173, 255}) }
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
