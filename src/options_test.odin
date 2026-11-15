package main

import "core:testing"

@(test)
backdrop_defaults_on_and_can_be_disabled_without_changing_window_filters :: proc(t: ^testing.T) {
    options := parse_options(nil)
    testing.expect(t, options.backdrop)
    options = parse_options([]string{"--workspace", "current", "--no-backdrop", "--monitor", "1"})
    testing.expect(t, !options.backdrop)
    testing.expect_value(t, options.filter.workspace, -2)
    testing.expect_value(t, options.filter.monitor, 1)
    options = parse_options([]string{"--no-backdrop", "--backdrop"})
    testing.expect(t, options.backdrop)
}
