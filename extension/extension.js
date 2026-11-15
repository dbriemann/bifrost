import Gio from 'gi://Gio';
import GLib from 'gi://GLib';
import Meta from 'gi://Meta';
import Shell from 'gi://Shell';
import St from 'gi://St';
import Clutter from 'gi://Clutter';
import Mtk from 'gi://Mtk';
import {Extension, InjectionManager} from 'resource:///org/gnome/shell/extensions/extension.js';
import * as Main from 'resource:///org/gnome/shell/ui/main.js';

const NAME = 'org.bifrost.WindowBridge';
const PATH = '/org/bifrost/WindowBridge';
const APP_ID = 'org.bifrost.Picker';
const RUNTIME_NAME = 'org.bifrost.PickerRuntime';
const XML = `<node><interface name="${NAME}">
  <method name="Snapshot"><arg type="s" direction="in"/><arg type="s" direction="out"/></method>
  <method name="Present"><arg type="s" direction="in"/><arg type="s" direction="out"/></method>
  <method name="Activate"><arg type="s" direction="in"/><arg type="s" direction="out"/></method>
  <method name="Applications"><arg type="s" direction="in"/><arg type="s" direction="out"/></method>
  <method name="Launch"><arg type="s" direction="in"/><arg type="s" direction="out"/></method>
  <method name="Dismiss"><arg type="s" direction="in"/><arg type="s" direction="out"/></method>
</interface></node>`;

export default class BifrostBridge extends Extension {
    enable() {
        this._generation = GLib.uuid_string_random();
        this._sessions = new Map();
        this._sources = new Set();
        this._animationOverrides = new InjectionManager();
        this._animationOverrides.overrideMethod(Main.wm, '_shouldAnimateActor', original => function (actor, ...args) {
            // A picker is an overlay, not a normal application opening. Avoid
            // exposing the desktop through a scaled/faded picker at startup.
            if (actor.meta_window?.get_wm_class() === APP_ID)
                return false;
            return original.call(this, actor, ...args);
        });
        this._export = Gio.DBusExportedObject.wrapJSObject(XML, this);
        this._export.export(Gio.DBus.session, PATH);
        this._owner = Gio.bus_own_name_on_connection(Gio.DBus.session, NAME,
            Gio.BusNameOwnerFlags.NONE, null, null);
        this._lockSignal = Main.sessionMode.connect('updated', () => {
            if (Main.sessionMode.isLocked) {
                for (const session of this._sessions.values()) {
                    const picker = this._findPicker(session.token);
                    this._retireSession(session.token);
                    picker?.delete(global.get_current_time());
                }
            }
        });
        this._monitorSignal = Main.layoutManager.connect('monitors-changed', () => {
            for (const session of this._sessions.values())
                this._updateBackdrop(session);
        });
    }

    disable() {
        for (const source of this._sources)
            GLib.source_remove(source);
        this._sources.clear();
        Main.sessionMode.disconnect(this._lockSignal);
        Main.layoutManager.disconnect(this._monitorSignal);
        for (const session of this._sessions.values()) {
            const picker = this._findPicker(session.token);
            this._retireSession(session.token);
            picker?.delete(global.get_current_time());
        }
        this._export.unexport();
        Gio.bus_unown_name(this._owner);
        this._sessions.clear();
        this._animationOverrides.clear();
    }

    _destroyBackdrop(session) {
        const backdrop = session.backdrop;
        session.backdrop = null;
        session.backdropTiles = [];
        session.backdropPicker = null;
        session.backdropCaptures = [];
        session.backdropCaptureKey = null;
        try {
            backdrop?.destroy();
        } finally {
            if (session.unredirectDisabled) {
                session.unredirectDisabled = false;
                global.compositor.enable_unredirect();
            }
        }
    }

    _retireSession(token) {
        const session = this._sessions.get(token);
        if (!session)
            return;
        if (session.runtimeWatch) {
            Gio.bus_unwatch_name(session.runtimeWatch);
            session.runtimeWatch = 0;
        }
        this._destroyBackdrop(session);
        for (const signal of session.pickerSignals ?? [])
            session.picker.disconnect(signal);
        if (session.pickerActorSignal)
            session.pickerActor.disconnect(session.pickerActorSignal);
        session.pickerSignals = [];
        session.pickerActorSignal = 0;
        session.pickerActor = null;
        session.picker = null;
        this._sessions.delete(token);
    }

