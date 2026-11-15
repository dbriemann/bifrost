# Bifrost: application and window picker

Status: Linux/GNOME first, Odin/raylib UI, and a JavaScript GNOME Shell bridge
selected. A first GNOME prototype is implemented (2026-11-11); live desktop
validation is still outstanding.

## First implementation status

Implemented in `src/`, `native/`, and `extension/`:

- Odin/raylib picker with application stacks/counts, second-stage window choices,
  digit/letter keys, arrow navigation, and overflow pages.
- Running-only groups, persistent relative application order, compact views,
  drag-and-drop reorder, and workspace/monitor/application invocation filters.
- GNOME 50 JavaScript bridge over session D-Bus: generation-aware snapshots,
  exact-window activation, pointer-monitor centering, and cancellation assistance.
- Native Wayland selection using raylib 6.2 modules linked to system GLFW 3.4;
  standalone icon-theme lookup, in-process SVG rasterization, and atomic state
  saves. See `README.md` for build/runtime requirements.
- Build, test, install, and extension packaging scripts. Installation was checked
  with temporary destinations; the live user desktop was not modified.

Verified: build and Odin vet checks, six model tests, eight mocked-compositor
bridge tests, real themed SVG decoding to RGBA, atomic state-write checks, CLI
validation, temporary installation, and extension ZIP contents.

This sandbox blocks session D-Bus and Wayland sockets (including binding sockets
for a nested session). Therefore actual rendering, focus, fullscreen stacking,
shortcut invocation, and multi-monitor placement are not yet desktop-validated.
The manual validation sequence is in `README.md`.

Prototype scope differs from the longer-term architecture below: the executable
runs only while visible; a second invocation closes it. It does not yet stay
resident, publish live window deltas, or replace the visible picker on a request
with different filters. Window membership is frozen until reopening. macOS and
other compositor backends remain planned follow-up work.

## Purpose

Open a keyboard-driven picker showing large application icons and numbered
targets. Choose a number to focus a window. Keep positions predictable so that
repeated use builds spatial and keyboard muscle memory.

The application is written in Odin with a shared raylib UI. Target Linux Wayland
first, with a planned macOS adapter. A separate Xorg backend is out of scope.
Platform independence is a design goal, subject to the window-management
capabilities each platform exposes.

## Added application starter

Space opens a text-only launcher in place of the icon grid. Installed desktop
applications are searched incrementally with fuzzy matching, returning at most
ten results. Arrow keys select; Enter requests a launch through the GNOME bridge;
Esc restores the picker. The launcher is independent of window filters and never
executes query text as a command. This extends the initial window-switcher scope.

The catalogue and launch methods require version 2 of the Shell extension. The
Odin search/editing model and bridge paths are automated-tested; live launcher
rendering, keyboard routing, and application startup still need desktop validation.

## Confirmed requirements

- Display one target per application as a large icon with a visible selection key.
- Indicate multiple windows using overlapping copies of the application icon.
- Selecting a multi-window application opens a second set of choices, one per
  window. Selecting a single-window application focuses that window directly.
- Keep the layout stable rather than sorting by recent focus changes.
- Persist application order across application and picker restarts and logins;
  append unknown applications at the end. Support drag-and-drop reordering.
- Use digits first, then letters for single-key selection.
- Include all workspaces and monitors by default; allow filtered invocation.
- Select a target using the keyboard and switch focus to its window.
- Invoke the picker through a shortcut configured in the desktop environment.
- Use Odin and raylib for the application and picker UI.
- Show only groups with eligible running windows; compact them in saved order.
- Show the picker on the pointer monitor, with active then primary fallback.

“All running applications” means eligible windows belonging to the current
graphical user session, not background processes or other users' sessions.
Background applications with no eligible window are not shown.

## Remaining decisions

