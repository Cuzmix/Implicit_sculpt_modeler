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
}

// The built-in preset `j` as a preset: the table's row over a fresh brush's values. The
// built-in alphas always take the first indices, in shape order (alpha_find).
built_in_preset :: proc(j: int) -> Brush_Preset {
	r := BUILT_IN_PRESETS[j]
	p := Brush_Preset {
		values = {
			kind = r.kind, strength = r.strength, falloff = {focal = r.focal}, alpha = -1, stroke = .Dots,
			spread = SPRAY_DEFAULT_SPREAD, smoothing = 1, pressure_smoothing = 1, color = {1, 1, 1}, lock_plane = r.lock_plane, connected = r.connected,
			grab_depth = r.grab_depth, smooth_only = r.smooth_only,
		},
	}
	if shape, ok := r.alpha.?; ok do p.values.alpha = int(shape)
	preset_name_set(&p, r.name)
	return p
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
