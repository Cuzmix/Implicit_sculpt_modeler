package main

import "core:path/filepath"

import "../hdri"
import "../sculpt"

// Capture VDM and Export VDM (the Alpha section): a stamp made from the selected slab,
// and the brush's VDM stamp written as an OpenEXR vector map for another app. The
// sculpting side is sculpt/vdm_capture.odin.

// Capture VDM: the selected object's upward faces become a new VDM alpha, named after
// `name`, kept in the library as an OpenEXR map in Blender's layout (as alpha_keep keeps a
// map from another app) and selected for the brush. The outcome becomes the file note.
vdm_capture_selected :: proc(app: ^App, name := "VDM capture") -> bool {
	obj := selected_object(app)
	if obj == nil || obj.voxel != nil {
		file_note(app, true, "Capture VDM needs a mesh object selected: sculpt a Plane (Scene > Add object) and capture it")
		return false
	}
	alpha, why := sculpt.vdm_capture(object_sculptor(obj))
	if why != "" {
		file_note(app, true, "Cannot capture a VDM from %s: %s", object_label(obj), why)
		return false
	}
	if app.library.folder == "" {
		app.brush.alpha = alpha_add(app, name, name, alpha)
		file_note(app, false, "Captured VDM %s from %s, for this run only (it keeps no library)", name, object_label(obj))
		return true
	}
	data := vdm_exr(&alpha, .Blender)
	i, failed := library_keep(app, name, "", data, alpha)
	app.brush.alpha = i
	if failed != "" {
		file_note(app, true, "Captured VDM %s from %s, for this run only: the library could not keep a copy (%s)", app.alphas[i].name, object_label(obj), failed)
	} else {
		file_note(app, false, "Captured VDM %s from %s, %d by %d, and kept it in your library", app.alphas[i].name, object_label(obj), alpha.size, alpha.size)
	}
	return true
}

// Export VDM: the brush's VDM alpha goes to `path` as an OpenEXR map laid out for the app
// VDM files from names, so that app reads it back as the same stamp.
vdm_export :: proc(app: ^App, path: string) -> bool {
	a := brush_alpha(app)
	if a == nil || a.vectors == nil {
		file_note(app, true, "Export VDM needs a VDM stamp picked as the brush's alpha")
		return false
	}
	if failed := write_durably(path, vdm_exr(a, app.vdm_axes)); failed != "" {
		file_note(app, true, "Cannot export VDM to %s: %s", filepath.base(path), failed)
		return false
	}
	file_note(app, false, "Exported VDM %s, %d by %d, for %s", filepath.base(path), a.size, a.size, sculpt.VDM_AXES_NAMES[app.vdm_axes])
	return true
}

// The OpenEXR file of a VDM alpha's offsets in `axes`' layout, in the temp allocator.
@(private = "file")
vdm_exr :: proc(a: ^sculpt.Alpha, axes: sculpt.Vdm_Axes) -> []u8 {
	pixels := make([][3]f32, len(a.vectors), context.temp_allocator)
	for v, i in a.vectors do pixels[i] = sculpt.vdm_to_file(v, axes)
	return hdri.exr_encode(pixels, a.size, a.size, context.temp_allocator)
}
