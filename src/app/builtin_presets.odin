package main

import "core:strings"

import "../sculpt"

// The built-in presets: the brushes a sculptor coming from the reference app looks for in
// its library by name, each a preset over one of our brushes (presets.odin). They are
// read-only as a pack's are, and numbered from BUILT_IN_PRESET, between the person's own
// and the packs' (PACK_PRESET), so the dock, the brush and settings.txt hold them as they
// hold any preset; settings.txt names them by name, as the person's own.

BUILT_IN_PRESET :: 1 << 15

// One row of the library: the brush and what differs from it as a fresh install has it.
Built_In_Preset :: struct {
	name:        string,
	kind:        sculpt.Brush_Kind,
	strength:    f32,
	focal:       f32, // focal shift (sculpt.FOCAL_MIN to FOCAL_MAX)
	alpha:       Maybe(sculpt.Alpha_Shape),
	lock_plane:  bool,
	connected:   bool,
	grab_depth:  bool,
	smooth_only: sculpt.Smooth_Only,
	topological: bool, // Grab's falloff along the surface
	one_way:     bool, // the stroke's No back and forth
	// Flatten's plane height and depth, 0 to 1; both 0 here mean a fresh brush's 1.
	plane:       [2]f32,
	// The Cloth brush's mode and what differs from sculpt.CLOTH_DEFAULTS: the region,
	// Gravity, Firmness (0 here means the default) and Allow expand.
	cloth_mode:   sculpt.Cloth_Mode,
	region:       sculpt.Cloth_Region,
	gravity:      f32,
	firmness:     f32,
	allow_expand: bool,
	// The Physics switch on, at its default strength: a brush that moves the surface as cloth.
	physics:      bool,
}

// Appended to only, as a dock slot read from an older settings file finds its preset by
// name and a script by name too.
@(rodata)
BUILT_IN_PRESETS := [?]Built_In_Preset {
	{name = "Standard", kind = .Draw, strength = 0.5},
	{name = "Sharp crease", kind = .Crease, strength = 0.6, focal = 45},
	{name = "Clay buildup", kind = .Clay, strength = 0.6, alpha = .Square},
	{name = "Move", kind = .Grab, strength = 0.5},
	{name = "Move connected", kind = .Grab, strength = 0.5, connected = true},
	{name = "Move all depth", kind = .Grab, strength = 0.5, grab_depth = true},
	{name = "Hard polish", kind = .Flatten, strength = 0.5, focal = -60, lock_plane = true},
	{name = "Trim", kind = .Flatten, strength = 0.4, focal = -35},
	{name = "Blob", kind = .Inflate, strength = 0.4, alpha = .Noise},
	{name = "Slash", kind = .Crease, strength = 0.7, focal = 75},
	{name = "Smooth stronger", kind = .Smooth, strength = 1},
	{name = "Smooth valleys", kind = .Smooth, strength = 0.8, smooth_only = .Valleys},
	{name = "Smooth peaks", kind = .Smooth, strength = 0.8, smooth_only = .Peaks},
	{name = "Move topological", kind = .Grab, strength = 0.5, topological = true},
	// Fine parallel grooves from a zigzag, as ZBrush's No back and forth is used for.
	{name = "Hatch", kind = .Crease, strength = 0.5, focal = 40, one_way = true},
	// Blender's Plane brush halves: Fill only raises the dips, Scrape only cuts the bumps.
	{name = "Fill", kind = .Flatten, strength = 0.5, plane = {0, 1}},
	{name = "Scrape", kind = .Flatten, strength = 0.5, plane = {1, 0}},
	// ZBrush's cloth brushes (its Dynamics family), each a Cloth mode or a moving brush
	// with Physics on, named as there with a space; listed under Cloth in the Library.
	{name = "Cloth nudge", kind = .Cloth, strength = 0.25, cloth_mode = .Drag},
	{name = "Cloth pull", kind = .Cloth, strength = 0.5, cloth_mode = .Drag, allow_expand = true},
	{name = "Cloth hook", kind = .Snake_Hook, strength = 0.5, physics = true},
	{name = "Cloth inflate", kind = .Cloth, strength = 0.5, cloth_mode = .Inflate},
	// A firm cloth swells into one round puff instead of puckering.
	{name = "Cloth ball", kind = .Cloth, strength = 0.6, cloth_mode = .Inflate, firmness = 0.95},
	{name = "Cloth fold", kind = .Cloth, strength = 0.5, cloth_mode = .Pinch_Line},
	{name = "Cloth pinch", kind = .Cloth, strength = 0.5, cloth_mode = .Pinch},
	{name = "Cloth pinch trails", kind = .Cloth, strength = 0.5, cloth_mode = .Pinch, region = .Follows},
	{name = "Cloth slide", kind = .Cloth, strength = 0.5, cloth_mode = .Drag, region = .Follows},
	{name = "Cloth twister", kind = .Cloth, strength = 0.5, cloth_mode = .Twist},
	{name = "Cloth wind", kind = .Cloth, strength = 0.5, cloth_mode = .Wind},
	{name = "Cloth dimple", kind = .Cloth, strength = 0.5, cloth_mode = .Push},
	// Picks the cloth up by one point and lets the rest hang from it under gravity.
	{name = "Cloth pin", kind = .Cloth, strength = 0.5, cloth_mode = .Drag, gravity = 0.5},
	{name = "Cloth smooth", kind = .Smooth, strength = 0.5, physics = true},
}

