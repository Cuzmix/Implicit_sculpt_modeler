package main

import "core:testing"

import "../sculpt"

// The context bar keeps its own short lists for the mask and hidden parts, with Extract
// and Delete hidden in them; the other groups keep theirs whole.
@(test)
context_bar_lists_are_round_twos :: proc(t: ^testing.T) {
	a: App
	defer results_destroy(&a)
	mask := action_list(&a, .Mask)
	testing.expect_value(t, mask[0], Action{.Mask, int(sculpt.Mask_Command.Invert), "Invert"})
	testing.expect_value(t, mask[len(mask) - 1].id, Command_Id.Extract_Masked)
	hidden := action_list(&a, .Hidden)
	testing.expect_value(t, hidden[len(hidden) - 1].id, Command_Id.Delete_Hidden)
	testing.expect_value(t, len(action_list(&a, .Gizmo)), len(ACTION_GROUPS[.Gizmo].actions))
}

// Every tile of the Tools card's grids runs a command of the registry, with an icon, and
// no grid shows the same command twice.
@(test)
tool_tiles_are_registry_commands :: proc(t: ^testing.T) {
	grids := [][]Tool_Tile{MASK_TILES[:], VISIBILITY_TILES[:], REPAIR_TILES[:]}
	for grid in grids {
		for tile, i in grid {
			testing.expect(t, tile.id != .None && COMMANDS[tile.id].run != nil, tile.label)
			testing.expect(t, tile.glyph != 0, tile.label)
			testing.expect(t, COMMANDS[tile.id].args == 0 || tile.arg < COMMANDS[tile.id].args, tile.label)
			for other in grid[i + 1:] do testing.expect(t, other.id != tile.id || other.arg != tile.arg, tile.label)
		}
	}
}

// Show the mask off asks the shader to draw masked parts as the rest, whether or not the
// viewport's style is on.
@(test)
show_the_mask_goes_to_the_style :: proc(t: ^testing.T) {
	a: App
	testing.expect_value(t, viewport_style(&a).z, 0)
	a.ui.mask_hidden = true
	testing.expect_value(t, viewport_style(&a), [4]f32{0, 0, 1, 0})
	a.styled, a.rim = true, 0.5
	style := viewport_style(&a)
	testing.expect(t, style.z == 1 && style.w == 1)
}
