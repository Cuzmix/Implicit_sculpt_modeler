package main

import "core:testing"

// Every verb in the table is a real command with an argument it takes and a label to show,
// and each type has its own verbs where it is worked on (a mesh and clay in Sculpt, a cage
// in Model) and something to offer from the other of the two.
@(test)
object_verbs_are_commands_that_run :: proc(t: ^testing.T) {
	for kind in Object_Type {
		for space in Space {
			for v in OBJECT_VERBS[kind][space] {
				testing.expect(t, v.id != .None)
				args := COMMANDS[v.id].args
				testing.expectf(t, v.arg >= 0 && v.arg < max(args, 1), "%v: arg %d of %d", v.id, v.arg, args)
				testing.expect(t, (v.label if v.label != "" else command_label(v.id, v.arg)) != "")
			}
		}
		testing.expect(t, len(OBJECT_VERBS[kind][.Sculpt]) > 0 && len(OBJECT_VERBS[kind][.Model]) > 0)
		conv := OBJECT_CONVERSIONS[kind]
		testing.expect(t, conv.id != .None && conv.arg < max(COMMANDS[conv.id].args, 1))
	}
}

// The menu's type is what the chip says the object is.
@(test)
object_type_matches_the_chip :: proc(t: ^testing.T) {
	for kind in Object_Type do testing.expect(t, OBJECT_TYPE_NAMES[kind] != "" && OBJECT_TYPE_ICONS[kind] != 0)
	testing.expect_value(t, OBJECT_TYPE_NAMES[.Sculpt_Mesh], "Sculpt mesh")
	testing.expect_value(t, OBJECT_TYPE_NAMES[.Voxel_Clay], "Voxel clay")
	testing.expect_value(t, OBJECT_TYPE_NAMES[.Cage], "Cage")
	testing.expect_value(t, OBJECT_TYPE_NAMES[.Curve], "Curve")
}
