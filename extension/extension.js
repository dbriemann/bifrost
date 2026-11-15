import Gio from 'gi://Gio';
import GLib from 'gi://GLib';
import Meta from 'gi://Meta';
import Shell from 'gi://Shell';
import {Extension} from 'resource:///org/gnome/shell/extensions/extension.js';
import * as Main from 'resource:///org/gnome/shell/ui/main.js';

const NAME = 'org.bifrost.WindowBridge';
const PATH = '/org/bifrost/WindowBridge';
const APP_ID = 'org.bifrost.Picker';
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
        this._export = Gio.DBusExportedObject.wrapJSObject(XML, this);
        this._export.export(Gio.DBus.session, PATH);
        this._owner = Gio.bus_own_name_on_connection(Gio.DBus.session, NAME,
            Gio.BusNameOwnerFlags.NONE, null, null);
        this._lockSignal = Main.sessionMode.connect('updated', () => {
            if (Main.sessionMode.isLocked) {
                for (const session of this._sessions.values()) {
                    const picker = this._findPicker(session.token);
                    picker?.delete(global.get_current_time());
                }
                this._sessions.clear();
            }
        });
    }

    disable() {
        for (const source of this._sources)
            GLib.source_remove(source);
        this._sources.clear();
        Main.sessionMode.disconnect(this._lockSignal);
        for (const session of this._sessions.values()) {
            const picker = this._findPicker(session.token);
            picker?.delete(global.get_current_time());
        }
        this._export.unexport();
        Gio.bus_unown_name(this._owner);
        this._sessions.clear();
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

    Snapshot(_input) {
        if (Main.sessionMode.isLocked)
            throw new Error('Session is locked');
        // Keep abandoned snapshots bounded (e.g. a crashed client).
        if (this._sessions.size >= 16)
            this._sessions.delete(this._sessions.keys().next().value);
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
        this._sessions.set(token, {token, previous, workspace, monitor: index});
        return JSON.stringify({version: 1, token, generation: this._generation,
            workspace: workspace.index(), monitor: index,
            width: area.width, height: area.height, windows});
    }

    PresentAsync([input], invocation) {
        try {
            const request = JSON.parse(input);
            const session = this._session(request);
            let attempts = 0;
            const source = GLib.timeout_add(GLib.PRIORITY_DEFAULT, 25, () => {
                try {
                    this._session(request);
                    const picker = this._findPicker(session.token);
                    if (!picker) {
                        if (++attempts < 60)
                            return GLib.SOURCE_CONTINUE;
                        throw new Error('Native Wayland picker window not found');
                    }
                    const area = session.workspace.get_work_area_for_monitor(session.monitor);
                    const rect = picker.get_frame_rect();
                    picker.move_frame(true,
                        area.x + Math.round((area.width - rect.width) / 2),
                        area.y + Math.round((area.height - rect.height) / 2));
                    picker.make_above();
                    picker.stick();
                    Main.activateWindow(picker);
                    invocation.return_value(new GLib.Variant('(s)', ['{"ok":true}']));
                } catch (error) {
                    invocation.return_dbus_error(`${NAME}.Failed`, error.message);
                }
                this._sources.delete(source);
                return GLib.SOURCE_REMOVE;
            });
            this._sources.add(source);
        } catch (error) {
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
                    this._sessions.delete(request.token);
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
            this._sessions.delete(request.token);
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
        this._sessions.delete(request.token);
        return '{"ok":true}';
    }
}