| Question | Proposed starting point | Status |
| --- | --- | --- |
| Initial desktop support | Linux/GNOME Wayland first; Fedora 44 / GNOME 50.6 is the initial test environment | Selected |
| Small JavaScript GNOME bridge allowed? | Yes; add the bridge required for GNOME window access, with application logic and UI in Odin | Selected |
| macOS support | Native adapter after the first Linux backend; user has a Mac available later for building/testing | Planned |
| Inactive/filtered applications | Hide and compact; persist relative application order | Selected |
| Exact key alphabet | `1234567890abcdefghijklmnopqrstuvwxyz` (36 choices per level) | Proposed |
| Beyond 36 choices at either level | Explicit overflow pages; no time-based multi-key ambiguity | Proposed |
| Window order inside a group | Stable creation order during the session; no title/MRU sorting | Proposed |
| Picker location | Pointer monitor at invocation; active then primary fallback | Selected |
| XWayland windows in a Wayland session | Include if the backend exposes them; no dedicated Xorg support | Pending |

Persist relative application order, not permanent selection keys. Only groups
with matching running windows appear, compacted from the first cell. Positions
and keys may change as applications open/close or filters change; focus changes
never reorder the list. Reopened applications regain their saved relative rank.

## Local development baseline

Observed on 2026-11-10:

- Fedora Linux 44 Workstation, GNOME Shell 50.6, Wayland session.
- Odin compiler available: `dev-2026-11:2347ac067`.
- Project directory has no existing application source.
- GTK4 and Wayland client development metadata are not currently discoverable
  through `pkg-config`. Determine dependencies during the feasibility prototype;
  do not assume missing development metadata means runtime libraries are absent.

Use GNOME 50 as the initial test target. Claim support for other Shell versions
only after testing them.

## Wayland feasibility and portability

There is no assumption of a universal window-control API across desktops.

- `ext-foreign-toplevel-list-v1` supplies window identities and metadata, but
  does not provide activation. Enumeration alone cannot implement this picker.
- `wlr-foreign-toplevel-management-unstable-v1` supplies window enumeration and
  activation requests where the compositor exposes it. Activation remains a
  request governed by compositor policy.
- Combined with `wlr-layer-shell-unstable-v1` for an overlay and keyboard input,
  this can implement the picker through Wayland protocols, without a Shell
  extension, on compositors exposing both. These are optional extensions, not
  universally available Wayland functionality. The client can be written in Odin
  using Wayland C bindings and generated protocol glue as needed.
- GNOME/Mutter 50.6 does not expose that combination: its protocol initialization
  does not include the foreign-toplevel-management or layer-shell interfaces.
  Verify registry capabilities at runtime rather than relying only on DE names.
- GNOME integration should use a small Shell extension to enumerate and activate
  `Meta.Window` objects. The extension entry point is JavaScript; a strictly
  Odin-only implementation would need a different supported target or a revised
  integration approach.
- `xdg-activation-v1` supports focus handoff using tokens; it is not an API for
  finding and activating arbitrary foreign windows.
- Presentation, placement, and acquiring keyboard focus also depend on the
  compositor. An ordinary Wayland application cannot assume it may position
  itself or become an unrestricted desktop overlay.

Implement the GNOME adapter first. Keep the backend boundary ready for a later
Wayland protocol adapter and macOS adapter, without implementing those before
the GNOME MVP is usable. Do not promise universal support from one compositor
test.

## Proposed architecture

### Odin application

Own the window model, slot assignment, selection state, configuration, icon
resolution, and picker UI. Run one process per graphical session and keep it
resident for fast invocation and continuity of window identities.

Expose commands such as `bifrost toggle`, `bifrost hide`, and `bifrost doctor`.
The desktop shortcut runs `bifrost toggle`. Use local single-instance IPC to
forward commands to the resident instance; start it when absent. Explicitly test
cold invocation as well as resident invocation because activation context may
differ.

### Raylib presentation

Use raylib from Odin for textures, text, badges, hover/highlight states, short
transitions, hit testing, and internal drag and drop. The compositor adapter owns
window discovery, activation, and presentation assistance; raylib owns drawing.
No GTK widgets are planned for the picker.

Proposed visual design:

- A centered, borderless panel on the pointer monitor, with generous spacing and
  configurable colors. Transparency is optional; blur is not an MVP dependency.
- Large icons (starting point: 96 logical pixels), application names below, and
  prominent digit/letter badges. Use a fixed cell size and column count per
  display profile. Keep the panel anchor stable when the entry count changes.
