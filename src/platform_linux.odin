package main

import "core:c"

foreign import platform "../build/libplatform.a"
foreign platform {
    bf_call :: proc(method, input: cstring) -> cstring ---
    bf_free :: proc(value: rawptr) ---
    bf_error :: proc() -> cstring ---
    bf_instance :: proc(request: cstring) -> c.int ---
    bf_poll :: proc() -> cstring ---
    bf_wayland_prepare :: proc() -> c.int ---
    bf_wayland_active :: proc() -> c.int ---
    bf_icon :: proc(description: cstring) -> cstring ---
    bf_app_icon :: proc(description, app_id: cstring) -> cstring ---
    bf_pixels :: proc(path: cstring, width, height: ^c.int) -> rawptr ---
    bf_save :: proc(path, text: cstring) -> c.int ---
    bf_shutdown :: proc() ---
}
