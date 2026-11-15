package main

import "core:fmt"
import "core:strings"
import "core:testing"
import "core:unicode/utf8"

@(test)
fuzzy_ranking_prefers_exact_names_prefixes_and_word_starts :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)
    apps := []Launcher_App{
        {id="bonfire.desktop", name="Bonfire Utility"},
        {id="firefox-dev.desktop", name="Firefox Developer Edition"},
        {id="firefox.desktop", name="Firefox", keywords="web browser"},
        {id="code.desktop", name="Visual Studio Code", executable="code"},
        {id="editor.desktop", name="Text Editor"},
    }
    results := search_apps(apps, "firefox")
    testing.expect_value(t, apps[results[0].index].id, "firefox.desktop")
    delete(results)
    results = search_apps(apps, "fire")
    testing.expect_value(t, apps[results[0].index].id, "firefox.desktop")
    delete(results)
    results = search_apps(apps, "vsc")
    testing.expect_value(t, apps[results[0].index].id, "code.desktop")
    delete(results)
    results = search_apps(apps, "ff")
    testing.expect_value(t, apps[results[0].index].id, "firefox.desktop")
    delete(results)
    results = search_apps(apps, "texteditor")
    testing.expect_value(t, apps[results[0].index].id, "editor.desktop")
    delete(results)
}

@(test)
launcher_search_matches_keywords_and_unicode_case :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)
    apps := []Launcher_App{
        {id="browser.desktop", name="Firefox", keywords="internet web browser"},
        {id="editor.desktop", name="Éditeur", executable="edit"},
    }
    results := search_apps(apps, "BROWSER")
    testing.expect_value(t, len(results), 1)
    testing.expect_value(t, results[0].index, 0)
    delete(results)
    results = search_apps(apps, "éDI")
    testing.expect_value(t, len(results), 1)
    testing.expect_value(t, results[0].index, 1)
    delete(results)
    results = search_apps(apps, "not-an-installed-app")
    testing.expect_value(t, len(results), 0)
    delete(results)
}

@(test)
launcher_returns_at_most_ten_unique_stable_results :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)
    apps := make([]Launcher_App, 16)
    defer delete(apps)
    for i in 0..<15 {
        apps[i] = Launcher_App{
            id=fmt.tprintf("app%02d.desktop", 14-i),
            name=fmt.tprintf("App %02d", 14-i),
        }
    }
    apps[15] = apps[0]
    results := search_apps(apps, "")
    defer delete(results)
    testing.expect_value(t, len(results), 10)
    for result, i in results {
        testing.expect_value(t, apps[result.index].name, fmt.tprintf("App %02d", i))
    }
    filtered := search_apps(apps, "App")
    defer delete(filtered)
    testing.expect_value(t, len(filtered), 10)
}

@(test)
launcher_text_edits_are_unicode_safe_and_refresh_selection :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)
    state := Launcher{apps=[]Launcher_App{{id="firefox.desktop", name="Firefox"}}}
    defer delete(state.query)
    defer delete(state.results)
    for r in "fé" { testing.expect(t, launcher_insert(&state, r)) }
    state.cursor = 1
    testing.expect(t, launcher_insert(&state, 'i'))
    value := utf8.runes_to_string(state.query[:], context.temp_allocator)
    testing.expect_value(t, value, "fié")
    testing.expect(t, launcher_backspace(&state))
    testing.expect(t, launcher_delete(&state))
    value = utf8.runes_to_string(state.query[:], context.temp_allocator)
    testing.expect_value(t, value, "f")
    launcher_refresh(&state)
    testing.expect_value(t, len(state.results), 1)
    state.selected, state.top = 4, 3
    testing.expect(t, launcher_insert(&state, 'x'))
    launcher_refresh(&state)
    testing.expect_value(t, state.selected, 0)
    testing.expect_value(t, state.top, 0)
    testing.expect(t, !launcher_insert(&state, '\n'))
    testing.expect(t, !launcher_insert(&state, '\t'))
}

