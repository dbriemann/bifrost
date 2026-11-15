# Bifrost

A keyboard-driven application/window picker for **GNOME 50 on Wayland**, written
in **Odin**, drawn with **raylib**. A small GNOME Shell extension supplies window
metadata, activation, and picker placement. Other compositors and macOS are
planned; this version implements the GNOME path, including an installed-app launcher.

The picker uses a larger layout with 120-pixel icons, enlarged fonts and key
badges, and centered application names/window titles below each icon. Names
use 45-pixel text with up to two lines, and selection keys use bold 51-pixel text.
The heading shows `BIFROST (all windows)` or the active filter mode. Tile and row
heights follow the text: single-line names leave only a small bottom padding,
while longer names reserve a second line when needed. The grid chooses nearly
equal row and column counts: seven apps use three columns and three rows when
the work area allows it. Each application/window view fits its own content,
including a shorter final overflow page, with a small footer below the last row.
Window size constraints update with the content so switching views does not
leave an oversized panel. Monitor limits can produce a wider/narrower grid or
overflow pages; very small work areas reduce the overall scale to stay usable.

By default, GNOME dims and blurs the desktop around the picker across all
monitors, including the top bar, while leaving the picker sharp. Use
`bifrost --no-backdrop` to disable both effects for an invocation;
`--backdrop` explicitly enables them. The backdrop follows picker size/position
changes and is removed on selection, dismissal, native window loss, lock, or
extension disable. It does not take keyboard/mouse focus. Each monitor's desktop
image is captured into memory before the picker is created, then blurred and
dimmed as frozen content. Background animations therefore pause visually while
the picker is open; the picker itself remains live and interactive. Images are
discarded with the picker session and are never saved to disk. `--no-backdrop`,
`doctor`, and `list` skip image preparation.
Each monitor uses one stable blur surface, with a sharp, non-reactive copy of the
native picker drawn above it. This avoids both blur seams around a resizing
cutout and live-framebuffer artifacts from partial screen repaints.
Bifrost's own window animations are suppressed so it opens at full size without
exposing the desktop beneath it; other applications keep their animation policy.
The bridge waits for drawable picker content before presenting the backdrop.
This implementation requires extension version 6; after installing its update, log out/in
to reload the Shell extension. The extension-free `--demo` preview draws only the
picker.

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
  only to resolve icon files in a separate `bifrost-icon-resolver` process, so it
  cannot conflict with the GTK version used by GLFW/libdecor. All UI rendering
  is raylib. The picker uses the
  application's icon supplied by GNOME, with desktop-entry and Flatpak-export
  fallbacks. Unmatched window IDs can use a unique declared `StartupWMClass` or
  a trailing `-desktop` packaging alias (for example, `mtgatool-desktop` uses
  `mtgatool.desktop`). Matching affects icon lookup only; saved app identities
  and ordering stay intact. Exact descriptors/entries take precedence, and
  ambiguous metadata matches are rejected. PNG and other common raster formats decode directly in raylib;
  SVG icons rasterize in-process through librsvg. Missing icons are reported on
  stderr and fall back to an application tile.
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
be set to override discovery. Small linker wrappers preserve our Wayland app
ID when raylib resets window hints and bypass unsupported client-side window
position calls on Wayland. The GNOME bridge handles actual placement. The binary remains linked to `libglfw.so.3`.
The borderless picker disables GLFW's libdecor initialization to avoid loading
unused client-side title bars and their GTK plugin during startup.
Builds use Odin's speed optimization by default; `BIFROST_DEBUG=1 make` produces
an unoptimized build with debug information.

## Install and run

```sh
make install
# On first installation, log out and back in if GNOME has not discovered it.
gnome-extensions enable bifrost@dlb.local
~/.local/bin/bifrost doctor
~/.local/bin/bifrost toggle
```

Installation copies the picker, its icon resolver helper, and the extension
into your user directories. Keep `bifrost-icon-resolver` beside the `bifrost`
executable if copying the application manually. It does
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
- **Tab / Shift+Tab:** highlight the next/previous application or window, wrapping
  at the ends and changing overflow pages as needed. **Arrows** also navigate;
  **Enter** selects the highlighted item. **PageUp/PageDown:** overflow pages.
- **Space:** replace the icons with installed-app search. Type to fuzzy-match
  names, executable names, keywords, and descriptions. **Up/Down** or
  **Tab/Shift+Tab** selects among the best ten results; **Enter** or a mouse click
  starts the selected app and closes Bifrost.
  Each result shows a small application icon matching the name's text size.
  **Esc** restores the previous picker view. Letters/digits edit the search while
  this mode is open, and spaces are ordinary input after entering the launcher.
  **Left/Right, Home/End, Backspace/Delete** edit the query; **Ctrl+V** pastes and
  **Ctrl+U** clears it. Mouse selection and scrolling also work.
- **Esc:** return from windows to applications; at the root, dismiss. During a
  drag, cancel the drag. Cancelling restores prior focus if the picker still owns it.
