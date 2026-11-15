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
    const runtimeWatches = new Map();
    const withSignals = object => {
        const signals = new Map();
        return Object.assign(object, {
            signals,
            connect(name, callback) { const id = ++serial; signals.set(id, {name, callback}); return id; },
            disconnect(id) { signals.delete(id); },
            emit(name) { for (const signal of [...signals.values()]) if (signal.name === name) signal.callback(); },
        });
    };
    class Widget {
        constructor(properties = {}) { this.visible = true; Object.assign(this, properties); this.children = []; this.effects = new Map(); }
        add_child(child) { child.parent = this; this.children.push(child); }
        add_effect_with_name(name, effect) { this.effects.set(name, effect); }
        set_position(x, y) { this.x = x; this.y = y; }
        set_size(width, height) { this.width = width; this.height = height; }
        hide() { this.visible = false; }
        show() { this.visible = true; }
        set_child_above_sibling(child, sibling) {
            this.children.splice(this.children.indexOf(child), 1);
            const index = sibling ? this.children.indexOf(sibling) + 1 : this.children.length;
            this.children.splice(index, 0, child);
        }
        destroy() {
            this.destroyed = true;
            for (const child of [...this.children]) child.destroy();
            if (this.parent) this.parent.children.splice(this.parent.children.indexOf(this), 1);
        }
    }
    class InjectionManager {
        constructor() { this.saved = []; }
        overrideMethod(object, name, wrap) {
            this.saved.push({object, name, original: object[name]});
            object[name] = wrap(object[name]);
        }
        clear() { for (const {object, name, original} of this.saved) object[name] = original; this.saved = []; }
    }
    const workspace = {index: () => 2, get_work_area_for_monitor: i =>
        ({x: i * 1000, y: 20, width: 1000, height: 760})};
    const main = {
        sessionMode: withSignals({isLocked: false}),
        layoutManager: withSignals({monitors: [{index: 0, x: 0, y: 0, width: 1000, height: 800},
            {index: 1, x: 1000, y: 0, width: 1000, height: 800}], primaryIndex: 0}),
        uiGroup: new Widget(),
        wm: {animationChecks: [], _shouldAnimateActor(actor, types) {
            this.animationChecks.push({actor, types});
            return actor.animate !== false;
        }},
        activateWindow(w) { global.display.focus_window = w; },
    };
    function window(id, app = 'browser.desktop', title = `Window ${id}`) {
        const result = withSignals({id, moved: null, minimized: true,
            rect: {x: 0, y: 0, width: 600, height: 400},
            get_stable_sequence: () => id, get_wm_class: () => app,
            get_gtk_application_id: () => null, get_title: () => title,
            get_workspace: () => workspace, get_monitor: () => 0,
            is_on_all_workspaces: () => false, is_skip_taskbar: () => false,
            get_frame_rect() { return this.rect; },
            get_compositor_private() { return this.actor; },
            get_transient_for: () => null,
            unminimize() { this.minimized = false; }, make_above() {}, stick() {},
            move_frame(_user, x, y) { this.moved = {x, y}; this.rect = {...this.rect, x, y}; this.emit('position-changed'); },
            delete() { this.emit('unmanaged'); windows.splice(windows.indexOf(this), 1); },
        });
        result.actor = withSignals({meta_window: result, texture: true,
            visible: true, hide() { this.visible = false; }, show() { this.visible = true; },
            scale_x: 1, scale_y: 1, opacity: 255, translation_x: 0, translation_y: 0,
            get_texture() { return this.texture ? {} : null; },
            remove_all_transitions() { this.transitionsRemoved = true; },
            set_pivot_point(x, y) { this.pivot = [x, y]; },
            set_scale(x, y) { this.scale_x = x; this.scale_y = y; },
            get_transformed_position() { return this.position ?? [result.rect.x, result.rect.y]; },
            get_transformed_size() { return this.size ?? [result.rect.width, result.rect.height]; },
        });
        return result;
    }
    const windows = [window(2), window(1)];
    const global = {display: {get_tab_list: () => windows, focus_window: windows[0]},
        stage: {width: 2000, height: 800, captures: [],
            paint_to_content(rect, scale, colorState, flags) {
                const capture = {rect: {...rect}, scale, colorState, flags,
                    visiblePickers: windows.filter(w => w.get_wm_class() === 'org.bifrost.Picker' && w.actor.visible).length,
                    visibleBackdrops: main.uiGroup.children.filter(a => a.visible).length,
                    unredirectDisabled: global.compositor.unredirectDisabled};
                this.captures.push(capture);
                this.onCapture?.();
                if (this.captureError) throw new Error(this.captureError);
                return {id: ++serial, capture};
            }},
        compositor: {unredirectDisabled: 0,
            disable_unredirect() { this.unredirectDisabled++; },
            enable_unredirect() { this.unredirectDisabled--; }},
        get_pointer: () => [1200, 100], get_current_time: () => 123,
        workspace_manager: {get_active_workspace: () => workspace},
        get_window_actors: () => windows.map(w => w.actor)};
    const Gio = {DBusExportedObject: {wrapJSObject: () => ({export() {}, unexport() {}})},
        DBus: {session: {}}, BusNameOwnerFlags: {NONE: 0},
        BusNameWatcherFlags: {NONE: 0},
        bus_watch_name_on_connection(_bus, name, _flags, _appeared, vanished) {
            const id = ++serial; runtimeWatches.set(id, {name, vanished}); return id;
        },
        bus_unwatch_name(id) { runtimeWatches.delete(id); },
        bus_own_name_on_connection: () => 1, bus_unown_name() {}};
    const GLib = {uuid_string_random: () => `uuid-${++serial}`, PRIORITY_DEFAULT: 0,
        SOURCE_CONTINUE: true, SOURCE_REMOVE: false,
        Variant: class {constructor(_type, value) { this.value = value; }},
        timeout_add(_priority, _ms, callback) { const id = ++serial; timers.set(id, callback); return id; },
        source_remove(id) { timers.delete(id); }};
    const Shell = {BlurMode: {ACTOR: 0, BACKGROUND: 1}, BlurEffect: class {constructor(props) { Object.assign(this, props); }},
        WindowTracker: {get_default: () => ({get_window_app: w => ({
        get_id: () => w.get_wm_class(), get_name: () => 'Browser',
        get_app_info: () => ({get_icon: () => ({to_string: () => 'firefox'})}),
    })})}};
    const context = vm.createContext({Gio, GLib, Shell, Meta: {TabList: {NORMAL_ALL: 0}},
        St: {Widget}, Clutter: {FixedLayout: class {}, Clone: class extends Widget {}, PaintFlag: {NO_CURSORS: 1, CLEAR: 4}},
        Mtk: {Rectangle: class {constructor(props) { Object.assign(this, props); }}},
        Main: main, global, Extension: class {}, InjectionManager});
    vm.runInContext(source, context);
    const bridge = new context.BifrostBridge();
    const originalAnimate = main.wm._shouldAnimateActor;
    bridge.enable();
    const tick = () => { for (const [id, callback] of timers) if (!callback()) timers.delete(id); };
    const invocation = () => ({result: null, error: null,
        return_value(value) { this.result = JSON.parse(value.value[0]); },
        return_dbus_error(_name, value) { this.error = value; }});
    return {bridge, global, main, window, windows, timers, tick, invocation, Gio, Shell, originalAnimate, runtimeWatches};
}

