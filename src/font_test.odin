package main

import "core:c"
import "core:os"
import "core:testing"
import rl "../build/rl"

// Load CPU glyph data using raylib's actual font parser. This detects missing
// glyph requests before any display or OpenGL texture is needed.
@(test)
ui_fonts_do_not_request_missing_unused_glyphs :: proc(t: ^testing.T) {
    windows := []Window{{name="Firefox", title="Mail — Inbox"}}
    snapshot := Snapshot{windows=windows}
    regular := font_codepoints(snapshot)
    defer delete(regular)
    bold := font_codepoints(snapshot, bold=true)
    defer delete(bold)
    paths := [2]string{
        "/usr/share/fonts/google-noto-vf/NotoSans[wght].ttf",
        "/usr/share/fonts/open-sans/OpenSans-Bold.ttf",
    }
    when ODIN_OS == .Darwin {
        paths = {"/System/Library/Fonts/Supplemental/Arial.ttf", "/System/Library/Fonts/Supplemental/Arial Bold.ttf"}
    }
    for path, i in paths {
        if !os.exists(path) { continue }
        bytes, err := os.read_entire_file(path, context.allocator)
        testing.expect(t, err == nil)
        if err != nil { continue }
        requested := regular[:] if i == 0 else bold[:]
        found: c.int
        glyphs := rl.LoadFontData(raw_data(bytes), c.int(len(bytes)), 32,
            raw_data(requested), c.int(len(requested)), .DEFAULT, &found)
        testing.expect(t, glyphs != nil)
        testing.expect_value(t, int(found), len(requested))
        if glyphs != nil { rl.UnloadFontData(glyphs, found) }
        delete(bytes)
    }
}
