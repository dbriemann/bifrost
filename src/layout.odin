package main

GRID_GAP :: CELL_WIDTH-TILE_WIDTH
GRID_ROW_GAP :: 12
GRID_FOOTER :: 48

Grid_Layout :: struct {
    cols, rows, capacity, pages, page, visible: int,
    width, height, tile_height, cell_height: int,
}

grid_footer_height :: proc(cols: int, paginated: bool) -> int {
    return GRID_FOOTER + (22 if cols == 1 else 0) + (22 if paginated else 0)
}

grid_rows_that_fit :: proc(cols, count, tile_height, available_height: int) -> int {
    step := tile_height+GRID_ROW_GAP
    footer := grid_footer_height(cols, false)
    rows := clamp((available_height-GRID_Y-footer+GRID_ROW_GAP)/step, 1, 6)
    if count > min(len(KEYS), cols*rows) {
        footer = grid_footer_height(cols, true)
        rows = clamp((available_height-GRID_Y-footer+GRID_ROW_GAP)/step, 1, 6)
    }
    return rows
}

// Prefer equal row/column counts; on ties use fewer empty cells, then a wider
// grid. Fit the current view, never reserve space for another view's windows.
grid_layout :: proc(count, tile_height, available_width, available_height: int, page := 0) -> Grid_Layout {
    max_cols := clamp((available_width-2*GRID_X+GRID_GAP)/CELL_WIDTH, 1, 6)
    max_capacity := 1
    for cols in 1..=max_cols {
        max_capacity = max(max_capacity,
            min(len(KEYS), cols*grid_rows_that_fit(cols, count, tile_height, available_height)))
    }
    target := clamp(count, 1, max_capacity)
    best_cols, best_rows, best_difference, best_empty := 1, target, 1000, 1000
    for cols in 1..=min(max_cols, target) {
        rows := (target+cols-1)/cols
        if rows > grid_rows_that_fit(cols, count, tile_height, available_height) { continue }
        difference, empty := abs(cols-rows), cols*rows-target
        if difference < best_difference ||
            difference == best_difference && (empty < best_empty || empty == best_empty && cols > best_cols) {
            best_cols, best_rows, best_difference, best_empty = cols, rows, difference, empty
        }
    }
    result := Grid_Layout{cols=best_cols, capacity=best_cols*best_rows,
        tile_height=tile_height, cell_height=tile_height+GRID_ROW_GAP}
    result.pages = max(1, (count+result.capacity-1)/result.capacity)
    result.page = clamp(page, 0, result.pages-1)
    result.visible = min(result.capacity, max(0, count-result.page*result.capacity))
    result.rows = (result.visible+result.cols-1)/result.cols
    result.width = 2*GRID_X + (result.cols-1)*CELL_WIDTH + TILE_WIDTH
    body := (result.rows-1)*result.cell_height+tile_height if result.rows > 0 else 48
    result.height = GRID_Y+body+grid_footer_height(result.cols, result.pages > 1)
    return result
}
