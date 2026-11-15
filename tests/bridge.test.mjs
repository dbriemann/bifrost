// Execute the actual extension class against a small compositor fixture. This
// checks bridge behavior; it does not replace a real GNOME presentation test.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';
import {test} from 'node:test';

const source = fs.readFileSync('extension/extension.js', 'utf8')
    .replace(/^import .*;\n/gm, '')
    .replace('export default class BifrostBridge', 'globalThis.BifrostBridge = class BifrostBridge');

function fixture() {
    let serial = 0;
    const timers = new Map();
    const workspace = {index: () => 2, get_work_area_for_monitor: i =>
        ({x: i * 1000, y: 20, width: 1000, height: 760})};
    const main = {
        sessionMode: {isLocked: false, connect: () => 1, disconnect() {}},
        layoutManager: {monitors: [{index: 0, x: 0, y: 0, width: 1000, height: 800},
            {index: 1, x: 1000, y: 0, width: 1000, height: 800}], primaryIndex: 0},
        activateWindow(w) { global.display.focus_window = w; },
    };
    function window(id, app = 'browser.desktop', title = `Window ${id}`) {
        return {id, moved: null, minimized: true,
            get_stable_sequence: () => id, get_wm_class: () => app,
            get_gtk_application_id: () => null, get_title: () => title,
            get_workspace: () => workspace, get_monitor: () => 0,
            is_on_all_workspaces: () => false, is_skip_taskbar: () => false,
            get_frame_rect: () => ({width: 600, height: 400}),
            get_transient_for: () => null,
            unminimize() { this.minimized = false; }, make_above() {}, stick() {},
            move_frame(_user, x, y) { this.moved = {x, y}; },
        };
    }
    const windows = [window(2), window(1)];
    const global = {display: {get_tab_list: () => windows, focus_window: windows[0]},
        get_pointer: () => [1200, 100], get_current_time: () => 123,
        workspace_manager: {get_active_workspace: () => workspace},
        get_window_actors: () => windows.map(meta_window => ({meta_window}))};
    const Gio = {DBusExportedObject: {wrapJSObject: () => ({export() {}, unexport() {}})},
        DBus: {session: {}}, BusNameOwnerFlags: {NONE: 0},
        bus_own_name_on_connection: () => 1, bus_unown_name() {}};
    const GLib = {uuid_string_random: () => `uuid-${++serial}`, PRIORITY_DEFAULT: 0,
        SOURCE_CONTINUE: true, SOURCE_REMOVE: false,
        Variant: class {constructor(_type, value) { this.value = value; }},
        timeout_add(_priority, _ms, callback) { const id = ++serial; timers.set(id, callback); return id; },
        source_remove(id) { timers.delete(id); }};
    const Shell = {WindowTracker: {get_default: () => ({get_window_app: w => ({
        get_id: () => w.get_wm_class(), get_name: () => 'Browser',
        get_app_info: () => ({get_icon: () => ({to_string: () => 'firefox'})}),
    })})}};
    const context = vm.createContext({Gio, GLib, Shell, Meta: {TabList: {NORMAL_ALL: 0}},
        Main: main, global, Extension: class {}});
    vm.runInContext(source, context);
    const bridge = new context.BifrostBridge();
    bridge.enable();
    const tick = () => { for (const [id, callback] of timers) if (!callback()) timers.delete(id); };
    const invocation = () => ({result: null, error: null,
        return_value(value) { this.result = JSON.parse(value.value[0]); },
        return_dbus_error(_name, value) { this.error = value; }});
    return {bridge, global, main, window, windows, timers, tick, invocation, Gio, Shell};
}

test('snapshot sorts stable window identities and captures pointer monitor', () => {
    const f = fixture();
    const s = JSON.parse(f.bridge.Snapshot('{}'));
    assert.equal(s.version, 1);
    assert.equal(s.monitor, 1);
    assert.equal(s.workspace, 2);
    assert.equal(s.windows[0].id, `${s.generation}:1`);
    assert.equal(s.windows[0].icon, 'firefox');
});