// The built-in preset `j` as a preset: the table's row over a fresh brush's values. The
// built-in alphas always take the first indices, in shape order (alpha_find).
built_in_preset :: proc(j: int) -> Brush_Preset {
	r := BUILT_IN_PRESETS[j]
	p := Brush_Preset {
		values = {
			kind = r.kind, strength = r.strength, falloff = {focal = r.focal, projected = projected_default(r.kind)}, alpha = -1, stroke = .Dots,
			spread = SPRAY_DEFAULT_SPREAD, smoothing = 1, pressure_smoothing = 1, color = {1, 1, 1}, lock_plane = r.lock_plane, connected = r.connected,
			grab_depth = r.grab_depth, smooth_only = r.smooth_only, grab_topological = r.topological, elastic_volume = ELASTIC_VOLUME_DEFAULT,
			// As the plain brushes start: Draw does not build up over itself.
			sample_radius = 1, no_accumulate = r.kind == .Draw, one_way = r.one_way,
			tip_roundness = sculpt.CLAY_TIP_ROUNDNESS, tip_scale = 1, trim_angle = TRIM_ANGLE_DEFAULT_DEGREES, trim_dynamic = true,
			plane_height = r.plane[0] if r.plane != {} else 1, plane_depth = r.plane[1] if r.plane != {} else 1,
		},
	}
	if shape, ok := r.alpha.?; ok do p.values.alpha = int(shape)
	p.values.physics, p.values.physics_strength = r.physics, PHYSICS_STRENGTH_DEFAULT
	if .Cloth in BRUSHES[r.kind].flags {
		p.values.cloth_mode, p.values.cloth = r.cloth_mode, sculpt.CLOTH_DEFAULTS
		p.values.cloth.region, p.values.cloth.gravity, p.values.cloth.allow_expand = r.region, r.gravity, r.allow_expand
		if r.firmness > 0 do p.values.cloth.firmness = r.firmness
	}
	preset_name_set(&p, r.name)
	return p
}

// Whether the built-in preset numbered `n` moves the surface as cloth, so the Library lists
// it under Cloth whatever its brush.
built_in_preset_cloth :: proc(n: int) -> bool {
	if !preset_built_in(n) do return false
	r := BUILT_IN_PRESETS[n - BUILT_IN_PRESET]
	return r.physics || .Cloth in BRUSHES[r.kind].flags
}

// Whether `n` numbers a built-in preset.
preset_built_in :: proc(n: int) -> bool {
	return n >= BUILT_IN_PRESET && n < BUILT_IN_PRESET + len(BUILT_IN_PRESETS)
}

// Whether the preset numbered `n` cannot be changed: a built-in's or a pack's.
preset_read_only :: proc(n: int) -> bool {
	return n >= BUILT_IN_PRESET
}

// The built-in preset named `name` (ignoring case), numbered from BUILT_IN_PRESET; 0 for
// none.
built_in_preset_find :: proc(name: string) -> int {
	for r, j in BUILT_IN_PRESETS do if strings.equal_fold(r.name, name) do return BUILT_IN_PRESET + j
	return 0
}
