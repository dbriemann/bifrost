package main

import "core:c"
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:time"
import rl "../build/rl"

Options :: struct {
    command: string,
    filter: Filter,
    demo: bool,
    backdrop: bool,
    frames: int,
    screenshot: string,
    scale: f32,
}
Reply :: struct { ok: bool, error: string }
Request :: struct { token, id: string, backdrop: bool }

Startup_Profile :: struct { enabled: bool, start, last: time.Tick }
startup_profile: Startup_Profile

startup_mark :: proc(stage: string) {
    if !startup_profile.enabled { return }
    now := time.tick_now()
    fmt.eprintf("bifrost startup: %-18s %7.2f ms (+%.2f ms)\n", stage,
        time.duration_milliseconds(time.tick_diff(startup_profile.start, now)),
        time.duration_milliseconds(time.tick_diff(startup_profile.last, now)))
    startup_profile.last = now
}

cstr :: proc(s: string) -> cstring { return strings.clone_to_cstring(s, context.temp_allocator) }
env :: proc(key: string) -> string { return os.get_env(key, context.temp_allocator) }
launcher_report :: proc(name: string, value: int) {
    when ODIN_OS == .Darwin {
        directory := env("BIFROST_LAUNCH_DIR")
        if directory != "" {
            if bf_save(cstr(fmt.tprintf("%s/%s", directory, name)), cstr(fmt.tprintf("%d", value))) == 0 {
                fmt.eprintln("bifrost: could not report status to command launcher")
            }
        }
    }
}
fail :: proc(message: string) {
    fmt.eprintln("bifrost:", message)
    launcher_report("status", 1)
    os.exit(1)
}

bridge :: proc(method: string, request: Request) -> (string, bool) {
    encoded, err := json.marshal(request, allocator = context.temp_allocator)
    if err != nil { return "Cannot encode bridge request", false }
    raw := bf_call(cstr(method), cstr(string(encoded)))
    if raw == nil { return strings.clone(string(bf_error())), false }
    defer bf_free(rawptr(raw))
    return strings.clone(string(raw)), true
}

