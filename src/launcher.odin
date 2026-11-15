package main

import "core:strings"
import "core:unicode"
import "core:unicode/utf8"

LAUNCHER_LIMIT :: 10
Launcher_App :: struct {
    id, name, description, keywords, executable: string,
}
App_Catalogue :: struct { version: int, apps: []Launcher_App }
Search_Result :: struct { index, score: int }
Launcher :: struct {
    apps: []Launcher_App,
    query: [dynamic]rune,
    cursor, selected, top: int,
    results: [dynamic]Search_Result,
    error, catalogue_error: string,
    pointer: Pointer_Gesture,
}

// Optimal subsequence alignment: reward word starts and adjacent letters, and
// penalize gaps. Prefixes and exact matches get additional bonuses.
fuzzy_score :: proc(candidate, query: string) -> (int, bool) {
    lower := strings.to_lower(candidate, context.temp_allocator)
    needle := strings.to_lower(strings.trim_space(query), context.temp_allocator)
    hay := utf8.string_to_runes(lower, context.temp_allocator)
    raw_query := utf8.string_to_runes(needle, context.temp_allocator)
    q := make([dynamic]rune, allocator=context.temp_allocator)
    for r in raw_query { if !unicode.is_space(r) { append(&q, r) } }
    if len(q) == 0 { return 0, true }
    if len(q) > len(hay) { return 0, false }
    // Desktop metadata is short; cap extremely long descriptions for predictable
    // per-keystroke cost without truncating ordinary application names.
    if len(hay) > 512 { hay = hay[:512] }
    invalid :: -1_000_000
    previous := make([]int, len(hay), context.temp_allocator)
    current := make([]int, len(hay), context.temp_allocator)
    for &v in previous { v = invalid }
    for wanted, i in q {
        best := invalid
        for r, j in hay {
            current[j] = invalid
            boundary := j == 0 || !unicode.is_letter(hay[j-1]) && !unicode.is_digit(hay[j-1])
            bonus := 16 + (18 if boundary else 0)
            if r == wanted {
                if i == 0 { current[j] = bonus - 2*j }
                else {
                    if best > invalid { current[j] = best - 2*j + bonus }
                    if j > 0 && previous[j-1] > invalid {
                        current[j] = max(current[j], previous[j-1] + bonus + 24)
                    }
                }
            }
            if previous[j] > invalid { best = max(best, previous[j]+2*j) }
        }
        previous, current = current, previous
    }
    score := invalid
    for value in previous { score = max(score, value) }
    if score == invalid { return 0, false }
    if lower == needle { score += 400 }
    else if strings.has_prefix(lower, needle) { score += 120 }
    else if strings.contains(lower, needle) { score += 50 }
    return score - len(hay)/8, true
}

result_before :: proc(a, b: Search_Result, apps: []Launcher_App) -> bool {
    if a.score != b.score { return a.score > b.score }
    an := strings.to_lower(apps[a.index].name, context.temp_allocator)
    bn := strings.to_lower(apps[b.index].name, context.temp_allocator)
    if an != bn { return an < bn }
    return apps[a.index].id < apps[b.index].id
}

search_apps :: proc(apps: []Launcher_App, query: string) -> [dynamic]Search_Result {
    results := make([dynamic]Search_Result)
    seen := make(map[string]bool, allocator=context.temp_allocator)
    empty := strings.trim_space(query) == ""
    for app, index in apps {
        if app.id == "" || app.name == "" || seen[app.id] { continue }
        seen[app.id] = true
        best, matched := 0, empty
        if !empty {
            fields := [5]string{app.name, app.executable, app.keywords, app.id, app.description}
            weights := [5]int{300, 160, 80, 40, 0}
            for field, i in fields {
                score, ok := fuzzy_score(field, query)
                if ok {
                    if !matched { best = score+weights[i] }
                    else { best = max(best, score+weights[i]) }
                    matched = true
                }
            }
        }
        if !matched { continue }
        result := Search_Result{index, best}
        at := len(results)
        for existing, i in results { if result_before(result, existing, apps) { at = i; break } }
        if at >= LAUNCHER_LIMIT { continue }
        append(&results, result)
        for i := len(results)-1; i > at; i -= 1 { results[i] = results[i-1] }
        results[at] = result
        if len(results) > LAUNCHER_LIMIT { resize(&results, LAUNCHER_LIMIT) }
    }
    return results
}

launcher_refresh :: proc(state: ^Launcher) {
    delete(state.results)
    query := utf8.runes_to_string(state.query[:], context.temp_allocator)
    state.results = search_apps(state.apps, query)
    state.selected, state.top = 0, 0
    state.pointer = {}
    state.error = state.catalogue_error
}

launcher_insert :: proc(state: ^Launcher, value: rune) -> bool {
    if value < 32 || value == 127 || len(state.query) >= 256 { return false }
    append(&state.query, value)
    for i := len(state.query)-1; i > state.cursor; i -= 1 { state.query[i] = state.query[i-1] }
    state.query[state.cursor] = value
    state.cursor += 1
    return true
}

launcher_backspace :: proc(state: ^Launcher) -> bool {
    if state.cursor <= 0 { return false }
    copy(state.query[state.cursor-1:], state.query[state.cursor:])
    resize(&state.query, len(state.query)-1)
    state.cursor -= 1
    return true
}

launcher_delete :: proc(state: ^Launcher) -> bool {
    if state.cursor >= len(state.query) { return false }
    copy(state.query[state.cursor:], state.query[state.cursor+1:])
    resize(&state.query, len(state.query)-1)
    return true
}