- Multi-window groups show up to three offset icon copies and an exact count
  badge. Choosing a group replaces the grid with individual windows, using the
  same anchor and a small application/back heading.
- Window choices show icons and distinguishable titles; reveal full titles on
  highlight if needed. No screenshots or live previews are required.
- Dragging an application previews its insertion point; drop saves, Esc cancels.
  This is internal pointer interaction, not desktop file drag and drop.

Conceptual layout (labels stand in for actual icon textures):

```text
Applications
  [1: Browser + stack (3)]  [2: Editor]  [3: Terminal + stack (2)]

Press 1 → Browser
  [1: Documentation]       [2: Mail]    [3: Project issue]
```

Implementation considerations:

- Odin already supplies `vendor:raylib` bindings. Pin a compatible raylib build
  and verify native Wayland execution. The local bindings also link X11; this
  alone does not establish which window backend the binary actually uses.
- Stock raylib window creation does not automatically provide layer-shell.
  A Wayland surface with an xdg role cannot simply be assigned a second role
  through its native handle. Prototype a suitable raylib platform integration
  or a native Wayland/EGL host using raylib rendering components for this path.
- On GNOME, prototype a normal native Wayland raylib window, with the bridge
  assisting placement, stacking, and focus. Test pointer-monitor placement and
  presentation over fullscreen windows before building the rest of the UI.
- Resolve desktop-entry/theme icons separately, rasterize SVG icons as necessary,
  cache images, and upload textures on the render thread. Raylib does not supply
  desktop application discovery or complete icon-theme resolution.
- Implement Unicode glyph fallback, scaling, keyboard navigation, and drag hit
  testing explicitly. A custom raylib UI does not inherit a toolkit accessibility
  tree; document that limitation and investigate accessibility separately.
- Coordinate raylib input/render handling with backend and IPC events. Avoid
  busy rendering while hidden; bound animation frames and redraw on changes.

### Wayland protocol backend (after GNOME MVP)

Discover globals and bind compatible versions at runtime. Use wlr foreign
toplevel management for window metadata/lifecycle and activation, and layer-shell
for picker placement and keyboard interaction. Release overlay keyboard focus
as part of the tested activation handoff. Keep protocol callbacks on the chosen
event loop and handle global removal and compositor disconnects.

Workspace filtering may need extra protocols or compositor IPC: foreign toplevel
management alone does not supply workspace membership. Missing capabilities must
produce an explicit unsupported-filter error, never silently broaden the scope.

Keep raylib as the drawing layer. Prove how the chosen host owns the layer-shell
surface, EGL context, and event/input loop; raylib and a native host must not both
independently own these resources. Global pointer coordinates are not generally
available to ordinary Wayland clients; use compositor output selection/IPC and
report any fallback to active or primary output.

### GNOME bridge (initial backend)

Use a minimal JavaScript Shell extension with a versioned session D-Bus API:

- Enumerate eligible windows, assign opaque session-local handles, and report
  application identity, title, workspace, monitor, and relevant state.
- Publish window additions, changes, and removals; provide a complete snapshot
  for initialization and reconnection.
- Activate a selected handle, including workspace changes and unminimizing when
  required, through Shell/Mutter APIs.
- Provide the picker presentation/focus integration that the feasibility
  prototype demonstrates is necessary.
- Release signals and exported objects when disabled. Report bridge loss to the
  application and invalidate handles when the bridge generation changes.

Keep slot rules and selection policy out of the extension. Limit its methods to
the operations the picker actually needs; do not expose arbitrary code execution.

The initial prototype must settle whether the Odin raylib window can satisfy focus,
stacking, and monitor placement reliably with this bridge. If it cannot, discuss
the tradeoff before adopting a Shell-rendered picker: that would move some UI
implementation into JavaScript and change the Odin boundary.

### macOS adapter (planned)

Reuse the Odin application model and raylib renderer. Implement a native adapter
inside the application; no GNOME-style Shell extension or D-Bus service is
required for macOS window access.

Proposed API mapping:

| Responsibility | macOS integration |
| --- | --- |
| Running applications, bundle identities, icons | AppKit `NSWorkspace` / `NSRunningApplication` |
| Eligible windows and titles | Accessibility `AXUIElement` and `kAXWindowsAttribute` |
| Individual window selection | App activation plus supported Accessibility raise/focus actions; unminimize where appropriate |
| Window changes | `AXObserver` notifications and workspace lifecycle notifications, with bounded reconciliation where necessary |
| Pointer-monitor placement | AppKit pointer/screen coordinates and native window placement |
| Picker presentation | raylib macOS window with AppKit assistance for window level and collection behavior |

Important implementation constraints:

- Accessibility control requires explicit user authorization. Detect trust with
  the Accessibility trust APIs and provide setup instructions when absent;
  never silently reduce individual-window selection to application activation.
- Use public APIs. Do not depend on private WindowServer/Spaces APIs to claim
  exact parity with Linux workspace controls.
- Include only apps with eligible windows: a macOS app remaining open after its
  last window closes must not produce a tile. Minimized windows remain eligible.
- Preserve app order using bundle identifiers, namespaced by platform. Window
  accessibility references are session-local; neither PID nor title is identity.
- Some applications expose incomplete Accessibility information or actions.
  Handle inaccessible windows, timeouts, rejected actions, and permission
  revocation explicitly. Keep slow Accessibility requests off the render path.
- "All" should include windows exposed by supported APIs, including minimized
  and off-Space windows where available. Validate enumeration and activation
  across Spaces/fullscreen apps; do not promise completeness before testing.
- Exact Space membership and arbitrary Space switching are not universally
  exposed by the proposed public APIs. Make workspace filters capability-based
  and reject unsupported requests; monitor filtering can use available bounds.
- Prototype presentation over fullscreen Spaces, multiple displays, Stage
  Manager, Retina scaling, and restoring the previously focused window. Drawing
  a borderless raylib window alone does not settle these behaviors.
- Prefer direct Odin framework bindings. The local compiler includes AppKit,
  Foundation, and Objective-C bindings; Accessibility C declarations may need a
  small additional binding. A thin Objective-C C-ABI shim is a fallback, not a
  requirement to rewrite the application in Swift.
- Use a platform-specific single-instance/activation mechanism and integrate
  AppKit and raylib event-loop ownership on the main thread. Do not assume the
  Linux session-bus launch path transfers directly to macOS.
- Keep screen capture/previews out of scope. Determine actual privacy permissions
  in the prototype rather than adding screen-capture or input-monitoring access
  speculatively. A native hotkey or externally configured shortcut can invoke
  the picker; ordinary in-picker input does not require a global key logger.

Ship as a macOS application bundle with stable identity. Determine minimum OS,
Apple Silicon/Intel support, signing, and notarization requirements before
distribution. Linux development can prepare the interface, but validation needs
a real macOS environment. The user has a Mac available later for building and
testing. Prepare the shared interface and isolate platform dependencies during
Linux development; defer macOS build and runtime claims until that validation.
Choose the minimum macOS version and CPU architectures when the test machine is
available. macOS support is planned, not implemented or tested.

### Backend boundary

Represent capabilities explicitly: enumeration, activation, workspace metadata,
monitor metadata, and picker presentation assistance.

The model consumes snapshots and deltas identified by a backend generation and an
opaque window ID. It requests activation and receives success, rejection, or a
vanished-target result. Do not use a title or PID as window identity.

Backend candidates:

1. A compositor exposing wlr foreign-toplevel management, with an appropriate
   presentation mechanism and a named, tested compositor/version.
2. Sway, Hyprland, or another compositor's supported IPC if protocol capabilities
   are insufficient.
3. KDE through a separately researched and tested KWin integration.
4. macOS through AppKit and Accessibility, as described above.

The first release uses the GNOME bridge. Other backends are follow-up work; a
protocol backend must be validated on a named target compositor.

## Picker behavior

1. Invoke the shortcut; capture the previously focused window, workspace, and
   monitor and pointer monitor before the picker takes focus. Resolve filters
   against that context and place the picker on the pointer monitor. Keep it
   there while visible rather than following pointer movement.