- **Click:** select. **Drag an application tile onto another or into a gap:**
  change saved order. A floating icon follows the pointer and an insertion marker
  shows the drop position. Normal hover highlighting pauses while dragging.
  A stationary mouse leaves keyboard highlighting unchanged.
  Pointer coordinates are converted through the drawing camera each frame so
  resize/DPI callbacks cannot shift hover, click, or drag targets.
- A second invocation or `bifrost hide` closes the visible picker. In this version,
  a second invocation with different filters also closes it; invoke again to open
  the new selection.

The launcher searches visible installed desktop applications, including Flatpak
exports, regardless of the current window filters. Empty queries show up to ten
apps alphabetically. Search updates after each edit; case-insensitive subsequence
matching favors names, prefixes, word starts, and consecutive letters. Ties use
application name and desktop ID for stable ordering. On smaller monitors only
part of the top-ten list may fit; navigation scrolls the selected result into view.
Launching goes through GNOME Shell on the workspace captured when Bifrost opened;
desktop-file and application behavior determine whether an existing app creates
a new window. Unavailable apps or rejected launches leave the search open with an
error. Search text is never executed as a shell command.

**Updating from the picker-only extension:** run `make install`, then **log out
and back in** to load version 2 of the Shell bridge. Restarting the Bifrost binary
alone does not load the new application-listing and launch methods into Shell.

The picker appears on the pointer monitor and stays there while visible. Its
application/window mappings are snapshots: newly opened windows appear next
invocation, and closed targets fail selection instead of reassigning their key.
A vanished target may remain drawn until reopening the picker.

Order is saved atomically in `$XDG_STATE_HOME/bifrost/order.json`, defaulting to
`~/.local/state/bifrost/order.json`. Absent apps retain ordering metadata only.
Delete that file to reset the order. Reordering a filtered subset preserves the
positions of excluded apps in the saved ordering. `BIFROST_FONT` can point to a
TTF font with the glyphs you need; the default attempts Noto Sans and DejaVu Sans.
`BIFROST_BOLD_FONT` can override the bold font used for selection keys and counts.
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

Implemented checks: twenty-eight Odin search/model/font/image/interaction tests for drag gestures, drop
targets, cancellation, grouping, persistence round-trip,
compaction, filters, ordering, and key alphabet; twenty-nine mocked-compositor tests of
the actual extension class; native icon lookup/SVG-to-RGBA and atomic state-write
checks, isolated icon lookup with GTK3 preloaded, desktop-entry icon fallbacks,
window-class/packaging-alias lookup with exact-entry priority and ambiguity checks,
missing-icon rejection, PNG/SVG pixel
checks, font glyph coverage, balanced/content-sized layouts and paged hit targets,
Wayland position-call routing and content-size constraints; compilation and
command-line validation.
Backdrop checks cover stable full-monitor surfaces, sharp picker ordering, resizing,
default/disabled behavior, actor reuse, and cleanup after selection, cancellation,
native window loss, lock, extension disable, session eviction, and setup errors.
Presentation checks cover waiting for drawable content, normalizing active picker
effects, and preserving/restoring animation behavior for other applications.
Frozen-image checks cover preparation before native window creation, reuse without
recapture on picker updates, excluding old/current picker actors from captures,
monitor refresh, failure recovery, and a client exiting before its window maps.

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
7. Tab/Shift+Tab/Enter in both picker levels and search, including wraparound and
   overflow pages with the mouse stationary over another target. Space to search,
   rapid query edits, click a result to start it, and Esc back to the same grid.
8. Launch an installed app that is not running, a terminal app, and a Flatpak app;
   check that a failed launch leaves the query intact.
9. Default desktop dimming/blur across monitors, the sharp picker after
   view/page changes, outside clicks and Esc, and `bifrost --no-backdrop`. Also
   check startup without growth/white flashes, background without seams, and
   cleanup if the native picker exits unexpectedly or the session locks.

The executable currently runs only while the picker is open; there is no resident
service or autostart setup. Each invocation reconnects and loads icons. GNOME 50
is the only declared extension target. Unicode glyph coverage depends on the
chosen font. No native macOS or other compositor backend is implemented yet.

Startup submits the complete picker before requesting GNOME presentation, without
an extra blank frame. The bridge presents an already mapped window immediately;
the 25 ms retry timer runs only while waiting for the window to map. To measure
startup on your desktop, close the picker and run `BIFROST_TIMING=1 bifrost`.
Stderr reports elapsed and per-stage times for the instance check, snapshot,
saved order, Wayland connection, OpenGL window, fonts, icons, first submitted
frame, and GNOME presentation request. Timing starts at `main`; it excludes
shortcut dispatch, process loading, and compositor scanout, so it is not a full
key-to-visible measurement.

If the bridge is unavailable, inspect `gnome-extensions info bifrost@dlb.local`
and Shell logs (`journalctl --user -b`, search for Bifrost). In-session extension
errors may also appear in GNOME Looking Glass (`Alt+F2`, `lg`). For build or
prototype issues, see [PLAN.md](PLAN.md).

To remove, disable the extension, delete
`~/.local/share/gnome-shell/extensions/bifrost@dlb.local`, and remove
`~/.local/bin/bifrost` and `~/.local/bin/bifrost-icon-resolver`. Saved ordering
can be removed separately.