    _watchPicker(session, picker) {
        if (session.picker === picker)
            return;
        for (const signal of session.pickerSignals ?? [])
            session.picker.disconnect(signal);
        if (session.pickerActorSignal)
            session.pickerActor.disconnect(session.pickerActorSignal);
        session.picker = picker;
        session.pickerActor = picker.get_compositor_private();
        session.pickerSignals = [
            picker.connect('unmanaged', () => this._retireSession(session.token)),
            picker.connect('position-changed', () => this._updateBackdrop(session)),
            picker.connect('size-changed', () => this._updateBackdrop(session)),
        ];
        session.pickerActorSignal = session.pickerActor.connect('notify::allocation',
            () => this._updateBackdrop(session));
    }

    _backdropGeometryKey() {
        return JSON.stringify(Main.layoutManager.monitors.map(({x, y, width, height}) =>
            ({x, y, width, height})));
    }

    _captureBackdrop(session) {
        // Normally called by Snapshot, before the native picker exists. For a
        // monitor change or an older client, temporarily hide our actors only
        // during the synchronous offscreen paint; no visible frame is emitted.
        const backdrops = [...this._sessions.values()].map(s => s.backdrop).filter(a => a?.visible);
        const pickers = global.get_window_actors().filter(actor =>
            actor.visible && actor.meta_window?.get_wm_class() === APP_ID);
        const inhibitUnredirect = !session.unredirectDisabled;
        let inhibited = false;
        session.capturingBackdrop = true;
        try {
            // Prepared images exist before there is a Meta.Window to watch.
            // Release them if the native process exits during initialization.
            if (!session.runtimeWatch) {
                session.runtimeWatch = Gio.bus_watch_name_on_connection(Gio.DBus.session,
                    RUNTIME_NAME, Gio.BusNameWatcherFlags.NONE, null,
                    () => this._retireSession(session.token));
            }
            if (inhibitUnredirect) {
                global.compositor.disable_unredirect();
                inhibited = true;
            }
            for (const backdrop of backdrops) backdrop.hide();
            for (const actor of pickers) actor.hide();
            const captures = Main.layoutManager.monitors.map(({x, y, width, height}) => {
                const rect = new Mtk.Rectangle({x, y, width, height});
                // A blurred backdrop needs no full-resolution copy. Render all
                // pixels into a fresh offscreen target, without a mouse cursor.
                const content = global.stage.paint_to_content(rect, 0.5, null,
                    Clutter.PaintFlag.NO_CURSORS | Clutter.PaintFlag.CLEAR);
                if (!content)
                    throw new Error('Could not prepare the desktop backdrop');
                return {content};
            });
            session.backdropCaptures = captures;
            session.backdropCaptureKey = this._backdropGeometryKey();
        } finally {
            for (const actor of pickers) actor.show();
            for (const backdrop of backdrops) backdrop.show();
            if (inhibited) global.compositor.enable_unredirect();
            session.capturingBackdrop = false;
        }
    }

    _updateBackdrop(session) {
        if (!session.backdrop || !session.pickerActor || session.capturingBackdrop)
            return;
        if (session.backdropCaptureKey !== this._backdropGeometryKey())
            this._captureBackdrop(session);
        session.backdrop.set_size(global.stage.width, global.stage.height);
        // Blur the frozen image itself. BACKGROUND mode reads the live stage
        // framebuffer, which can contain incomplete/partially repainted regions.
        const rectangles = Main.layoutManager.monitors;
        for (let i = 0; i < rectangles.length; i++) {
            let tile = session.backdropTiles[i];
            if (!tile) {
                tile = new St.Widget({
                    name: 'bifrost-backdrop-region', reactive: false, can_focus: false,
                });
                // Attach before creating the effect so partial failures are
                // owned by the backdrop and cleaned up with it.
                session.backdrop.add_child(tile);
                session.backdropTiles.push(tile);
                tile.add_effect_with_name('bifrost-blur', new Shell.BlurEffect({
                    radius: 32, brightness: 0.55, mode: Shell.BlurMode.ACTOR,
                }));
            }
            tile.content = session.backdropCaptures[i].content;
            const r = rectangles[i];
            tile.set_position(r.x, r.y);
            tile.set_size(r.width, r.height);
        }
        while (session.backdropTiles.length > rectangles.length)
            session.backdropTiles.pop().destroy();
        if (!session.backdropPicker) {
            session.backdropPicker = new Clutter.Clone({
                source: session.pickerActor, reactive: false,
            });
            session.backdrop.add_child(session.backdropPicker);
        }
        const [x, y] = session.pickerActor.get_transformed_position();
        const [width, height] = session.pickerActor.get_transformed_size();
        session.backdropPicker.set_position(x, y);
        session.backdropPicker.set_size(width, height);
        session.backdrop.set_child_above_sibling(session.backdropPicker, null);
    }

