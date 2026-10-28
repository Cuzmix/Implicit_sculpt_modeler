package main

import "core:strings"
import "core:testing"

// The built-in Inspect workspace gives its four panes the whole window: no floating or
// docked panels, the brush bar and dock hidden.
@(test)
inspect_built_in_opens_no_panels :: proc(t: ^testing.T) {
	text := built_in_layout(.Inspect)
	testing.expect(t, !strings.contains(text, "pinned"), text)
	testing.expect(t, !strings.contains(text, "column"), text)
	testing.expect(t, strings.contains(text, "panes "), text)
	testing.expect(t, strings.contains(text, "hidden Brush_Bar Dock"), text)
}
