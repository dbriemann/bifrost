package main

import "core:fmt"
import "core:os"
import "core:testing"
import rl "../build/rl"

// Exercise the exact CPU image-loading path used before texture upload. No
// compositor, GTK display, decoder service, or OpenGL context is needed.
@(test)
application_png_and_svg_images_keep_their_pixels :: proc(t: ^testing.T) {
    directory, err := os.get_working_directory(context.allocator)
    testing.expect(t, err == nil)
    defer delete(directory)
    defer free_all(context.temp_allocator)
    png := load_icon_image(fmt.tprintf("%s/tests/fixtures/app.png", directory), "fixture.desktop")
    testing.expect(t, png.data != nil)
    if png.data == nil { return }
    defer rl.UnloadImage(png)
    testing.expect_value(t, png.width, 2)
    testing.expect_value(t, png.height, 1)
    testing.expect_value(t, rl.GetImageColor(png, 0, 0), rl.Color{233,84,32,255})
    testing.expect_value(t, rl.GetImageColor(png, 1, 0), rl.Color{53,132,228,128})

    when ODIN_OS == .Linux {
        svg := load_icon_image(fmt.tprintf("%s/tests/fixtures/app.svg", directory), "fixture.desktop")
        testing.expect(t, svg.data != nil)
        if svg.data == nil { return }
        defer rl.UnloadImage(svg)
        testing.expect_value(t, svg.width, 256)
        testing.expect_value(t, svg.height, 256)
        testing.expect_value(t, rl.GetImageColor(svg, 64, 64), rl.Color{233,84,32,255})
    }
    when ODIN_OS == .Darwin {
        // Compare every pixel with the previous PNG route, covering orientation,
        // channel order and alpha conversion for a full-size AppKit icon.
        bundle := fmt.tprintf("%s/build/Bifrost.app", directory)
        filename := bf_icon(cstr(bundle))
        testing.expect(t, filename != nil)
        if filename == nil { return }
        defer bf_free(rawptr(filename))
        previous := decode_icon_image(string(filename))
        direct := load_icon_image(bundle, "org.bifrost.picker")
        testing.expect(t, previous.data != nil && direct.data != nil)
        defer if previous.data != nil { rl.UnloadImage(previous) }
        defer if direct.data != nil { rl.UnloadImage(direct) }
        if previous.data != nil && direct.data != nil {
            testing.expect_value(t, direct.width, previous.width)
            testing.expect_value(t, direct.height, previous.height)
            expected := rl.LoadImageColors(previous)
            actual := rl.LoadImageColors(direct)
            defer rl.UnloadImageColors(expected)
            defer rl.UnloadImageColors(actual)
            for i in 0..<int(direct.width*direct.height) {
                a, b := actual[i], expected[i]
                matches := a.a == b.a && (a.a == 0 ||
                    abs(int(a.r)-int(b.r)) <= 1 && abs(int(a.g)-int(b.g)) <= 1 && abs(int(a.b)-int(b.b)) <= 1)
                if !matches {
                    testing.expect(t, false, fmt.tprintf("Icon pixel %d differs: direct %v; PNG %v", i, a, b))
                    break
                }
            }
        }
    }

    missing := load_icon_image("bifrost-nonexistent-icon-regression", "bifrost-nonexistent.desktop")
    testing.expect(t, missing.data == nil)
    if missing.data != nil { rl.UnloadImage(missing) }

    for path in ([2]string{
        "/usr/share/icons/hicolor/256x256/apps/firefox.png",
        "/usr/share/icons/hicolor/scalable/apps/org.gnome.Nautilus.svg",
    }) {
        if !os.exists(path) { continue }
        image := decode_icon_image(path)
        testing.expect(t, image.data != nil, path)
        if image.data == nil { continue }
        testing.expect(t, image.width > 0 && image.height > 0)
        fmt.printf("Decoded installed application icon: %s (%dx%d)\n", path, image.width, image.height)
        rl.UnloadImage(image)
    }
}