function present(f, options = {}) {
    const snapshot = JSON.parse(f.bridge.Snapshot(JSON.stringify({backdrop: options.backdrop !== false})));
    const picker = f.window(10, 'org.bifrost.Picker', `Bifrost · ${snapshot.token}`);
    f.windows.push(picker);
    const call = f.invocation();
    f.bridge.PresentAsync([JSON.stringify({token: snapshot.token, ...options})], call);
    assert.equal(call.result?.ok, true, call.error);
    return {snapshot, picker, session: f.bridge._sessions.get(snapshot.token)};
}

test('full-monitor blur surfaces have no internal edges and stay fixed while the picker moves', () => {
    const f = fixture();
    const monitors = [{x: -1000, y: 0, width: 1000, height: 800},
        {x: 0, y: 0, width: 1200, height: 900}, {x: 1200, y: 200, width: 800, height: 1000}];
    f.main.layoutManager.monitors = monitors.map((m, index) => ({...m, index}));
    const {picker, session} = present(f);
    const surfaces = [...session.backdropTiles];
    for (const rect of [{x: 200, y: 100, width: 600, height: 400},
        {x: -150, y: 300, width: 800, height: 500}, {x: 1900, y: 800, width: 600, height: 600},
        {x: 3000, y: 0, width: 600, height: 400}]) {
        picker.rect = rect;
        picker.emit('size-changed');
        picker.emit('position-changed');
        assert.equal(session.backdropTiles.length, monitors.length);
        for (const [i, surface] of session.backdropTiles.entries()) {
            assert.equal(surface, surfaces[i]);
            const {x, y, width, height} = surface;
            assert.deepEqual({x, y, width, height}, monitors[i]);
        }
        const clone = session.backdropPicker;
        assert.deepEqual({x: clone.x, y: clone.y, width: clone.width, height: clone.height}, rect);
        assert.equal(session.backdrop.children.at(-1), clone);
    }
});