2. Group eligible windows by normalized application identity. Render large icons
   in persisted application order with digit/letter badges and application names.
3. For groups with several eligible windows, render overlapping copies of the
   icon, with a capped visual stack and an exact count badge. Counts refer to
   the current filter, not excluded windows.
4. A single-window group's key focuses that window directly. A multi-window
   group's key expands the picker into individually keyed window choices, with
   an icon and distinguishable window title. Reuse the key alphabet at this level.
5. Selecting a child focuses that exact window and hides the picker. Proposed:
   Esc in the child view returns to applications; Esc at the root dismisses and
   restores prior focus where valid.
6. Accept digits and letters without holding the invoking modifiers. Support
   keypad digits and define number-row behavior for layouts using Shift for digits.
   Require key release before the same key can select at the next level; ignore
   autorepeat so a single held key cannot select both a group and a window.

Freeze selection-to-target mappings while each view is visible. Mark closed
targets unavailable, defer additions to the next view/invocation, and never
silently substitute a different window. A group that shrinks during interaction
must not turn a pending keypress into unexpected activation.

Use row-major cells without focus-based sorting. Between invocations, hide absent
or excluded applications and compact the visible list in persisted order. During
interaction, freeze keys: a closed target can leave a temporary unavailable cell
until the view is rebuilt, so its key never selects a different application.
A fresh invocation shows no inactive applications or reserved holes.

Drag and drop explicitly changes saved order. Suppress key activation during a
drag, commit on drop, and save atomically. Cancelled drags leave order unchanged.
New identities append after all remembered identities. When reordering a filtered
subset, rearrange those identities within their existing positions in the saved
list, leaving excluded identities in place.

Example: saved order Browser, Editor, Terminal. With all running, their keys are
1, 2, 3. Closing Editor produces Browser=1, Terminal=2 on the next invocation.
Music is new and appends after Terminal. Reopening Editor restores Browser=1,
Editor=2, Terminal=3, Music=4. Editor has no visible slot while closed.

Do not change column count based on the current number of windows. Define a
consistent overflow policy for small displays and scaling; a display geometry
change may require an explicit layout reset, never a silent key reassignment
while the picker is visible.

Filter out the picker, desktop surfaces, docks, menus, tooltips, and taskbar-skipped
utility windows. Fold attached modal dialogs into their parent target where
appropriate, and ensure activation reaches the dialog. Include minimized windows.

Resolve icons using backend application metadata and desktop entries, including
Flatpak IDs. Fall back to a generic icon. Icon failure must not block switching.
No screenshots or live window previews are required.

## Configuration and lifecycle

Keep configuration small: backend selection/auto-detection, grid/icon sizing,
monitor policy, and scope/numbering rules. Use XDG directories. Persist the ordered
list of application identities automatically, with atomic writes and a schema
version. Prefer desktop-entry IDs/backend app mappings, including Flatpak IDs;
provide aliases for inconsistent IDs. Do not group by title or PID. Unknown
identities append deterministically, and focus/title changes cannot alter identity.
Transient window handles are never restored across sessions. Remembered absent
applications retain ordering metadata only, with no visible tile or reserved
key. Provide explicit forgetting/reset for obsolete identities.

### Invocation filters

Default: all eligible windows across all workspaces and monitors. Proposed CLI:

```sh
bifrost toggle
bifrost toggle --workspace current
bifrost toggle --monitor current
bifrost toggle --workspace current --monitor current
bifrost toggle --app org.mozilla.firefox
```

Compose filters using intersection. Resolve `current` from the pre-picker context;
allow explicit workspace/monitor identifiers once backend semantics are defined.
Filtered invocation retains saved relative order but compacts visible groups and
reassigns keys; child choices include matching windows only. Define monitor
`current` as the pointer monitor at invocation, with active then primary fallback;
workspace `current` means the previously active workspace.
Unsupported filters fail explicitly. Decide whether a different filtered request
while visible replaces the current view; proposed behavior is replace, while an
identical request toggles it off. Starting directly in an application's child
picker is a possible later invocation mode, separate from filtering.