test('present centers only the matching picker and activates it', () => {
    const f = fixture();
    const s = JSON.parse(f.bridge.Snapshot('{}'));
    const picker = f.window(10, 'org.bifrost.Picker', `Bifrost · ${s.token}`);
    f.windows.push(picker);
    const call = f.invocation();
    f.bridge.PresentAsync([JSON.stringify({token: s.token})], call);
    // An already mapped picker must not wait for a timer tick.
    assert.equal(call.result.ok, true);
    assert.equal(f.timers.size, 0);
    assert.deepEqual(picker.moved, {x: 1200, y: 200});
    assert.equal(f.global.display.focus_window, picker);
    assert.equal(JSON.parse(f.bridge.Snapshot('{}')).windows.length, 2);
});

test('present retries while mapping is pending and removes its timer when ready', () => {
    const f = fixture();
    const s = JSON.parse(f.bridge.Snapshot('{}'));
    const call = f.invocation();
    f.bridge.PresentAsync([JSON.stringify({token: s.token})], call);
    assert.equal(call.result, null);
    assert.equal(f.timers.size, 1);
    f.tick();
    assert.equal(call.result, null);
    const picker = f.window(10, 'org.bifrost.Picker', `Bifrost · ${s.token}`);
    f.windows.push(picker);
    f.tick();
    assert.equal(call.result.ok, true);
    assert.equal(f.global.display.focus_window, picker);
    assert.equal(f.timers.size, 0);
    assert.equal(f.bridge._sources.size, 0);
});

test('present stops retrying when the picker never maps or the session locks', () => {
    const f = fixture();
    const s = JSON.parse(f.bridge.Snapshot('{}'));
    const call = f.invocation();
    f.bridge.PresentAsync([JSON.stringify({token: s.token})], call);
    for (let i = 0; i < 60; i++) f.tick();
    assert.match(call.error, /not found/);
    assert.equal(f.timers.size, 0);
    assert.equal(f.bridge._sources.size, 0);
    const locked = f.invocation();
    f.bridge.PresentAsync([JSON.stringify({token: s.token})], locked);
    f.main.sessionMode.isLocked = true;
    f.tick();
    assert.match(locked.error, /locked/);
    assert.equal(f.timers.size, 0);
    assert.equal(f.bridge._sources.size, 0);
});

test('selects exact window, unminimizes, and retires the session', () => {
    const f = fixture();
    const s = JSON.parse(f.bridge.Snapshot('{}'));
    const call = f.invocation();
    f.bridge.ActivateAsync([JSON.stringify({token: s.token, id: s.windows[0].id})], call);
    f.tick();
    assert.equal(call.result.ok, true);
    assert.equal(f.global.display.focus_window.id, 1);
    assert.equal(f.windows[1].minimized, false);
    assert.throws(() => f.bridge.Dismiss(JSON.stringify({token: s.token})), /expired/);
});

test('closed or stale targets do not activate a replacement', () => {
    const f = fixture();
    const s = JSON.parse(f.bridge.Snapshot('{}'));
    f.windows.pop();
    const before = f.global.display.focus_window;
    const call = f.invocation();
    f.bridge.ActivateAsync([JSON.stringify({token: s.token, id: s.windows[0].id})], call);
    assert.equal(call.result.ok, false);
    assert.equal(f.global.display.focus_window, before);
    const stale = f.invocation();
    f.bridge.ActivateAsync([JSON.stringify({token: 'old', id: s.windows[1].id})], stale);
    assert.match(stale.error, /expired/);
});

test('dismiss restores focus only while picker still owns focus', () => {
    const f = fixture();
    const s = JSON.parse(f.bridge.Snapshot('{}'));
    const previous = f.global.display.focus_window;
    const picker = f.window(10, 'org.bifrost.Picker', `Bifrost · ${s.token}`);
    f.windows.push(picker);
    f.global.display.focus_window = picker;
    f.bridge.Dismiss(JSON.stringify({token: s.token}));
    assert.equal(f.global.display.focus_window, previous);
    const other = JSON.parse(f.bridge.Snapshot('{}'));
    f.global.display.focus_window = f.windows[1];
    f.bridge.Dismiss(JSON.stringify({token: other.token}));
    assert.equal(f.global.display.focus_window, f.windows[1]);
});

test('session lock rejects requests and bridge teardown releases pending timers', () => {
    const f = fixture();
    const s = JSON.parse(f.bridge.Snapshot('{}'));
    const call = f.invocation();
    f.bridge.PresentAsync([JSON.stringify({token: s.token})], call);
    assert.equal(f.timers.size, 1);
    f.main.sessionMode.isLocked = true;
    f.tick();
    assert.match(call.error, /locked/);
    assert.throws(() => f.bridge.Snapshot('{}'), /locked/);
    f.bridge.disable();
    assert.equal(f.timers.size, 0);
});