test('present defaults to dimmed background blur with a sharp picker and reuses its actors', () => {
    const f = fixture();
    const {snapshot, picker, session} = present(f);
    const root = session.backdrop;
    assert.equal(f.main.uiGroup.children.length, 1);
    assert.equal(root.reactive, false);
    assert.equal(root.can_focus, false);
    assert.equal(f.global.display.focus_window, picker);
    assert.equal(f.global.compositor.unredirectDisabled, 1);
    assert.equal(session.backdropTiles.length, 2);
    assert.equal(session.backdropTiles.reduce((sum, r) => sum + r.width * r.height, 0), 2 * 1000 * 800);
    for (const tile of session.backdropTiles) {
        assert.equal(tile.reactive, false);
        const blur = tile.effects.get('bifrost-blur');
        assert.equal(blur.mode, f.Shell.BlurMode.ACTOR);
        assert.equal(blur.brightness, 0.55);
        assert.equal(blur.radius, 32);
        assert.ok(tile.content);
    }
    assert.equal(session.backdropPicker.source, picker.actor);
    assert.equal(session.backdropPicker.reactive, false);
    assert.equal(root.children.at(-1), session.backdropPicker);
    const tiles = [...root.children];
    const again = f.invocation();
    f.bridge.PresentAsync([JSON.stringify({token: snapshot.token})], again);
    assert.equal(again.result.ok, true);
    assert.equal(session.backdrop, root);
    assert.deepEqual(root.children, tiles);
    assert.equal(f.global.compositor.unredirectDisabled, 1);
});

test('desktop images are prepared once before the picker and reused without live framebuffer sampling', () => {
    const f = fixture();
    const {snapshot, picker, session} = present(f);
    assert.equal(f.global.stage.captures.length, 2);
    for (const capture of f.global.stage.captures) {
        assert.equal(capture.visiblePickers, 0);
        assert.equal(capture.visibleBackdrops, 0);
        assert.equal(capture.scale, 0.5);
        assert.equal(capture.flags, 5); // NO_CURSORS | CLEAR
        assert.ok(capture.unredirectDisabled > 0);
    }
    const contents = session.backdropTiles.map(tile => tile.content);
    for (let i = 0; i < 20; i++) {
        picker.rect = {x: i * 10, y: i * 5, width: 600 + i, height: 400 + i};
        picker.emit('size-changed');
        picker.actor.emit('notify::allocation');
    }
    const again = f.invocation();
    f.bridge.PresentAsync([JSON.stringify({token: snapshot.token})], again);
    assert.equal(again.result.ok, true);
    assert.equal(f.global.stage.captures.length, 2);
    assert.deepEqual(session.backdropTiles.map(tile => tile.content), contents);
    f.bridge.Dismiss(JSON.stringify({token: snapshot.token}));
    assert.equal(session.backdropCaptures.length, 0);
    assert.equal(session.backdropCaptureKey, null);
    // A rapid reopen must not capture the old native window while Shell is
    // finishing its destruction, even if it has not disappeared from the list.
    present(f);
    assert.equal(f.global.stage.captures.length, 4);
    assert.ok(f.global.stage.captures.every(c => c.visiblePickers === 0 && c.visibleBackdrops === 0));
});

