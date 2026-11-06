package geom

import "core:math"

// The layers a material has over its base colour, metallic and roughness, in the terms of
// OpenPBR Surface (the layering that Autodesk's Standard Surface and Adobe's material
// model were merged into, and that glTF's KHR_materials_* extensions map onto):
// subsurface scattering, a clear coat, sheen, emission, transmission and a thin film.
// Each lobe is gated by its weight alone, so the zero value is a material with none of
// them, shaded exactly as one without layers. Fields with no meaningful zero (the IORs,
// sheen roughness, film thickness, subsurface scale and radius) read zero as their default
// through material_layers_resolve; colours are kept as given, so whoever turns a lobe on
// writes its colour, and black stays possible. The rows are laid out as the renderer's
// eight float4s, in this order.
Material_Layers :: struct {
	// The colour light leaves with after scattering under the surface, linear, and how
	// much of the diffuse part scatters so.
	subsurface_color:      [3]f32,
	subsurface_weight:     f32,
	// How far light travels under the surface before it scatters, per channel, times the
	// scale: in the object's mesh units (imports are normalised to radius 1, so a scale
	// means the same on every imported model, and scaling the object scales it).
	subsurface_radius:     [3]f32,
	subsurface_scale:      f32,
	// A clear coat over everything: how much, its roughness and its IOR; then the base's
	// own specular IOR, which sets a dielectric's reflectance seen straight on.
	coat_weight:           f32,
	coat_roughness:        f32,
	coat_ior:              f32,
	specular_ior:          f32,
	// Sheen, the soft rim of cloth and peach fuzz, linear.
	sheen_color:           [3]f32,
	sheen_weight:          f32,
	// Light the surface gives off, linear, and its brightness in the renderer's units.
	emission_color:        [3]f32,
	emission_luminance:    f32,
	// Light passing through, tinted, as glass and liquids.
	transmission_color:    [3]f32,
	transmission_weight:   f32,
	// The depth at which the transmission colour is reached inside (0: tinted at the
	// surface), whether the surface is a thin sheet with no inside, sheen's roughness,
	// and which way subsurface light tends to scatter (-1 back to 1 forward).
	transmission_depth:    f32,
	thin_walled:           f32,
	sheen_roughness:       f32,
	subsurface_anisotropy: f32,
	// A thin film over the surface (soap bubbles, oil, anodised metal): how much, its
	// thickness in nanometres and its IOR.
	thin_film_weight:      f32,
	thin_film_thickness:   f32,
	thin_film_ior:         f32,
	// How much weaker a dielectric's specular is than its IOR makes it: 1 less OpenPBR's
	// specular weight (glTF's KHR_materials_specular factor), so zero keeps the full
	// specular and a material with no layers stays as it was.
	specular_lessen:       f32,
}

#assert(size_of(Material_Layers) == 128)

// The defaults material_layers_resolve gives a field left at zero. The IORs are OpenPBR's
// (a dielectric's 1.5 is the 4 % reflectance every PBR material has without layers, so
// resolving changes nothing); a subsurface radius of red, half green and a quarter blue
// is skin's ordering, and a scale of 0.05 is about a fingertip's depth on a radius-1 head;
// a 500 nm film shows the first orders of colour.
LAYER_SPECULAR_IOR :: f32(1.5)
LAYER_COAT_IOR :: f32(1.6)
LAYER_THIN_FILM_IOR :: f32(1.4)
LAYER_THIN_FILM_THICKNESS :: f32(500)
LAYER_SHEEN_ROUGHNESS :: f32(0.3)
LAYER_SUBSURFACE_SCALE :: f32(0.05)
LAYER_SUBSURFACE_RADIUS :: [3]f32{1, 0.5, 0.25}

// `l` with every field that reads zero as a default given that default, for the shading.
material_layers_resolve :: proc(l: Material_Layers) -> Material_Layers {
	r := l
	if r.specular_ior == 0 do r.specular_ior = LAYER_SPECULAR_IOR
	if r.coat_ior == 0 do r.coat_ior = LAYER_COAT_IOR
	if r.thin_film_ior == 0 do r.thin_film_ior = LAYER_THIN_FILM_IOR
	if r.thin_film_thickness == 0 do r.thin_film_thickness = LAYER_THIN_FILM_THICKNESS
	if r.sheen_roughness == 0 do r.sheen_roughness = LAYER_SHEEN_ROUGHNESS
	if r.subsurface_scale == 0 do r.subsurface_scale = LAYER_SUBSURFACE_SCALE
	if r.subsurface_radius == {} do r.subsurface_radius = LAYER_SUBSURFACE_RADIUS
	return r
}

// The largest emission luminance and nanometres of film a file may hold: far past any
// look, so a value beyond them is damage, not a choice.
LAYER_EMISSION_MAX :: f32(1e4)
LAYER_THIN_FILM_MAX :: f32(1e4)
// The largest IOR accepted: diamond is 2.42, so 4 leaves room for any real material.
LAYER_IOR_MAX :: f32(4)

// Whether every value of `l` is one a material can have: finite, weights and colours in
// 0..1, distances and the emission not negative, IORs zero (the default) or 1 to
// LAYER_IOR_MAX, anisotropy in -1..1. A scene file holding anything else is refused.
material_layers_valid :: proc(l: Material_Layers) -> bool {
	unit :: proc(v: f32) -> bool {return v >= 0 && v <= 1}
	ior :: proc(v: f32) -> bool {return v == 0 || (v >= 1 && v <= LAYER_IOR_MAX)}
	length :: proc(v: f32) -> bool {return v >= 0 && v < 1e6}
	values := transmute([32]f32)l
	for v in values do if math.is_nan(v) || math.is_inf(v) do return false
	ok := true
	for k in 0 ..< 3 {
		ok &&= unit(l.subsurface_color[k]) && unit(l.sheen_color[k]) && unit(l.emission_color[k]) && unit(l.transmission_color[k])
		ok &&= length(l.subsurface_radius[k])
	}
	ok &&= unit(l.subsurface_weight) && unit(l.coat_weight) && unit(l.coat_roughness) && unit(l.sheen_weight)
	ok &&= unit(l.transmission_weight) && unit(l.sheen_roughness) && unit(l.thin_film_weight) && unit(l.thin_walled) && unit(l.specular_lessen)
	ok &&= length(l.subsurface_scale) && length(l.transmission_depth)
	ok &&= l.emission_luminance >= 0 && l.emission_luminance <= LAYER_EMISSION_MAX
	ok &&= l.thin_film_thickness >= 0 && l.thin_film_thickness <= LAYER_THIN_FILM_MAX
	ok &&= ior(l.specular_ior) && ior(l.coat_ior) && ior(l.thin_film_ior)
	ok &&= l.subsurface_anisotropy >= -1 && l.subsurface_anisotropy <= 1
	return ok
}
