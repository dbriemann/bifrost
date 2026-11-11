# Bifrost

A keyboard-driven application/window picker for **GNOME 50 on Wayland**, written
in **Odin**, drawn with **raylib**. A small GNOME Shell extension supplies window
metadata, activation, and picker placement. Other compositors and macOS are
planned; this first version implements the GNOME path.

Bifrost groups running windows by application. Groups with several windows show
stacked icons and a count. Select a group to choose one of its windows; a group
with one window switches directly. Application order persists, closed apps are
hidden, and newly discovered apps append. The visible grid compacts, so keys may
change when the running app set changes. Focus changes never reorder it.

## Build

Requirements for the initial **Linux x86-64** build:

- Odin with matching **raylib 6.2** vendor bindings and Linux static library
  (developed with `dev-2026-11:2347ac067`).
- C compiler, binutils, pkg-config, Python 3 (`/usr/bin/python3`), make.
- GLFW **3.4** with Wayland support, GLib/GIO development files, OpenGL and X11
  link libraries. X11 is a link dependency of the supplied raylib archive;
  Bifrost explicitly selects and verifies Wayland at runtime.
- GNOME's GTK4, GdkPixbuf, librsvg, Cairo, and icon themes at runtime. GTK is used
  only to resolve icon files; all UI rendering is raylib. Missing/undecodable icons
  fall back to an application tile.
- Node.js to run the bridge logic tests.

Typical Fedora development packages (Odin is installed separately):

```sh
sudo dnf install gcc binutils pkgconf-pkg-config python3 make glfw \
  glib2-devel libglvnd-devel libX11-devel gtk4 gdk-pixbuf2 librsvg2 nodejs
make
make test
```

The build copies Odin's matching raylib archive into `build/`, removes its bundled
X11-only GLFW object, and links the system GLFW instead. It generates a local
copy of the matching Odin binding with the replacement link paths. It never
changes the Odin installation. `GLFW_LIBRARY`, `RAYLIB_DIR`, and `ODIN_BIN` may
be set to override discovery. A small linker wrapper preserves our Wayland app
ID when raylib resets window hints. The binary remains linked to `libglfw.so.3`.

## Install and run

```sh
make install
# On first installation, log out and back in if GNOME has not discovered it.
gnome-extensions enable bifrost@dlb.local
~/.local/bin/bifrost doctor
~/.local/bin/bifrost toggle
```

Installation copies the binary and extension into your user directories. It does
not enable the extension or change keyboard shortcuts automatically. After editing
an already loaded extension on Wayland, log out/in to reload its JavaScript.
`make package` also creates an extension ZIP in `dist/`.

In **Settings → Keyboard → View and Customize Shortcuts → Custom Shortcuts**, add
an unused shortcut whose command is the **absolute path** to `bifrost toggle`.
For example, `/home/YOUR_USER/.local/bin/bifrost toggle`. Do not use a literal `~`
in the shortcut command. Bind additional shortcuts to filtered invocations if
wanted:

```sh
bifrost toggle --workspace current
bifrost toggle --monitor current
bifrost toggle --workspace current --monitor current
bifrost toggle --app org.mozilla.firefox.desktop
```

`current` workspace/monitor is captured before the picker takes focus. Monitor
means the pointer's monitor, with active-monitor fallback. Explicit workspace and
monitor indexes are zero-based. Filters intersect. Default scope is all eligible
windows across workspaces and monitors, including minimized and XWayland-hosted
windows. `bifrost list` prints desktop IDs/window metadata for configuring filters
(and includes window titles). `bifrost doctor` only reports connection status and
counts.

## Controls

- **1–9, 0, a–z:** choose the labeled application/window. Letter choices follow
  the current keyboard layout; number-row and keypad digits also work.
- **Arrows / Enter:** navigate and select. **PageUp/PageDown:** overflow pages.
- **Esc:** return from windows to applications; at the root, dismiss. During a
  drag, cancel the drag. Cancelling restores prior focus if the picker still owns it.
- **Click:** select. **Drag an application tile onto another:** change saved order.
- A second invocation or `bifrost hide` closes the visible picker. In this version,
  a second invocation with different filters also closes it; invoke again to open
  the new selection.

The picker appears on the pointer monitor and stays there while visible. Its
application/window mappings are snapshots: newly opened windows appear next
invocation, and closed targets fail selection instead of reassigning their key.
A vanished target may remain drawn until reopening the picker.

Order is saved atomically in `$XDG_STATE_HOME/bifrost/order.json`, defaulting to
`~/.local/state/bifrost/order.json`. Absent apps retain ordering metadata only.
Delete that file to reset the order. Reordering a filtered subset preserves the
positions of excluded apps in the saved ordering. `BIFROST_FONT` can point to a
TTF font with the glyphs you need; the default attempts Noto Sans and DejaVu Sans.
The raylib UI does not yet expose a screen-reader accessibility tree.

## Preview without the extension

These commands still need an accessible Wayland display, but do not need the
GNOME bridge and never write your saved application order:

```sh
./build/bifrost --demo
./build/bifrost --demo --frames 30 --screenshot /tmp/bifrost-preview.png
```

Demo selection displays the selected title instead of activating a real window.

## Verification and current limits

Implemented checks: six Odin model tests for grouping, persistence round-trip,
compaction, filters, ordering, and key alphabet; eight mocked-compositor tests of
the actual extension class; native icon lookup/SVG-to-RGBA and atomic state-write
checks; compilation and command-line validation.

**Live GNOME focus, window placement, fullscreen behavior, and rendering have not
been validated in the development sandbox**, which blocks session D-Bus/Wayland
sockets, including sockets for a nested test compositor. The first desktop run
should exercise:

1. `bifrost doctor`, then opening via an actual custom shortcut.
2. Single-window selection, a multi-window group, and Esc from each level.
3. Switching to minimized windows and windows on another workspace.
4. Pointer-monitor placement on multiple displays and fullscreen applications.
5. Drag reorder, close/reopen an app, then restart Bifrost and check saved order.
6. Filtered shortcuts, a target closed while visible, and extension disable/lock.

The executable currently runs only while the picker is open; there is no resident
service or autostart setup. Each invocation reconnects and loads icons. GNOME 50
is the only declared extension target. Unicode glyph coverage depends on the
chosen font. No native macOS or other compositor backend is implemented yet.

If the bridge is unavailable, inspect `gnome-extensions info bifrost@dlb.local`
and Shell logs (`journalctl --user -b`, search for Bifrost). In-session extension
errors may also appear in GNOME Looking Glass (`Alt+F2`, `lg`). For build or
prototype issues, see [PLAN.md](PLAN.md).

To remove, disable the extension, delete
`~/.local/share/gnome-shell/extensions/bifrost@dlb.local`, and remove
`~/.local/bin/bifrost`. Saved ordering can be removed separately.