The resident process should be event-driven with no continuous rendering while
hidden. A user service or desktop autostart entry may start it at login; document
the appropriate graphical-session lifecycle rather than assuming the command
inherits a complete desktop environment.

Provide actionable diagnostics for an absent extension, unsupported compositor,
protocol mismatch, stale handles, and inability to present or activate. Logs
should omit window titles by default. Dismiss the picker on session lock and do
not interfere with lock-screen input.

## Implementation milestones

### 0. Resolve product decisions

- Confirm keys, overflow, and child-window ordering.
- Keep compact running-only views and pointer-monitor placement as selected.
- Keep the selected language boundary: Odin/raylib application plus a small
  JavaScript Shell bridge, tested first on GNOME 50.6 Wayland.

Exit: selection semantics and the minimum supported environment are unambiguous.

### 1. Prove GNOME integration and Odin/raylib UI feasibility

- Build a minimal Odin/raylib UI with numbered placeholder icons on native
  Wayland; verify that the window is not using XWayland.
- Prove raylib host integration for the selected presentation mechanism.
- Implement the minimal JavaScript GNOME bridge to list windows and activate an
  opaque target ID over session D-Bus. Keep application policy and rendering in Odin.
- Test invocation from a real desktop shortcut, both cold and resident.
- Test presentation over normal and fullscreen windows, keyboard focus, monitor
  placement, cancellation, and switching to minimized/other-workspace windows.
- Pin raylib/binding versions; document dependencies, presentation behavior, and
  any custom native host or platform integration required.

Exit: a physical shortcut followed by a digit reliably focuses a real window on
the target system, with the agreed UI/language split. Stop and revisit architecture
if this is not feasible; do not build the rest around an unproven focus path.

### 2. Implement stable model and selection

- Implement the backend interface, generation-aware IDs, snapshots and updates.
- Implement application grouping, persisted order, slot lifecycle, two-stage
  selection, filter evaluation, and digit/letter overflow behavior in Odin.
- Test model rules with deterministic event sequences, including closing targets
  while visible, bridge restarts, and duplicate application identities.

Exit: focus churn and unrelated window events cannot silently reassign a visible
selection key.

### 3. Deliver the usable picker

- Add real icons, overlapping stacks, counts, child-window choices, digit/letter
  badges, overflow handling, and empty states.
- Implement drag-and-drop reordering and persisted application identities.
- Integrate single-instance commands and configuration.
- Handle activation rejection, bridge disconnects, cancellation, and focus loss.
- Add scaling, readable contrast, accessible labels, and keypad handling.

Exit: the main use cases and failure cases below work end to end.

### 4. Package and document

- Add reproducible build/check commands and pin tested compiler/dependency versions.
- Package the executable and bridge; provide install/uninstall instructions.
- Document shortcut setup and optional login startup without changing user settings
  as a side effect of building.
- Record the tested desktop versions and remaining limitations.

Exit: the user can build, install, invoke, diagnose, and remove the picker using
the repository documentation.

### 5. Extend portability after the GNOME MVP

Choose the next compositor/backend with the user. Verify both window control and picker
presentation before implementing its adapter. Reuse the same model and selection
acceptance cases; document actual capability differences.

### 6. Prove and deliver macOS support

- Choose the target macOS versions and hardware; test the shared Odin/raylib UI.
- Prove Accessibility authorization, enumeration, and exact-window activation
  with multiple windows, minimized windows, Spaces, and fullscreen apps.
- Validate pointer-monitor placement, presentation, cancellation, and event-loop
  integration; record unsupported filters and application-specific limitations.
- Add the native adapter, icon conversion, notifications, and app-bundle launch
  path while reusing grouping, ordering, drag/drop, and keyboard selection.
- Package and validate permission revocation/recovery and a signed release path.

Exit: the shared picker works on the declared macOS versions, with tested
capabilities and explicit limitations rather than assumed Linux parity.

## Acceptance checks