parse_options :: proc(args: []string) -> Options {
    options := Options{command = "toggle", filter = {-1, -1, ""}, backdrop=true, scale=DEFAULT_UI_SCALE}
    for i := 0; i < len(args); i += 1 {
        a := args[i]
        switch a {
        case "toggle", "hide", "doctor", "list", "authorize": options.command = a
        case "--demo": options.demo = true
        case "--backdrop": options.backdrop = true
        case "--no-backdrop": options.backdrop = false
        case "--workspace", "--monitor", "--app", "--frames", "--screenshot", "--scale":
            if i+1 >= len(args) { fail(fmt.tprintf("%s needs a value", a)) }
            i += 1
            value := args[i]
            switch a {
            case "--app": options.filter.app = value
            case "--screenshot": options.screenshot = value
            case "--scale":
                scale, ok := parse_ui_scale(value)
                if !ok { fail("--scale must be a number from 0.5 to 3 (default 1.5)") }
                options.scale = scale
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
            fmt.println(`Bifrost — Odin/raylib window picker for GNOME Wayland and macOS
Usage: bifrost [toggle|hide|doctor|list|authorize] [options]
  authorize                      macOS: request Accessibility and open its settings
  --workspace all|current|INDEX   Workspace filter (GNOME only; macOS supports all)
  --monitor all|current|INDEX     Include windows on this monitor (zero-based)
  --app APP_ID                    Include one desktop ID / macOS bundle identifier
  --no-backdrop                   Disable desktop backdrop (enabled by default)
  --backdrop                      Dim desktop (GNOME also blurs)
  --scale FACTOR                  UI pixel scale, 0.5–3 (default 1.5; DPI-aware)
  --demo                         UI preview without window access permissions
  --frames N --screenshot FILE    Bounded demo rendering / PNG capture
Keys: 1–9, 0, a–z select; arrows or Tab/Shift+Tab navigate; Enter selects; Esc goes back/cancels.
PageUp/PageDown change overflow pages. Drag application tiles to save their order.
Space opens installed-app search; type to filter, Up/Down or Tab/Shift+Tab to select, Enter/click to start.
A second invocation closes the visible picker.`)
            fmt.println("Saved order:", state_path())
            launcher_report("status", 0)
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
    when ODIN_OS == .Darwin {
        return strings.clone(fmt.tprintf("%s/Library/Application Support/Bifrost/order.json", env("HOME")))
    }
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
    when ODIN_OS == .Darwin {
        windows = []Window{
            {"1", "com.apple.Safari", "Safari", "Documentation", "", -1, 0},
            {"2", "com.apple.Safari", "Safari", "Mail — Inbox", "", -1, 0},
            {"3", "com.apple.Safari", "Safari", "Bifrost project", "", -1, 0},
            {"4", "com.apple.TextEdit", "TextEdit", "PLAN.md — Bifrost", "", -1, 0},
            {"5", "com.apple.Terminal", "Terminal", "odin build src", "", -1, 0},
            {"6", "com.apple.Terminal", "Terminal", "Development shell", "", -1, 0},
            {"7", "com.apple.finder", "Finder", "Projects", "", -1, 0},
            {"8", "com.apple.Music", "Music", "Now playing", "", -1, 0},
            {"9", "com.apple.iCal", "Calendar", "November", "", -1, 0},
            {"10", "com.apple.systempreferences", "System Settings", "Displays", "", -1, 0},
        }
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
    when ODIN_OS == .Darwin {
        paths = []string{env("BIFROST_FONT"), "/System/Library/Fonts/Supplemental/Arial.ttf", "/System/Library/Fonts/Helvetica.ttc"}
        if bold { paths = []string{env("BIFROST_BOLD_FONT"), "/System/Library/Fonts/Supplemental/Arial Bold.ttf", "/System/Library/Fonts/Helvetica.ttc"} }
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

view_grid_layout :: proc(font: rl.Font, groups: []Group, snapshot: Snapshot,
    child, page, available_width, available_height: int) -> Grid_Layout {
    count := len(groups) if child < 0 else len(groups[child].windows)
    return grid_layout(count, view_tile_height(font, groups, snapshot, child),
        available_width, available_height, page)
}

size_picker :: proc(width, height: c.int, scale: f32) {
    logical_width, logical_height := c.int(f32(width)*scale), c.int(f32(height)*scale)
    bf_window_size_limits(logical_width, logical_height)
    rl.SetWindowSize(logical_width, logical_height)
}

selection_held :: proc() -> bool {
    for key := 48; key <= 90; key += 1 { if rl.IsKeyDown(rl.KeyboardKey(key)) { return true } }
    for key := 320; key <= 329; key += 1 { if rl.IsKeyDown(rl.KeyboardKey(key)) { return true } }
    return false
}

take_screenshot :: proc(filename: string) {
    when ODIN_OS == .Darwin {
        // The bundled raylib screenshot path applies Retina scaling twice.
        // Read the native framebuffer dimensions once and let raylib encode it.
        width, height: c.int
        pixels := bf_screen_pixels(&width, &height)
        if pixels == nil { fail("could not read picker framebuffer") }
        defer rl.MemFree(pixels)
        image := rl.Image{data=pixels, width=width, height=height, mipmaps=1, format=.UNCOMPRESSED_R8G8B8A8}
        if !rl.ExportImage(image, cstr(filename)) { fail("could not save picker screenshot") }
    } else { rl.TakeScreenshot(cstr(filename)) }
}

run_picker :: proc(options: Options, snapshot: Snapshot, order: ^Order, path: string) {
    groups := build_groups(order^, snapshot, options.filter)
    defer free_groups(&groups)
    if bf_display_prepare() == 0 { fail(string(bf_error())) }
    startup_mark("display connection")
    // Start conservatively, then resolve backing scale from the native window
    // before choosing fonts/layout or presenting its first complete frame.
    ui_scale := picker_scale(options.scale, 1, snapshot.width, snapshot.height)
    available_width := int(f32(snapshot.width-16)/ui_scale)
    available_height := int(f32(snapshot.height-16)/ui_scale)
    grid := grid_layout(len(groups), 188, available_width, available_height)
    cols, capacity := grid.cols, grid.capacity
    width, height := c.int(grid.width), c.int(grid.height)
    rl.SetTraceLogLevel(.WARNING)
    window_flags := rl.ConfigFlags{.WINDOW_UNDECORATED, .WINDOW_HIGHDPI, .WINDOW_RESIZABLE, .VSYNC_HINT}
    when ODIN_OS == .Darwin { window_flags += {.WINDOW_HIDDEN} }
    rl.SetConfigFlags(window_flags)
    rl.InitWindow(c.int(f32(width)*ui_scale), c.int(f32(height)*ui_scale), cstr(fmt.tprintf("Bifrost · %s", snapshot.token)))
    if !rl.IsWindowReady() { fail("raylib could not create the picker window") }
    defer rl.CloseWindow()
    if bf_display_active() == 0 { fail("picker did not use the required native display backend") }
    startup_mark("window and OpenGL")
    rl.SetExitKey(.KEY_NULL)
    rl.SetTargetFPS(60)
    backing_scale := max(rl.GetWindowScaleDPI().x, rl.GetWindowScaleDPI().y)
    ui_scale = picker_scale(options.scale, backing_scale, snapshot.width, snapshot.height)
    available_width = int(f32(snapshot.width-16)/ui_scale)
    available_height = int(f32(snapshot.height-16)/ui_scale)
    camera := rl.Camera2D{zoom = ui_scale}
    font := load_font(snapshot)
    defer if font.texture.id != rl.GetFontDefault().texture.id { rl.UnloadFont(font) }
    key_font := load_font(snapshot, bold=true)
    defer if key_font.texture.id != rl.GetFontDefault().texture.id { rl.UnloadFont(key_font) }
    startup_mark("fonts")
    grid = view_grid_layout(font, groups[:], snapshot, -1, 0, available_width, available_height)
    cols, capacity = grid.cols, grid.capacity
    width, height = c.int(grid.width), c.int(grid.height)
    size_picker(width, height, ui_scale)
    icons := make(map[string]rl.Texture2D)
    for group in groups { icons[group.app] = load_icon(group.icon, group.app) }
    defer { for _, texture in icons { if texture.id != 0 { rl.UnloadTexture(texture) } }; delete(icons) }
    startup_mark("icons")
    launcher := Launcher{}
    defer delete(launcher.query)
    defer delete(launcher.results)
    defer {
        if !options.demo {
            for app in launcher.apps {
                delete(app.id); delete(app.name); delete(app.description)
                delete(app.keywords); delete(app.executable)
            }
        }
        delete(launcher.apps)
    }
    launcher_active, catalogue_loaded := false, false
    launcher_font := rl.Font{}
    defer if launcher_font.texture.id != 0 && launcher_font.texture.id != rl.GetFontDefault().texture.id { rl.UnloadFont(launcher_font) }
    launcher_mouse := ui_mouse_position(camera)
    picker_mouse := launcher_mouse
    // Submit the complete picker before asking Shell to present it. A separate
    // blank frame here used to add a swap/frame wait to every invocation.
    needs_present := !options.demo || ODIN_OS == .Darwin
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
        // A monitor/desktop scaling change can arrive after presentation. Keep
        // layout, native bounds, and input in the same logical coordinate space.
        next_backing_scale := max(rl.GetWindowScaleDPI().x, rl.GetWindowScaleDPI().y)
        if next_backing_scale != backing_scale {
            backing_scale = next_backing_scale
            ui_scale = picker_scale(options.scale, backing_scale, snapshot.width, snapshot.height)
            available_width = int(f32(snapshot.width-16)/ui_scale)
            available_height = int(f32(snapshot.height-16)/ui_scale)
            camera.zoom = ui_scale
            if launcher_active {
                width = c.int(min(max(int(width), min(700, available_width-16)), available_width-16))
                height = c.int(min(760, available_height-12))
            }
            size_picker(width, height, ui_scale)
            needs_present = !options.demo || ODIN_OS == .Darwin
            gesture = {} // Resizing during a drag must not reorder a different tile.
        }
        // One coordinate sample drives hover, clicks, drag targets, and drawing.
        mouse := ui_mouse_position(camera)
        entering_launcher := !launcher_active && !gesture.active && rl.IsKeyPressed(.SPACE)
        if entering_launcher {
            launcher_active = true
            launcher_mouse = mouse
            gesture = {}
            if !catalogue_loaded {
                if options.demo {
                    launcher.apps = make([]Launcher_App, len(groups))
                    for group, i in groups {
                        launcher.apps[i] = {id=group.app, name=group.name, description="Installed application preview"}
                    }
                    catalogue_loaded = true
                } else {
                    response, ok := bridge("Applications", {token=snapshot.token})
                    catalogue: App_Catalogue
                    if ok && json.unmarshal_string(response, &catalogue) == nil && catalogue.version == 1 {
                        launcher.apps = catalogue.apps
                        catalogue_loaded = true
                        launcher.catalogue_error = ""
                    } else {
                        launcher.catalogue_error = "Cannot list installed applications"
                        launcher.error = launcher.catalogue_error
                    }
                    delete(response)
                }
                if catalogue_loaded {
                    font_windows := make([]Window, len(launcher.apps))
                    for app, i in launcher.apps { font_windows[i] = Window{name=app.name, title=app.description} }
                    launcher_font = load_font(Snapshot{windows=font_windows})
                    delete(font_windows)
                }
            }
            if catalogue_loaded { launcher_refresh(&launcher) }
            width = max(width, c.int(min(700, available_width-16)))
            height = c.int(min(760, available_height-12))
            size_picker(width, height, ui_scale)
            needs_present = !options.demo || ODIN_OS == .Darwin
        }
        if launcher_active {
            back, app_index := launcher_input(&launcher, width, height, entering_launcher, mouse, &launcher_mouse)
            if back {
                launcher_active = false
                picker_mouse = mouse
                needs_present = !options.demo || ODIN_OS == .Darwin
            } else if app_index >= 0 {
                app := launcher.apps[app_index]
                if options.demo { launcher.error = fmt.aprintf("Preview: would start %s", app.name) }
                else {
                    response, ok := bridge("Launch", {token=snapshot.token, id=app.id})
                    reply: Reply
                    if ok && json.unmarshal_string(response, &reply) == nil && reply.ok { done = true; activated = true }
                    else { launcher.error = response if !ok else reply.error }
                    if ok { delete(response) }
                }
            }
            // Reuse picker textures and resolve other apps only when they appear
            // in search results. Cache failed lookups too, avoiding frame retries.
            if launcher_active {
                for result in launcher.results {
                    app := launcher.apps[result.index]
                    if _, loaded := icons[app.id]; !loaded {
                        icons[app.id] = load_icon("", app.id)
                    }
                }
            }
        } else {
            if !armed && !selection_held() { armed = true }
            count := len(groups)
            if child >= 0 { count = len(groups[child].windows) }
            grid = view_grid_layout(font, groups[:], snapshot, child, page, available_width, available_height)
            cols, capacity, page = grid.cols, grid.capacity, grid.page
            tile_height, cell_height := grid.tile_height, grid.cell_height
            pages, visible := grid.pages, grid.visible
            pointer_moved := mouse != picker_mouse
            picker_mouse = mouse
            pressed := rl.IsMouseButtonPressed(.LEFT)
            down := rl.IsMouseButtonDown(.LEFT)
            released := rl.IsMouseButtonReleased(.LEFT)
            // Treat release-frame motion as a drag before resolving the drop target.
            dropping := gesture.active && child < 0 &&
                (gesture.dragging ||
                 (mouse.x-gesture.origin_x)*(mouse.x-gesture.origin_x) +
                 (mouse.y-gesture.origin_y)*(mouse.y-gesture.origin_y) >= 64)
            hovered := pointer_target(mouse.x, mouse.y, cols, capacity, count, page, dropping, gesture.source, tile_height=tile_height, cell_height=cell_height)
            if hovered >= 0 && !gesture.active && !dropping && (pointer_moved || pressed) {
                highlighted = hovered
            }
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
                    if key_edit(.TAB) {
                        reverse := rl.IsKeyDown(.LEFT_SHIFT) || rl.IsKeyDown(.RIGHT_SHIFT)
                        highlighted = cycle_selection(highlighted, count, reverse)
                    }
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
                        response, ok := bridge("Activate", {token=snapshot.token, id=snapshot.windows[index].id})
                        reply: Reply
                        if ok && json.unmarshal_string(response, &reply) == nil && reply.ok { done = true; activated = true }
                        else if !ok { status = response }
                        else { status = reply.error }
                    }
                    armed = false
                }
            }
        } // Picker input is inactive while the launcher owns the keyboard.
        if !launcher_active {
            // A group/page transition changes the content size immediately.
            grid = view_grid_layout(font, groups[:], snapshot, child, page, available_width, available_height)
            cols, capacity, page = grid.cols, grid.capacity, grid.page
            if width != c.int(grid.width) || height != c.int(grid.height) {
                width, height = c.int(grid.width), c.int(grid.height)
                size_picker(width, height, ui_scale)
                needs_present = !options.demo || ODIN_OS == .Darwin
            }
        }
        rl.BeginDrawing()
        rl.ClearBackground({19, 23, 34, 255})
        drawing_camera := camera
        // BeginMode2D replaces raylib's DPI matrix on both platforms. The
        // drawing camera uses framebuffer pixels; the input camera stays logical.
        drawing_camera.zoom *= f32(rl.GetRenderWidth())/f32(rl.GetScreenWidth())
        rl.BeginMode2D(drawing_camera)
        rl.DrawRectangleRounded({0, 0, f32(width), f32(height)}, 0.06, 12, {19, 23, 34, 255})
        mode := "all windows"
        if options.filter.workspace != -1 { mode = "workspace" }
        if options.filter.monitor != -1 { mode = "monitor" }
        if options.filter.workspace != -1 && options.filter.monitor != -1 { mode = "workspace + monitor" }
        if options.filter.app != "" { mode = "application" }
        if launcher_active { mode = "start app" }
        rl.DrawTextEx(key_font, "BIFROST", {28, 22}, 26, 2, {119, 144, 178, 255})
        brand_width := rl.MeasureTextEx(key_font, "BIFROST", 26, 2).x
        mode_x := 28 + brand_width + 12
        text(font, fmt.tprintf("(%s)", mode), mode_x, 27, 20,
            {139, 151, 173, 255}, max(0, f32(width)-mode_x-28))
        subheading := ""
        if child >= 0 && !launcher_active { subheading = fmt.tprintf("%s · Choose a window · Esc to go back", groups[child].name) }
        if options.demo { subheading = fmt.tprintf("%s%sPreview", subheading, " · " if subheading != "" else "") }
        text(font, subheading, 28, 58, 14, {139, 151, 173, 255}, f32(width-56))
        if launcher_active {
            search_font := launcher_font if launcher_font.texture.id != 0 else font
            launcher_draw(launcher, search_font, width, height, icons)
        } else {
            tile_height, cell_height := grid.tile_height, grid.cell_height
            count := len(groups)
            if child >= 0 { count = len(groups[child].windows) }
            visible, pages := grid.visible, grid.pages
            hovered := pointer_target(mouse.x, mouse.y, cols, capacity, count, page,
                gesture.dragging, gesture.source, tile_height=tile_height, cell_height=cell_height)
            for local in 0..<visible {
                index := page*capacity+local
                group := &groups[index] if child < 0 else &groups[child]
                x := f32(GRID_X + (local%cols)*CELL_WIDTH)
                y := f32(GRID_Y + (local/cols)*cell_height)
                tile := rl.Rectangle{x, y, TILE_WIDTH, f32(tile_height)}
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
            footer := "Tab / Shift+Tab · Enter/click to choose · Space to search · Esc to cancel"
            if status != "" { footer = status }
            if gesture.dragging && child < 0 { footer = "Release to save position · Esc to cancel drag" }
            instructions := []string{footer}
            if status == "" && !gesture.dragging {
                if cols == 1 {
                    instructions = []string{"Tab/Shift+Tab: move", "Enter/click: choose", "Space: search", "Esc: cancel"}
                } else if cols == 2 {
                    instructions = []string{"Tab/Shift+Tab · Enter/click", "Space: search · Esc: cancel"}
                }
            }
            footer_y := height-FOOTER_TEXT_BOTTOM-c.int((len(instructions)-1)*FOOTER_LINE_HEIGHT)
            for line, i in instructions {
                text(font, line, 24, f32(footer_y)+f32(i*FOOTER_LINE_HEIGHT), FOOTER_FONT_SIZE, {139, 170, 192, 255}, f32(width-48))
            }
            if pages > 1 { text(font, fmt.tprintf("Page %d/%d · PgUp/PgDn", page+1, pages), 24,
                f32(footer_y-FOOTER_DETAIL_HEIGHT), FOOTER_DETAIL_FONT_SIZE, {139, 151, 173, 255}, f32(width-48)) }
        } // Launcher replaces the icon grid and picker footer.
        rl.EndMode2D()
        if options.frames > 0 && frame+1 == options.frames && options.screenshot != "" {
            take_screenshot(options.screenshot)
        }
        rl.EndDrawing()
        if frame == 0 { startup_mark("first frame") }
        if needs_present {
            response, ok := bridge("Present", {token=snapshot.token, backdrop=options.backdrop})
            if !ok {
                if frame == 0 { fail(response) }
                status = response
            } else { delete(response) }
            needs_present = false
            if frame == 0 { startup_mark("presented") }
        }
        frame += 1
        if options.frames > 0 && frame >= options.frames {
            if startup_profile.enabled {
                fmt.eprintf("bifrost rendering: window %dx%d; framebuffer %dx%d; DPI %.2f; UI zoom %.2f\n",
                    rl.GetScreenWidth(), rl.GetScreenHeight(), rl.GetRenderWidth(), rl.GetRenderHeight(), backing_scale, ui_scale)
            }
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
    launcher_report("pid", os.get_pid())
    defer launcher_report("status", 0)
    started := time.tick_now()
    startup_profile = {enabled=env("BIFROST_TIMING") == "1", start=started, last=started}
    options := parse_options(os.args[1:])
    if options.command == "authorize" {
        when ODIN_OS == .Darwin {
            if bf_request_access() != 0 { fmt.println("Bifrost Accessibility permission is enabled.") }
            else { fmt.eprintln(string(bf_error())) }
            return
        } else { fail("authorize is a macOS command") }
    }
    when ODIN_OS == .Darwin {
        if options.filter.workspace != -1 {
            fail("macOS public APIs do not expose Space membership; use --workspace all")
        }
    }
    defer bf_shutdown()
    if options.command == "hide" && options.demo { return }
    if !options.demo && options.command != "doctor" && options.command != "list" {
        result := bf_instance(cstr(options.command))
        if result < 0 { fail(string(bf_error())) }
        if result == 0 || options.command == "hide" { return }
    }
    startup_mark("instance")
    snapshot: Snapshot
    if options.demo { snapshot = preview_snapshot() }
    else {
        response, ok := bridge("Snapshot", {backdrop=options.backdrop && options.command == "toggle"})
        if !ok {
            when ODIN_OS == .Darwin { fail(response) }
            else { fail(fmt.tprintf("GNOME bridge unavailable. Install/enable bifrost@dlb.local.\n%s", response)) }
        }
        if json.unmarshal_string(response, &snapshot) != nil || snapshot.version != 1 || snapshot.token == "" {
            fail("unsupported or malformed window snapshot")
        }
        if options.command == "doctor" || options.command == "list" {
            if options.command == "list" { fmt.println(response) }
            else {
                when ODIN_OS == .Darwin {
                    fmt.printf("macOS Accessibility connected; %d eligible windows; pointer monitor %d; Space filtering unavailable.\n", len(snapshot.windows), snapshot.monitor)
                } else {
                    fmt.printf("GNOME bridge v%d connected; %d eligible windows; pointer monitor %d; native Wayland required.\n", snapshot.version, len(snapshot.windows), snapshot.monitor)
                }
            }
            dismissed, _ := bridge("Dismiss", {token = snapshot.token}); delete(dismissed)
            return
        }
    }
    startup_mark("snapshot")
    if snapshot.width < 240 || snapshot.height < 320 { fail("monitor work area is too small for the picker") }
    path := state_path()
    order := Order{version = 1} if options.demo else load_order(path)
    if observe(&order, snapshot.windows) && !options.demo && !save_order(order, path) {
        fail(fmt.tprintf("could not save application order: %s", string(bf_error())))
    }
    startup_mark("saved order")
    run_picker(options, snapshot, &order, path)
}
