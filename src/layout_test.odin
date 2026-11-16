package main

import "core:testing"

@(test)
grid_balances_rows_and_columns_for_the_current_item_count :: proc(t: ^testing.T) {
    cases := [][3]int{{1,1,1}, {2,2,1}, {3,2,2}, {4,2,2}, {5,3,2},
        {7,3,3}, {8,3,3}, {9,3,3}, {10,4,3}, {13,4,4}, {20,5,4}, {36,6,6}}
    for example in cases {
        layout := grid_layout(example[0], 154, 1600, 1600)
        testing.expect_value(t, layout.cols, example[1])
        testing.expect_value(t, layout.rows, example[2])
        testing.expect_value(t, layout.visible, example[0])
        testing.expect_value(t, layout.pages, 1)
    }
}

@(test)
grid_window_fits_content_and_does_not_reserve_other_views_or_empty_page_rows :: proc(t: ^testing.T) {
    root := grid_layout(7, 154, 1400, 1000)
    testing.expect_value(t, root.width, 692)
    testing.expect_value(t, root.height, 628)
    child := grid_layout(2, 222, 1400, 1000)
    testing.expect_value(t, child.cols, 2)
    testing.expect_value(t, child.rows, 1)
    testing.expect_value(t, child.height, GRID_Y+222+GRID_FOOTER+FOOTER_LINE_HEIGHT)
    restored := grid_layout(7, 154, 1400, 1000)
    testing.expect_value(t, restored.width, root.width)
    testing.expect_value(t, restored.height, root.height)
    first := grid_layout(37, 154, 1400, 750)
    last := grid_layout(37, 154, 1400, 750, first.pages-1)
    testing.expect_value(t, first.capacity, last.capacity)
    testing.expect_value(t, first.cols, last.cols)
    testing.expect(t, last.rows < first.rows && last.height < first.height)
    selected := cycle_selection(0, 37, true)
    testing.expect_value(t, selected/last.capacity, last.page)
    testing.expect(t, selected-last.page*last.capacity < last.visible)
}

@(test)
grid_fits_small_monitors_and_keeps_paged_hit_targets_aligned :: proc(t: ^testing.T) {
    for tile_height in ([3]int{154, 188, 222}) {
        for width in ([4]int{268, 472, 692, 1400}) {
            for height in ([3]int{GRID_Y+222+grid_footer_height(1, true), 600, 1000}) {
                for count in ([12]int{0, 1, 2, 3, 7, 10, 17, 35, 36, 37, 40, 73}) {
                    first := grid_layout(count, tile_height, width, height)
                    testing.expect(t, first.capacity > 0 && first.capacity <= len(KEYS))
                    seen := 0
                    for page in 0..<first.pages {
                        layout := grid_layout(count, tile_height, width, height, page)
                        testing.expect(t, layout.width <= width && layout.height <= height)
                        testing.expect_value(t, layout.capacity, first.capacity)
                        testing.expect_value(t, layout.cols, first.cols)
                        for local in 0..<layout.visible {
                            x := f32(GRID_X+(local%layout.cols)*CELL_WIDTH+TILE_WIDTH/2)
                            y := f32(GRID_Y+(local/layout.cols)*layout.cell_height+tile_height/2)
                            target := pointer_target(x, y, layout.cols, layout.capacity, count, page, false,
                                tile_height=tile_height, cell_height=layout.cell_height)
                            testing.expect_value(t, target, seen)
                            seen += 1
                        }
                        footer_y := f32(layout.height-20)
                        testing.expect_value(t, pointer_target(60, footer_y, layout.cols, layout.capacity,
                            count, page, false, tile_height=tile_height, cell_height=layout.cell_height), -1)
                    }
                    testing.expect_value(t, seen, count)
                }
            }
        }
    }
}