@(test)
fuzzy_match_requires_order_and_prefers_consecutive_letters :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)
    consecutive, ok := fuzzy_score("Terminal", "term")
    testing.expect(t, ok)
    scattered, ok2 := fuzzy_score("The Error Report Manager", "term")
    testing.expect(t, ok2)
    testing.expect(t, consecutive > scattered)
    _, reversed := fuzzy_score("abc", "cba")
    testing.expect(t, !reversed)
    _, blank := fuzzy_score("abc", strings.trim_space("  "))
    testing.expect(t, blank)
}

@(test)
launcher_click_starts_the_exact_scrolled_result_and_preserves_keyboard_highlight :: proc(t: ^testing.T) {
    state := Launcher{results=make([dynamic]Search_Result), top=1}
    defer delete(state.results)
    append(&state.results, Search_Result{index=7}, Search_Result{index=2}, Search_Result{index=5})
    testing.expect_value(t, launcher_pointer_step(&state, 45, LAUNCHER_LIST_Y+5,
        700, 760, true, true, false, false), -1)
    testing.expect_value(t, state.selected, 1)
    testing.expect_value(t, launcher_pointer_step(&state, 46, LAUNCHER_LIST_Y+5,
        700, 760, false, false, true, true), 2)
    testing.expect(t, !state.pointer.active)
    // A subsequent Tab changes selection even if the mouse remains on this row.
    state.selected = cycle_selection(state.selected, len(state.results), false)
    launcher_pointer_step(&state, 46, LAUNCHER_LIST_Y+5, 700, 760, false, false, false, false)
    testing.expect_value(t, state.selected, 2)
    launcher_pointer_step(&state, 46, LAUNCHER_LIST_Y+6, 700, 760, false, false, false, true)
    testing.expect_value(t, state.selected, 1)
}

@(test)
launcher_drags_padding_and_release_on_another_result_do_not_start_apps :: proc(t: ^testing.T) {
    state := Launcher{results=make([dynamic]Search_Result)}
    defer delete(state.results)
    append(&state.results, Search_Result{index=7}, Search_Result{index=2})
    launcher_pointer_step(&state, 45, LAUNCHER_LIST_Y+5, 700, 760, true, true, false, false)
    testing.expect_value(t, launcher_pointer_step(&state, 45, LAUNCHER_LIST_Y+53,
        700, 760, false, false, true, true), -1)
    launcher_pointer_step(&state, 45, LAUNCHER_LIST_Y+5, 700, 760, true, true, false, false)
    testing.expect_value(t, launcher_pointer_step(&state, 80, LAUNCHER_LIST_Y+5,
        700, 760, false, false, true, true), -1)
    // Text field, row separator, panel padding, empty rows, and clipped rows.
    for point in ([6][2]f32{{45,100}, {45,LAUNCHER_LIST_Y+47}, {20,LAUNCHER_LIST_Y+5},
        {680,LAUNCHER_LIST_Y+5}, {45,LAUNCHER_LIST_Y+101}, {45,LAUNCHER_LIST_Y+53}}) {
        launcher_pointer_step(&state, point[0], point[1], 700, 258, true, true, false, false)
        testing.expect_value(t, launcher_pointer_step(&state, point[0], point[1],
            700, 258, false, false, true, false), -1)
        testing.expect(t, !state.pointer.active)
    }
}

@(test)
launcher_query_changes_cancel_pending_clicks :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)
    state := Launcher{apps=[]Launcher_App{{id="a.desktop", name="Alpha"}, {id="b.desktop", name="Beta"}}}
    defer delete(state.results)
    defer delete(state.query)
    launcher_refresh(&state)
    launcher_pointer_step(&state, 45, LAUNCHER_LIST_Y+5, 700, 760, true, true, false, false)
    testing.expect(t, state.pointer.active)
    launcher_insert(&state, 'b')
    launcher_refresh(&state)
    testing.expect_value(t, len(state.results), 1)
    testing.expect(t, !state.pointer.active)
    testing.expect_value(t, launcher_pointer_step(&state, 45, LAUNCHER_LIST_Y+5,
        700, 760, false, false, true, false), -1)
}