test('snapshot diagnostics do not invalidate another open picker session', () => {
    const f = fixture();
    const first = JSON.parse(f.bridge.Snapshot('{}'));
    const second = JSON.parse(f.bridge.Snapshot('{}'));
    f.bridge.Dismiss(JSON.stringify({token: second.token}));
    assert.doesNotThrow(() => f.bridge.Dismiss(JSON.stringify({token: first.token})));
});

test('activation waits for focus and reports compositor rejection', () => {
    const f = fixture();
    const s = JSON.parse(f.bridge.Snapshot('{}'));
    f.main.activateWindow = () => {};
    const call = f.invocation();
    f.bridge.ActivateAsync([JSON.stringify({token: s.token, id: s.windows[0].id})], call);
    f.tick();
    assert.equal(call.result, null);
    for (let i = 0; i < 30; i++) f.tick();
    assert.equal(call.result.ok, false);
    assert.match(call.result.error, /focus/);
});


test('launcher catalogue includes visible installed apps and metadata only', () => {
    const f = fixture();
    const s = JSON.parse(f.bridge.Snapshot('{}'));
    const info = (id, show) => ({should_show: () => show, get_id: () => id,
        get_display_name: () => 'Text Editor', get_description: () => 'Edit text',
        get_keywords: () => ['text', 'editor'], get_executable: () => 'gnome-text-editor'});
    f.Gio.AppInfo = {get_all: () => [info('editor.desktop', true), info('hidden.desktop', false), info('', true)]};
    const catalogue = JSON.parse(f.bridge.Applications(JSON.stringify({token: s.token})));
    assert.equal(catalogue.version, 1);
    assert.equal(catalogue.apps.length, 1);
    assert.equal(catalogue.apps[0].id, 'editor.desktop');
    assert.equal(catalogue.apps[0].keywords, 'text editor');
    assert.equal(catalogue.apps[0].executable, 'gnome-text-editor');
});

test('launcher starts the exact desktop app on the captured workspace', () => {
    const f = fixture();
    const s = JSON.parse(f.bridge.Snapshot('{}'));
    const launches = [];
    f.Shell.AppSystem = {get_default: () => ({lookup_app: id => id === 'editor.desktop' ? {
        get_app_info: () => ({should_show: () => true}),
        open_new_window: workspace => launches.push({id, workspace}),
    } : null})};
    const reply = JSON.parse(f.bridge.Launch(JSON.stringify({token: s.token, id: 'editor.desktop'})));
    assert.equal(reply.ok, true);
    assert.deepEqual(launches, [{id: 'editor.desktop', workspace: 2}]);
    assert.throws(() => f.bridge.Dismiss(JSON.stringify({token: s.token})), /expired/);
});

test('launcher launch errors and vanished apps keep the picker session usable', () => {
    const f = fixture();
    const s = JSON.parse(f.bridge.Snapshot('{}'));
    f.Shell.AppSystem = {get_default: () => ({lookup_app: id => id === 'broken.desktop' ? {
        get_app_info: () => ({should_show: () => true}),
        open_new_window: () => { throw new Error('Cannot start application'); },
    } : null})};
    const request = id => JSON.stringify({token: s.token, id});
    assert.equal(JSON.parse(f.bridge.Launch(request('missing.desktop'))).ok, false);
    assert.match(JSON.parse(f.bridge.Launch(request('broken.desktop'))).error, /Cannot start/);
    assert.equal(JSON.parse(f.bridge.Launch(request('; touch /tmp/not-a-command'))).ok, false);
    assert.doesNotThrow(() => f.bridge.Dismiss(JSON.stringify({token: s.token})));
});

test('launcher requests reject locked and stale sessions before accessing apps', () => {
    const f = fixture();
    const s = JSON.parse(f.bridge.Snapshot('{}'));
    assert.throws(() => f.bridge.Applications(JSON.stringify({token: 'stale'})), /expired/);
    f.main.sessionMode.isLocked = true;
    assert.throws(() => f.bridge.Applications(JSON.stringify({token: s.token})), /locked/);
    assert.throws(() => f.bridge.Launch(JSON.stringify({token: s.token, id: 'editor.desktop'})), /locked/);
});