- Reopening the picker and restarting it preserves remembered application order.
- Focusing windows in different orders does not reorder the picker.
- Unknown applications append; reopening a known application restores its rank.
- Drag-and-drop reorder persists; cancelled drags leave the prior order intact.
- Inactive and filtered groups are absent on fresh invocation; visible groups
  compact in saved order. Reopened applications regain their relative rank.
- Multiple windows produce overlapping icons and expand to individual choices;
  a single-window group activates directly. Child titles disambiguate windows.
- Digits and letters select the displayed target, including minimized and other-workspace
  windows; a modal dialog receives focus when it blocks its parent.
- Disappearing targets, more than nine targets, key-alphabet overflow at both levels,
  and an empty session behave predictably.
- Default scope is all; workspace/monitor/app filters compose correctly, preserve
  the chosen ordering rules, and reject unsupported capabilities explicitly.
- Esc cancels; invocation modifiers need not remain held; repeated key events do
  not accidentally activate another target.
- Cold and resident shortcut invocation work; hidden picker windows are excluded.
- Picker opens on the pointer monitor and remains there while visible; output
  selection fallbacks are explicit and tested.
- Missing icons, long/non-ASCII titles, fractional scaling, mixed-DPI monitors,
  fullscreen applications, and monitor removal are usable or fail explicitly.
- Backend disconnect/reconnect, bridge disable/re-enable, target closure during selection, and application
  restart do not reuse invalid identities.
- If supported, XWayland-hosted applications work within the Wayland session
  without introducing a separate Xorg backend.

Measure invocation-to-visible and selection-to-focus latency separately. Proposed
warm-open target: p95 under 100 ms on the development machine; establish the
measurement procedure and a baseline during the prototype before treating this
as a release requirement. Check hidden CPU usage and memory for obvious leaks.

## Out of scope for the initial release

- Xorg sessions and background process management.
- Window previews, window rearrangement, and workspace management UI.
- Universal compositor compatibility or heuristic restoration of window identities
  after logout/restart.
- Automatic modification of the user's desktop shortcuts.

## Technical references

Consulted 2026-11-10; compositor support and GNOME API compatibility must be
verified against the versions actually tested.

- [Wayland toplevel-list protocol](https://raw.githubusercontent.com/wayland-mirror/wayland-protocols/main/staging/ext-foreign-toplevel-list/ext-foreign-toplevel-list-v1.xml)
- [wlr foreign-toplevel-management protocol](https://raw.githubusercontent.com/swaywm/wlr-protocols/master/unstable/wlr-foreign-toplevel-management-unstable-v1.xml)
- [wlr layer-shell protocol](https://raw.githubusercontent.com/swaywm/wlr-protocols/master/unstable/wlr-layer-shell-unstable-v1.xml)
- [Mutter 50.6 Wayland initialization](https://raw.githubusercontent.com/GNOME/mutter/50.6/src/wayland/meta-wayland.c)
- [Wayland activation protocol](https://raw.githubusercontent.com/wayland-mirror/wayland-protocols/main/staging/xdg-activation/xdg-activation-v1.xml)
- [GNOME Meta.Window API](https://gnome.pages.gitlab.gnome.org/mutter/meta/class.Window.html)
- [GNOME extension structure](https://gjs.guide/extensions/overview/anatomy.html)
- [Raylib Linux build guidance](https://github.com/raysan5/raylib/wiki/Working-on-GNU-Linux)
- [Raylib GLFW desktop backend](https://github.com/raysan5/raylib/blob/master/src/platforms/rcore_desktop_glfw.c)
- [Odin raylib bindings](https://github.com/odin-lang/Odin/blob/master/vendor/raylib/raylib.odin)
- [Odin foreign-function interface](https://odin-lang.org/docs/overview/#foreign-system)
- [Apple NSRunningApplication](https://developer.apple.com/documentation/appkit/nsrunningapplication)
- [Apple window Accessibility attribute](https://developer.apple.com/documentation/applicationservices/kaxwindowsattribute)
- [Apple AXUIElement API](https://developer.apple.com/documentation/applicationservices/axuielement)
- [Apple Accessibility model](https://developer.apple.com/library/archive/documentation/Accessibility/Conceptual/AccessibilityMacOSX/OSXAXmodel.html)
