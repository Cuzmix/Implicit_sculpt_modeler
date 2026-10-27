package main

import "core:fmt"
import "core:strings"
import "core:time"

import "../camera"
import "../geom"
import "../sculpt"

// The Mask section's Mask by and Mask adjust on the app side: what they are set to, and
// the commands that run them on the selected object as undo steps of their own
// (sculpt.sculptor_mask_by, sculpt.sculptor_mask_adjust).

Mask_By_Settings :: struct {
	kind:          sculpt.Mask_By, // the one the section's Apply runs
	strength:      f32, // Peaks, Curvature and Smoothness: how much the shape counts, 0 to 1
	blur:          i32, // Blur steps after, 0 to MASK_BY_BLUR_MAX
	curve:         geom.Curve, // the profile the measure goes through
	adjust_curve:  geom.Curve, // Mask adjust's curve, from the mask as it is to the new one
	adjust_blur:   i32,
	curve_handle:  int, // which of the profile's points a drag holds
	adjust_handle: int, // ...and of the adjust curve's
}

MASK_BY_SETTINGS_DEFAULT :: Mask_By_Settings {
	strength     = 0.5,
	curve        = geom.CURVE_LINEAR,
	adjust_curve = geom.CURVE_LINEAR,
	curve_handle = -1,
	adjust_handle = -1,
}

// The most Blur steps either takes: on a large mesh a measure leaves almost every node to
// blur, so each step is a full pass (about 0.1 s at 10M vertices).
MASK_BY_BLUR_MAX :: 5

// Each kind's step, as the History panel and the result line name it (History_Entry.what
// keeps it, so it is a constant).
@(rodata)
MASK_BY_NAMES := [sculpt.Mask_By]string {
	.Peaks            = "Mask by peaks",
	.Curvature        = "Mask by curvature",
	.Smoothness       = "Mask by smoothness",
	.Depth            = "Mask by depth",
	.Facing_Away      = "Mask by facing away",
	.Color_Intensity  = "Mask by colour intensity",
	.Color_Hue        = "Mask by colour hue",
	.Color_Saturation = "Mask by colour saturation",
	.Open_Borders     = "Mask by open borders",
	.Group_Borders    = "Mask by group borders",
	.Creases          = "Mask by creases",
}

// What each kind masks, for the section under its picker.
@(rodata)
MASK_BY_HELP := [sculpt.Mask_By]string {
	.Peaks            = "Masks the crests, more the higher they stand above what is around them.",
	.Curvature        = "Masks where the surface bends sharply, crests and dips alike.",
	.Smoothness       = "Masks the flat and gently curved parts, and leaves the detail.",
	.Depth            = "Masks what is near you fully and what is far not at all, through the curve.",
	.Facing_Away      = "Masks what faces away from you; edge-on parts half.",
	.Color_Intensity  = "Masks by how light the polypaint is.",
	.Color_Hue        = "Masks the polypaint near the main brush colour's hue.",
	.Color_Saturation = "Masks by how vivid the polypaint is.",
	.Open_Borders     = "Masks the edges of holes and of the shown part.",
	.Group_Borders    = "Masks where polygroups meet.",
	.Creases          = "Masks edges sharper than the Polygroups section's Angle.",
}

// Masks the selected object by `by` as an undo step of its own, with the Mask section's
// curve, strength and blur, the camera's view, the main brush colour and the crease angle.
mask_by_command :: proc(app: ^App, by: sculpt.Mask_By) {
	stroke_finish(app)
	obj := selected_object(app)
	if obj == nil do return
	name := MASK_BY_NAMES[by]
	#partial switch by {
	case .Color_Intensity, .Color_Hue, .Color_Saturation, .Group_Borders:
		// Polypaint and groups live on a level's own vertices.
		if !paint_allowed(obj) do return
	}
	set := app.ui.mask_by
	t := obj.transform
	o := sculpt.Mask_By_Options {
		strength = set.strength,
		curve    = set.curve,
		blur     = int(clamp(set.blur, 0, MASK_BY_BLUR_MAX)),
		view     = {parallel = app.camera.ortho, eye = to_local(t, camera.orbit_eye(app.camera)), toward = to_local_dir(t, -camera.orbit_toward(app.camera, app.camera.target))},
		hue      = brush_color_bytes(app),
		width    = sculpt.MASK_BY_DEFAULT.width,
		angle    = app.ui.crease_degrees,
	}
	start := time.tick_now()
	changed := sculpt.sculptor_mask_by(object_sculptor(obj), by, o)
	ms := time.duration_milliseconds(time.tick_since(start))
	if changed do history_record(app, obj, .Mask, name)
	why := ""
	if !changed {
		#partial switch by {
		case .Color_Intensity, .Color_Saturation: why = ": it has no polypaint"
		case .Color_Hue:                         why = ": it has no polypaint, or the main colour is grey"
		case .Group_Borders:                     why = ": it has no polygroups"
		}
	}
	report(app, Kit_Section.Mask, {.Quiet}, "%s in %.0f ms%s%s", name, ms, "" if changed else ", nothing changed", why)
}

// Reshapes the selected object's mask through the Mask section's adjust curve and blur,
// as an undo step of its own.
mask_adjust_command :: proc(app: ^App) {
	stroke_finish(app)
	obj := selected_object(app)
	if obj == nil do return
	set := app.ui.mask_by
	start := time.tick_now()
	changed := sculpt.sculptor_mask_adjust(object_sculptor(obj), set.adjust_curve, int(clamp(set.adjust_blur, 0, MASK_BY_BLUR_MAX)))
	ms := time.duration_milliseconds(time.tick_since(start))
	if changed do history_record(app, obj, .Mask, "Mask adjust")
	report(app, Kit_Section.Mask, {.Quiet}, "Mask adjust in %.0f ms%s", ms, "" if changed else ", nothing changed")
}

// The Mask by kind as the picker shows it: its name with a capital.
mask_by_label :: proc(by: sculpt.Mask_By) -> string {
	name := strings.trim_prefix(MASK_BY_NAMES[by], "Mask by ")
	return fmt.tprintf("%s%s", strings.to_upper(name[:1], context.temp_allocator), name[1:])
}

// The Mask by kind as a word, for the settings file and the exit stats.
mask_by_word :: proc(by: sculpt.Mask_By) -> string {
	return strings.to_lower(fmt.tprint(by), context.temp_allocator)
}