    _showBackdrop(session) {
        if (!session.backdropEnabled) {
            this._destroyBackdrop(session);
            return;
        }
        if (session.backdropCaptureKey !== this._backdropGeometryKey())
            this._captureBackdrop(session);
        if (!session.backdrop) {
            session.backdrop = new St.Widget({
                name: 'bifrost-backdrop', reactive: false, can_focus: false,
                layout_manager: new Clutter.FixedLayout(),
            });
            session.backdropTiles = [];
            // A non-reactive clone keeps the picker sharp above the full blur;
            // native pointer input/focus still belongs to the original window.
            // No window actors are reparented. Background images stay in memory
            // only and are discarded with this picker session.
            Main.uiGroup.add_child(session.backdrop);
            global.compositor.disable_unredirect();
            session.unredirectDisabled = true;
        }
        this._updateBackdrop(session);
    }

    _windows() {
        return global.display.get_tab_list(Meta.TabList.NORMAL_ALL, null)
            .filter(w => !w.is_skip_taskbar() && !this._isPicker(w))
            .sort((a, b) => a.get_stable_sequence() - b.get_stable_sequence());
    }

    _isPicker(w) {
        return w.get_wm_class() === APP_ID || w.get_title()?.startsWith('Bifrost · ');
    }

    _findPicker(token) {
        return global.get_window_actors().map(a => a.meta_window)
            .find(w => w.get_title() === `Bifrost · ${token}` &&
                w.get_wm_class() === APP_ID);
    }

    _session(request) {
        if (Main.sessionMode.isLocked)
            throw new Error('Session is locked');
        const session = this._sessions.get(request.token);
        if (!session)
            throw new Error('Picker session expired; reopen Bifrost');
        return session;
    }

    Snapshot(input) {
        if (Main.sessionMode.isLocked)
            throw new Error('Session is locked');
        const request = JSON.parse(input);
        // Keep abandoned snapshots bounded (e.g. a crashed client).
        if (this._sessions.size >= 16)
            this._retireSession(this._sessions.keys().next().value);
        const token = GLib.uuid_string_random();
        const previous = global.display.focus_window;
        const [px, py] = global.get_pointer();
        const monitors = Main.layoutManager.monitors;
        const monitor = monitors.find(m => px >= m.x && px < m.x + m.width &&
            py >= m.y && py < m.y + m.height) ?? Main.layoutManager.currentMonitor;
        const index = monitor?.index ?? Main.layoutManager.primaryIndex;
        const workspace = global.workspace_manager.get_active_workspace();
        const area = workspace.get_work_area_for_monitor(index);
        const tracker = Shell.WindowTracker.get_default();
        const windows = this._windows().map(w => {
            const app = tracker.get_window_app(w);
            const appInfo = app?.get_app_info();
            const appId = (appInfo ? app.get_id() : null) ??
                w.get_gtk_application_id() ?? w.get_wm_class() ??
                `unknown:${w.get_stable_sequence()}`;
            return {
                id: `${this._generation}:${w.get_stable_sequence()}`,
                app: appId,
                name: app?.get_name() ?? w.get_wm_class() ?? 'Unknown application',
                title: w.get_title() ?? '',
                icon: appInfo?.get_icon()?.to_string() ?? '',
                workspace: w.is_on_all_workspaces() ? -1 : (w.get_workspace()?.index() ?? -1),
                monitor: w.get_monitor(),
            };
        });
        const session = {token, previous, workspace, monitor: index};
        this._sessions.set(token, session);
        try {
            if (request.backdrop === true)
                this._captureBackdrop(session);
        } catch (error) {
            this._retireSession(token);
            throw error;
        }
        return JSON.stringify({version: 1, token, generation: this._generation,
            workspace: workspace.index(), monitor: index,
            width: area.width, height: area.height, windows});
    }

    _presentPicker(session) {
        const picker = this._findPicker(session.token);
        if (!picker)
            return false;
        const actor = picker.get_compositor_private();
        if (!actor?.get_texture())
            return false;
        // Also finish any effect already running when this extension was
        // enabled. Normalize before creating the sharp clone/backdrop.
        actor.remove_all_transitions();
        actor.set_pivot_point(0, 0);
        actor.set_scale(1, 1);
        actor.opacity = 255;
        actor.translation_x = 0;
        actor.translation_y = 0;
        const area = session.workspace.get_work_area_for_monitor(session.monitor);
        const rect = picker.get_frame_rect();
        picker.move_frame(true,
            area.x + Math.round((area.width - rect.width) / 2),
            area.y + Math.round((area.height - rect.height) / 2));
        picker.make_above();
        picker.stick();
        Main.activateWindow(picker);
        this._watchPicker(session, picker);
        this._showBackdrop(session);
        return true;
    }

