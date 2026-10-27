package main

import "core:math"
import "core:os"
import "core:strings"
import "core:testing"

import "../geom"

// The printed positions go through the placement into millimetres, turn Y up into Z up
// and stand centred on the bed.
@(test)
print_positions_stand_on_the_bed :: proc(t: ^testing.T) {
	positions := []Vec3{{-1, 0, -1}, {1, 0, -1}, {0, 2, 1}}
	at := print_positions(positions, {position = {5, 7, 9}, scale = 2}, 10)
	b := geom.AABB_EMPTY
	for p in at do geom.aabb_grow(&b, p)
	near :: proc(a, b: f32) -> bool {return math.abs(a - b) < 1e-3}
	testing.expectf(t, near(b.lo.z, 0) && near(b.hi.z, 40), "the up side, %v to %v, is not 0 to 40 mm", b.lo.z, b.hi.z)
	testing.expectf(t, near(b.lo.x, -20) && near(b.hi.x, 20) && near(b.lo.y, -20) && near(b.hi.y, 20), "not centred: %v", b)
	// The scene's front (+Z, toward the viewer) is the printer's -Y.
	testing.expect(t, at[2].y < at[0].y, "the front did not turn to -Y")
	free_all(context.temp_allocator)
}

// Dragging a side sets the scene's scale, and the file written has that size, closed,
// on the bed; a name not ending in .stl is refused.
@(test)
print_export_writes_the_size_set :: proc(t: ^testing.T) {
	FOLDER :: "build/print_test/"
	_ = os.remove_all(FOLDER)
	defer os.remove_all(FOLDER)
	testing.expect(t, os.make_directory_all(FOLDER) == nil)
	// Not temporary: an export frees the temporary allocator, as the frame does.
	path := strings.clone(FOLDER + "print.stl")
	defer delete(path)

	app: App
	defer tree_free(&app)
	objs := tree_scene(&app)
	obj := objs[0]
	obj.transform.scale = 2
	size := print_size_mm(&app, obj)
	testing.expectf(t, math.abs(size.y - 4 * PRINT_MM_DEFAULT) < 0.01, "a sphere 4 units across prints %v mm high", size.y)
	testing.expect(t, print_set_side(&app, obj, 1, 120))
	testing.expect(t, math.abs(print_scale(&app) - 30) < 1e-3, "the scale does not give 120 mm")
	testing.expect(t, !print_set_side(&app, obj, 1, 120), "the same size again changed something")
	testing.expect(t, !print_set_side(&app, obj, 1, 0))

	if !testing.expect(t, object_export(&app, obj, path, print = true)) do return
	testing.expect_value(t, app.print_exports, 1)
	data, read_err := os.read_entire_file(path, context.allocator)
	defer delete(data)
	if !testing.expect(t, read_err == nil) do return
	m, err, _ := geom.mesh_read_stl(data, nil)
	defer geom.mesh_destroy(&m)
	if !testing.expect_value(t, err, geom.Mesh_File_Error.None) do return
	// STL repeats each corner, so the import's weld joins them first.
	_, clean_err := geom.mesh_clean(&m, nil)
	testing.expect_value(t, clean_err, geom.Mesh_File_Error.None)
	r := geom.mesh_check(m)
	testing.expect(t, r.closed && !r.inverted, "the printed sphere is not closed and outward")
	b := r.bounds
	testing.expectf(t, math.abs(b.hi.z - b.lo.z - 120) < 0.5 && math.abs(b.lo.z) < 1e-3, "printed %v to %v mm high", b.lo.z, b.hi.z)

	testing.expect(t, !object_export(&app, obj, FOLDER + "print.obj", print = true), "a print went to an OBJ")
	free_all(context.temp_allocator)
}