test('diagnostics and disabled backdrop avoid desktop capture; late enabling excludes the picker', () => {
    const f = fixture();
    const diagnostic = JSON.parse(f.bridge.Snapshot(JSON.stringify({backdrop: false})));
    f.bridge.Dismiss(JSON.stringify({token: diagnostic.token}));
    const {snapshot, picker} = present(f, {backdrop: false});
    assert.equal(f.global.stage.captures.length, 0);
    const enabled = f.invocation();
    f.bridge.PresentAsync([JSON.stringify({token: snapshot.token, backdrop: true})], enabled);
    assert.equal(enabled.result.ok, true);
    assert.equal(f.global.stage.captures.length, 2);
    assert.ok(f.global.stage.captures.every(c => c.visiblePickers === 0));
    assert.equal(picker.actor.visible, true);
    assert.equal(f.global.display.focus_window, picker);
});

test('desktop capture failure restores actor visibility and compositor ownership', () => {
    const f = fixture();
    const snapshot = JSON.parse(f.bridge.Snapshot('{}'));
    const picker = f.window(10, 'org.bifrost.Picker', `Bifrost · ${snapshot.token}`);
    f.windows.push(picker);
    f.global.stage.captureError = 'Cannot paint desktop';
    const call = f.invocation();
    f.bridge.PresentAsync([JSON.stringify({token: snapshot.token})], call);
    assert.match(call.error, /Cannot paint desktop/);
    assert.equal(picker.actor.visible, true);
    assert.equal(f.main.uiGroup.children.length, 0);
    assert.equal(f.global.compositor.unredirectDisabled, 0);
    const session = f.bridge._sessions.get(snapshot.token);
    assert.equal(session.capturingBackdrop, false);
    assert.equal(session.backdropCaptures.length, 0);
    picker.emit('unmanaged');
    assert.throws(() => f.bridge.Snapshot(JSON.stringify({backdrop: true})), /Cannot paint desktop/);
    assert.equal(f.bridge._sessions.size, 0);
    assert.equal(f.global.compositor.unredirectDisabled, 0);
});

test('a native client exiting before its window appears releases prepared backdrop images', () => {
    const f = fixture();
    const snapshot = JSON.parse(f.bridge.Snapshot(JSON.stringify({backdrop: true})));
    const session = f.bridge._sessions.get(snapshot.token);
    assert.equal(session.backdropCaptures.length, 2);
    assert.equal(f.runtimeWatches.size, 1);
    const watch = f.runtimeWatches.values().next().value;
    assert.equal(watch.name, 'org.bifrost.PickerRuntime');
    watch.vanished();
    assert.equal(f.bridge._sessions.has(snapshot.token), false);
    assert.equal(session.backdropCaptures.length, 0);
    assert.equal(f.runtimeWatches.size, 0);
    assert.equal(f.main.uiGroup.children.length, 0);
    assert.equal(f.global.compositor.unredirectDisabled, 0);
});

test('backdrop can be disabled and re-enabled without changing native focus', () => {
    const f = fixture();
    const {snapshot, picker, session} = present(f, {backdrop: false});
    assert.equal(f.main.uiGroup.children.length, 0);
    assert.equal(f.global.compositor.unredirectDisabled, 0);
    const set = enabled => {
        const call = f.invocation();
        f.bridge.PresentAsync([JSON.stringify({token: snapshot.token, backdrop: enabled})], call);
        assert.equal(call.result.ok, true);
    };
    set(true);
    const root = session.backdrop;
    set(false);
    assert.ok(root.destroyed);
    assert.equal(f.main.uiGroup.children.length, 0);
    assert.equal(f.global.compositor.unredirectDisabled, 0);
    assert.equal(f.global.display.focus_window, picker);
});

