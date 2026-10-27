package main

import "core:testing"

import "../sculpt"
import "../voxel"

// The size presets map to whole mesh nodes of resolution, more vertices to more voxels,
// within the range a voxel sphere can be.
@(test)
voxel_resolution_follows_the_size_presets :: proc(t: ^testing.T) {
	last := 0
	for p in SPHERE_PRESETS {
		r := voxel_resolution_for(int(p.vertices))
		testing.expectf(t, r % voxel.NODE == 0, "%s: %d is not whole nodes", p.label, r)
		testing.expectf(t, r >= VOXELS_MIN && r <= VOXELS_MAX, "%s: %d is out of range", p.label, r)
		testing.expectf(t, r >= last, "%s: %d is below the smaller size's %d", p.label, r, last)
		last = r
	}
	// The bench's measured rows: 256 across meshes to about 347k vertices.
	testing.expect_value(t, voxel_resolution_for(347_000), 256)
	testing.expect_value(t, voxel_resolution_for(10), VOXELS_MIN)
	testing.expect_value(t, voxel_resolution_for(100_000_000), VOXELS_MAX)
}

// Only the brushes with a meaning on a volume become voxel brushes, each as the kind that
// does the same thing; a brush that is refused is refused at the press too.
@(test)
voxel_brushes_stand_for_the_mesh_brushes_that_have_a_meaning_on_clay :: proc(t: ^testing.T) {
	cases := [?]struct {
		kind:  sculpt.Brush_Kind,
		voxel: voxel.Brush_Kind,
		ok:    bool,
	}{
		{.Draw, .Add, true}, {.Clay, .Add, true}, {.Layer, .Add, true}, {.Smooth, .Smooth, true},
		{.Flatten, .Flatten, true}, {.Inflate, .Inflate, true},
		{.Grab, .Add, false}, {.Mask, .Add, false}, {.Pinch, .Add, false}, {.Paint, .Add, false}, {.Cloth, .Add, false},
	}
	for c in cases {
		vb, ok := voxel_brush_of({kind = c.kind, radius = 0.1, strength = 0.5, invert = true}, {0, 0, 1})
		testing.expectf(t, ok == c.ok, "%v: %v", c.kind, ok)
		if !ok do continue
		testing.expect_value(t, vb.kind, c.voxel)
		testing.expect(t, vb.invert && vb.radius == 0.1 && vb.strength == 0.5 && vb.normal == {0, 0, 1})
	}
}

// A voxel object's Object palette offers its placement and its Voxels section only; a
// mesh object's offers every section, and the Voxels section is on one page.
@(test)
voxel_objects_offer_transform_and_voxels_only :: proc(t: ^testing.T) {
	app: App
	part: Voxel_Part
	clay, mesh := Object{id = 1, voxel = &part}, Object{id = 2}
	append(&app.scene.objects, &clay, &mesh)
	defer delete(app.scene.objects)
	app.scene.selected = 0
	for s in OBJECT_SECTIONS {
		want := s.section == .Transform || s.section == .Voxels
		testing.expectf(t, object_section_offered(&app, s.section) == want, "%v offered to a voxel object: %v", s.section, !want)
	}
	app.scene.selected = 1
	for s in OBJECT_SECTIONS do testing.expectf(t, object_section_offered(&app, s.section), "%v not offered to a mesh", s.section)
	testing.expect(t, MESH_ONLY_COMMANDS & {.Add, .Delete, .Duplicate, .Copy, .Paste, .View, .Arrange, .Voxel_To_Mesh} == {})
	testing.expect(t, .Remesh in MESH_ONLY_COMMANDS && .Subdivide in MESH_ONLY_COMMANDS && .Boolean in MESH_ONLY_COMMANDS)
}
