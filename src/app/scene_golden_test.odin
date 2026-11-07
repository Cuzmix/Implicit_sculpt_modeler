package main

import "core:os"
import "core:strings"
import "core:testing"

import "../camera"
import "../geom"
import "../jobs"
import "../sculpt"
import "../voxel"

// Files written by earlier builds, kept so that a change to a reader that would refuse
// them fails here. They are never rewritten: a new field leaves them as they are and
// must still read them (the field takes its default), and only a change to SCENE_FORMAT
// or STROKES_FORMAT, which says old files are refused on purpose, replaces them.
//   scene-format-1-meshes.sculpt: two spheres with two levels and a recorded stroke
//     (build/sculpt --spheres=2 --vertices=642 --subdivide=1 --record-strokes
//      --bench-stroke=10 --frames=20 --save=... --save-strokes=strokes-format-1.strokes)
//   scene-format-1-voxel.sculpt: a voxel sphere (--voxels=32 --frames=5 --save=...)
//   scene-format-1-curves.sculpt: two curves, written by golden_files_written below
@(private = "file")
GOLDEN_DIR :: #directory + "testdata/golden/"

@(private = "file")
GOLDEN_SCENES := [?]string{"scene-format-1-meshes.sculpt", "scene-format-1-voxel.sculpt", "scene-format-1-curves.sculpt"}

// Every chunk of every kept scene reads: the header, the preview, the scene's fields, the
// references and each object (made needs a GPU, which tests do not have, so only read is
// asked for).
@(test)
golden_scenes_still_read :: proc(t: ^testing.T) {
	for name in GOLDEN_SCENES {
		path := strings.concatenate({GOLDEN_DIR, name}, context.temp_allocator)
		data, err := os.read_entire_file_from_path(path, context.allocator)
		testing.expectf(t, err == nil, "%s: %v", name, err)
		if err != nil do continue
		defer delete(data)
		app: App
		defer results_destroy(&app)
		jobs.pool_init(&app.pool, 2)
		defer jobs.pool_destroy(&app.pool)
		r := geom.byte_reader(data)
		testing.expectf(t, scene_head_read(&r), "%s: the header", name)
		testing.expectf(t, preview_block_skip(&r), "%s: the preview", name)
		tag, chunk, ok := scene_chunk_next(&r)
		testing.expectf(t, ok && tag == CHUNK_SCENE, "%s: no scene chunk first", name)
		f, fields_ok := scene_fields_get(&app, &chunk)
		scene_fields_destroy(&f)
		testing.expectf(t, fields_ok, "%s: the scene's fields", name)
		objects := 0
		for {
			next, body, more := scene_chunk_next(&r)
			if !more do break
			switch next {
			case CHUNK_REFS:
				refs, refs_ok := refs_get(&body)
				refs_free(&refs)
				testing.expectf(t, refs_ok, "%s: the references", name)
			case CHUNK_CURVE:
				obj, read, _ := object_get(&app, &body, nil, .Curve_Chunk)
				testing.expectf(t, read, "%s: curve %d did not read", name, objects)
				if obj != nil do object_discard(&app, obj)
				objects += 1
			case CHUNK_OBJECT:
				testing.expectf(t, golden_object_reads(&app, &body), "%s: object %d did not read", name, objects)
				objects += 1
			case:
				testing.expectf(t, false, "%s: a chunk %x this build does not write", name, next)
			}
		}
		testing.expectf(t, r.ok && r.at == len(data), "%s: bytes after the last chunk", name)
		testing.expectf(t, objects == f.count + f.curves && objects > 0, "%s: %d objects for %d and %d curves", name, objects, f.count, f.curves)
	}
}

// An object chunk's parts read as object_get reads them, short of the GPU upload, which
// tests have no device for: its fields, material and polygroup materials, and its levels,
// clay or cage.
@(private = "file")
golden_object_reads :: proc(app: ^App, r: ^geom.Byte_Reader) -> bool {
	rec := geom.record_take(r)
	known, _ := geom.record_known(&rec, Object_Tag)
	if !rec.ok || !known do return false
	obj := new(Object)
	defer object_discard(app, obj)
	object_get_fields(&rec, obj)
	kind := int(geom.rec_need(&rec, Object_Tag.Kind, u8))
	if mr, present := geom.rec_reader(&rec, Object_Tag.Material); present {
		obj.material = material_get(&mr, app, nil)
		if !mr.ok do return false
	}
	if gr, present := geom.rec_reader(&rec, Object_Tag.Group_Materials); present {
		group_materials_get(&gr, obj, app, nil)
		if !gr.ok do return false
	}
	switch kind {
	case OBJECT_KIND_VOXEL:
		vr, present := geom.rec_reader(&rec, Object_Tag.Voxel_Clay)
		clay: voxel.Clay
		defer voxel.clay_destroy(&clay)
		return present && geom.rec_need(&rec, Object_Tag.Voxel_Resolution, i32) >= VOXELS_MIN && voxel.clay_read(&clay, &vr, &app.pool)
	case OBJECT_KIND_CAGE:
		_, present := geom.rec_reader(&rec, Object_Tag.Cage)
		return present && rec.ok
	}
	lr, present := geom.rec_reader(&rec, Object_Tag.Levels)
	if !rec.ok || !present || !sculpt.levels_read(&obj.levels, &lr, &app.pool) do return false
	if sr, skin := geom.rec_reader(&rec, Object_Tag.Skin); skin && !sculpt.levels_skin_read(&obj.levels, &sr) do return false
	return len(obj.levels.levels) > 0
}

// The kept strokes file still loads.
@(test)
golden_strokes_still_read :: proc(t: ^testing.T) {
	app: App
	defer {
		take_destroy(&app.replay.take)
		results_destroy(&app)
	}
	testing.expect(t, strokes_load(&app, GOLDEN_DIR + "strokes-format-1.strokes"), "the strokes file did not load")
	testing.expect(t, len(app.replay.take.frames) > 0, "no frames")
}

// Writes the curve scene when SCULPT_GOLDEN=1 and it is not there yet; a kept file is never
// written over.
@(test)
golden_files_written :: proc(t: ^testing.T) {
	if os.get_env("SCULPT_GOLDEN", context.temp_allocator) != "1" do return
	path := GOLDEN_DIR + "scene-format-1-curves.sculpt"
	if os.exists(path) do return
	app: App
	defer {
		for obj in app.scene.objects do object_discard(&app, obj)
		delete(app.scene.objects)
		curve_tool_destroy(&app.curve)
		history_destroy(&app.history)
		results_destroy(&app)
	}
	app.camera = camera.orbit_default()
	app.scene.lights = app.start_lights
	a := []geom.Bezier_Point{{p = {0, 0, 0}, h_out = {0.1, 0, 0}, radius = 0.2, intensity = 1}, {p = {1, 0, 0}, h_in = {-0.1, 0, 0}, radius = 0.1, intensity = 0.5, twist = 0.3, handles = .Free}}
	b := []geom.Bezier_Point{{p = {0, 1, 0}, radius = 1, intensity = 1}, {p = {0, 2, 0}, radius = 1, intensity = 1}, {p = {1, 2, 0}, radius = 1, intensity = 1}}
	testing.expect(t, curve_object_add(&app, a, false))
	testing.expect(t, curve_object_add(&app, b, true))
	testing.expect(t, scene_save(&app, path))
}