test('backdrop follows window geometry and monitor changes without another presentation', () => {
    const f = fixture();
    const {picker, session} = present(f);
    picker.rect = {x: 100, y: 100, width: 800, height: 500};
    picker.emit('size-changed');
    assert.equal(session.backdropTiles.reduce((sum, r) => sum + r.width * r.height, 0), 1600000);
    picker.rect = {...picker.rect, x: 950};
    picker.emit('position-changed');
    assert.equal(session.backdropPicker.x, 950);
    assert.equal(f.global.stage.captures.length, 2);
    // Offscreen painting may trigger source allocation notifications; it must
    // not recurse into capture or capture the overlay being refreshed.
    f.global.stage.onCapture = () => picker.actor.emit('notify::allocation');
    f.main.layoutManager.monitors = [{x: 0, y: 0, width: 1000, height: 800}];
    f.global.stage.width = 1000;
    f.main.layoutManager.emit('monitors-changed');
    assert.equal(session.backdrop.width, 1000);
    assert.equal(session.backdropTiles.reduce((sum, r) => sum + r.width * r.height, 0), 800000);
    assert.equal(f.global.stage.captures.length, 3);
    assert.ok(f.global.stage.captures.every(c => c.visiblePickers === 0 && c.visibleBackdrops === 0));
    assert.equal(picker.actor.visible, true);
    assert.equal(session.backdrop.visible, true);
    // Buffer allocation can lag Meta.Window geometry. Follow the actual source
    // actor so the sharp copy never exposes a strip of the blurred picker.
    picker.actor.position = [940, 95];
    picker.actor.size = [820, 520];
    picker.actor.emit('notify::allocation');
    assert.deepEqual([session.backdropPicker.x, session.backdropPicker.y], [940, 95]);
    assert.deepEqual([session.backdropPicker.width, session.backdropPicker.height], [820, 520]);
    f.main.layoutManager.monitors.push({x: 1000, y: 0, width: 800, height: 600});
    f.main.layoutManager.emit('monitors-changed');
    assert.equal(session.backdrop.children.at(-1), session.backdropPicker);
});

test('dismiss, native window loss, lock, and disable release backdrop and signal ownership', () => {
    for (const action of ['dismiss', 'unmanaged', 'lock', 'disable']) {
        const f = fixture();
        const {snapshot, picker, session} = present(f);
        const root = session.backdrop;
        if (action === 'dismiss') f.bridge.Dismiss(JSON.stringify({token: snapshot.token}));
        if (action === 'unmanaged') picker.emit('unmanaged');
        if (action === 'lock') { f.main.sessionMode.isLocked = true; f.main.sessionMode.emit('updated'); }
        if (action === 'disable') f.bridge.disable();
        assert.ok(root.destroyed, action);
        assert.equal(f.main.uiGroup.children.length, 0, action);
        assert.equal(f.global.compositor.unredirectDisabled, 0, action);
        assert.equal(picker.signals.size, 0, action);
        assert.equal(picker.actor.signals.size, 0, action);
        assert.equal(f.bridge._sessions.has(snapshot.token), false, action);
        assert.equal(session.backdropCaptures.length, 0, action);
        assert.equal(f.runtimeWatches.size, 0, action);
        if (action !== 'disable') f.bridge.disable();
        assert.equal(f.main.sessionMode.signals.size, 0);
        assert.equal(f.main.layoutManager.signals.size, 0);
    }
});

test('only Bifrost animations are suppressed and the original policy is restored on disable', () => {
    const f = fixture();
    const picker = f.window(10, 'org.bifrost.Picker', 'Bifrost · test');
    const normal = f.window(11, 'browser.desktop', 'Bifrost · document');
    const types = [1, 2, 3];
    assert.equal(f.main.wm._shouldAnimateActor(picker.actor, types), false);
    assert.equal(f.main.wm.animationChecks.length, 0);
    assert.equal(f.main.wm._shouldAnimateActor(normal.actor, types), true);
    assert.equal(f.main.wm.animationChecks[0].types, types);
    normal.actor.animate = false;
    assert.equal(f.main.wm._shouldAnimateActor(normal.actor, types), false);
    f.bridge.disable();
    assert.equal(f.main.wm._shouldAnimateActor, f.originalAnimate);
    assert.equal(f.main.wm._shouldAnimateActor(picker.actor, types), true);
});