    PresentAsync([input], invocation) {
        let session;
        try {
            const request = JSON.parse(input);
            session = this._session(request);
            session.backdropEnabled = request.backdrop !== false;
            // Usually the first submitted frame is already mapped. Avoid an
            // unconditional 25 ms timer before attempting to show it.
            if (this._presentPicker(session)) {
                invocation.return_value(new GLib.Variant('(s)', ['{"ok":true}']));
                return;
            }
            let attempts = 0;
            const source = GLib.timeout_add(GLib.PRIORITY_DEFAULT, 25, () => {
                try {
                    this._session(request);
                    if (!this._presentPicker(session)) {
                        if (++attempts < 60)
                            return GLib.SOURCE_CONTINUE;
                        throw new Error('Native Wayland picker window not found');
                    }
                    invocation.return_value(new GLib.Variant('(s)', ['{"ok":true}']));
                } catch (error) {
                    this._destroyBackdrop(session);
                    invocation.return_dbus_error(`${NAME}.Failed`, error.message);
                }
                this._sources.delete(source);
                return GLib.SOURCE_REMOVE;
            });
            this._sources.add(source);
        } catch (error) {
            if (session)
                this._destroyBackdrop(session);
            invocation.return_dbus_error(`${NAME}.Failed`, error.message);
        }
    }

    ActivateAsync([input], invocation) {
        try {
            const request = JSON.parse(input);
            this._session(request);
            const window = this._windows().find(w =>
                `${this._generation}:${w.get_stable_sequence()}` === request.id);
            if (!window) {
                invocation.return_value(new GLib.Variant('(s)', [JSON.stringify({
                    ok: false, error: 'Window closed; reopen the picker',
                })]));
                return;
            }
            window.unminimize();
            Main.activateWindow(window);
            let attempts = 0;
            const source = GLib.timeout_add(GLib.PRIORITY_DEFAULT, 25, () => {
                const focus = global.display.focus_window;
                const ok = focus === window || focus?.get_transient_for() === window;
                if (!ok && ++attempts < 30 && !Main.sessionMode.isLocked)
                    return GLib.SOURCE_CONTINUE;
                if (ok)
                    this._retireSession(request.token);
                invocation.return_value(new GLib.Variant('(s)', [JSON.stringify({
                    ok, error: ok ? '' : 'GNOME did not grant focus to that window',
                })]));
                this._sources.delete(source);
                return GLib.SOURCE_REMOVE;
            });
            this._sources.add(source);
        } catch (error) {
            invocation.return_dbus_error(`${NAME}.Failed`, error.message);
        }
    }

    Applications(input) {
        this._session(JSON.parse(input));
        const apps = Gio.AppInfo.get_all()
            .filter(info => info.should_show() && info.get_id())
            .map(info => ({
                id: info.get_id(),
                name: info.get_display_name() ?? info.get_name() ?? '',
                description: info.get_description() ?? '',
                keywords: (info.get_keywords?.() ?? []).join(' '),
                executable: info.get_executable() ?? '',
            }));
        return JSON.stringify({version: 1, apps});
    }

    Launch(input) {
        const request = JSON.parse(input);
        const session = this._session(request);
        const app = Shell.AppSystem.get_default().lookup_app(request.id);
        if (!app || !app.get_app_info()?.should_show())
            return JSON.stringify({ok: false, error: 'Application is no longer available'});
        try {
            // Delegate desktop-file launch semantics to Shell; never interpret
            // search text or desktop Exec fields as shell commands ourselves.
            app.open_new_window(session.workspace.index());
            this._retireSession(request.token);
            return '{"ok":true}';
        } catch (error) {
            return JSON.stringify({ok: false, error: error.message});
        }
    }

    Dismiss(input) {
        const request = JSON.parse(input);
        const session = this._session(request);
        const previous = session.previous;
        const picker = this._findPicker(session.token);
        // Do not steal focus back if the user has clicked another application.
        if (previous && picker && global.display.focus_window === picker &&
            global.get_window_actors().some(a => a.meta_window === previous))
            Main.activateWindow(previous);
        this._retireSession(request.token);
        return '{"ok":true}';
    }
}
