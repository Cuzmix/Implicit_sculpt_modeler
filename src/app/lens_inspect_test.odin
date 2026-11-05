package main

import "core:strings"
import "core:testing"

// Inspect gives its four panes the whole window, the brush bar and dock aside, and puts
// the view back when it ends; the layout, and so the space's dot, stays as it was.
@(test)
inspect_shows_four_panes_and_leaves_the_layout :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	k := new(Kit_State)
	defer free(k)
	bars_reset(k)
	panels_default(k)
	layouts_init(k)
	defer layouts_destroy(k)
	layouts_frame(k)
	before := strings.clone(kit_layout_text(k), context.temp_allocator)
	inspect_set(k, true)
	testing.expect_value(t, grid_panes(&k.grid), 4)
	testing.expect(t, zone_hidden(k, .Brush_Bar) && zone_hidden(k, .Dock) && !zone_hidden(k, .View_Bar))
	testing.expect(t, k.hidden == {}, "Inspect changed the layout's hidden bars")
	testing.expect(t, kit_layout_text(k) == before, "Inspect changed the layout")
	layouts_frame(k)
	testing.expect(t, !k.layouts.modified, "Inspect lit the space's dot")
	inspect_set(k, false)
	testing.expect_value(t, grid_panes(&k.grid), 1)
	testing.expect(t, !zone_hidden(k, .Dock))

	// Focus hides the side bars the same way.
	k.focus_mode = true
	testing.expect(t, zone_hidden(k, .Brush_Bar) && zone_hidden(k, .View_Bar) && zone_hidden(k, .Action_Bar))
	testing.expect(t, lens_focus(k))
	layouts_frame(k)
	testing.expect(t, !k.layouts.modified, "Focus lit the space's dot")
	// A layout put in place ends both.
	inspect_set(k, true)
	kit_layout_put(k, built_in_layout(.Model))
	testing.expect(t, !k.focus_mode && !k.inspect.on)
}
