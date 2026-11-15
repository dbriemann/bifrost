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

    svg := load_icon_image(fmt.tprintf("%s/tests/fixtures/app.svg", directory), "fixture.desktop")
    testing.expect(t, svg.data != nil)
    if svg.data == nil { return }
    defer rl.UnloadImage(svg)
    testing.expect_value(t, svg.width, 256)
    testing.expect_value(t, svg.height, 256)
    testing.expect_value(t, rl.GetImageColor(svg, 64, 64), rl.Color{233,84,32,255})

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