test('present waits for drawable content and normalizes any existing map effect before showing the backdrop', () => {
    const f = fixture();
    const snapshot = JSON.parse(f.bridge.Snapshot('{}'));
    const picker = f.window(10, 'org.bifrost.Picker', `Bifrost · ${snapshot.token}`);
    Object.assign(picker.actor, {texture: false, opacity: 0, scale_x: 0.1, scale_y: 0.2,
        translation_x: 7, translation_y: 8});
    f.windows.push(picker);
    const call = f.invocation();
    f.bridge.PresentAsync([JSON.stringify({token: snapshot.token})], call);
    assert.equal(call.result, null);
    assert.equal(f.main.uiGroup.children.length, 0);
    picker.actor.texture = true;
    f.tick();
    assert.equal(call.result.ok, true);
    assert.ok(picker.actor.transitionsRemoved);
    assert.deepEqual([picker.actor.scale_x, picker.actor.scale_y, picker.actor.opacity,
        picker.actor.translation_x, picker.actor.translation_y], [1, 1, 255, 0, 0]);
    assert.deepEqual(picker.actor.pivot, [0, 0]);
    const session = f.bridge._sessions.get(snapshot.token);
    assert.equal(session.backdropPicker.source, picker.actor);
});

test('failed window activation retains the backdrop until a successful selection', () => {
    const f = fixture();
    const {snapshot, session} = present(f);
    const activate = f.main.activateWindow;
    f.main.activateWindow = () => {};
    const rejected = f.invocation();
    f.bridge.ActivateAsync([JSON.stringify({token: snapshot.token, id: snapshot.windows[0].id})], rejected);
    for (let i = 0; i < 30; i++) f.tick();
    assert.equal(rejected.result.ok, false);
    assert.ok(session.backdrop);
    f.main.activateWindow = activate;
    const accepted = f.invocation();
    f.bridge.ActivateAsync([JSON.stringify({token: snapshot.token, id: snapshot.windows[0].id})], accepted);
    f.tick();
    assert.equal(accepted.result.ok, true);
    assert.equal(f.main.uiGroup.children.length, 0);
    assert.equal(f.global.compositor.unredirectDisabled, 0);
});

test('launch failure retains the backdrop and successful app launch removes it', () => {
    const f = fixture();
    const {snapshot, session} = present(f);
    let fail = true;
    f.Shell.AppSystem = {get_default: () => ({lookup_app: () => ({
        get_app_info: () => ({should_show: () => true}),
        open_new_window: () => { if (fail) throw new Error('Cannot start'); },
    })})};
    const request = JSON.stringify({token: snapshot.token, id: 'editor.desktop'});
    assert.equal(JSON.parse(f.bridge.Launch(request)).ok, false);
    assert.ok(session.backdrop);
    fail = false;
    assert.equal(JSON.parse(f.bridge.Launch(request)).ok, true);
    assert.equal(f.main.uiGroup.children.length, 0);
    assert.equal(f.global.compositor.unredirectDisabled, 0);
});

test('partial blur setup failure and malformed requests cannot leave a backdrop behind', () => {
    const f = fixture();
    f.Shell.BlurEffect = class {constructor() { throw new Error('GPU effect unavailable'); }};
    const snapshot = JSON.parse(f.bridge.Snapshot('{}'));
    const picker = f.window(10, 'org.bifrost.Picker', `Bifrost · ${snapshot.token}`);
    f.windows.push(picker);
    const call = f.invocation();
    f.bridge.PresentAsync([JSON.stringify({token: snapshot.token})], call);
    assert.match(call.error, /GPU effect/);
    assert.equal(f.main.uiGroup.children.length, 0);
    assert.equal(f.global.compositor.unredirectDisabled, 0);
    const malformed = f.invocation();
    assert.doesNotThrow(() => f.bridge.PresentAsync(['{'], malformed));
    assert.ok(malformed.error);
    picker.emit('unmanaged');
    assert.equal(picker.signals.size, 0);
});

test('session eviction releases any backdrop and picker signal references', () => {
    const f = fixture();
    const {snapshot, picker} = present(f);
    for (let i = 0; i < 16; i++) f.bridge.Snapshot('{}');
    assert.equal(f.bridge._sessions.has(snapshot.token), false);
    assert.equal(f.main.uiGroup.children.length, 0);
    assert.equal(f.global.compositor.unredirectDisabled, 0);
    assert.equal(picker.signals.size, 0);
});

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
