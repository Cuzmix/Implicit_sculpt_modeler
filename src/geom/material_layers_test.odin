package geom

import "core:math"
import "core:testing"

// No layers at all is a valid material and resolves to the defaults, which are themselves
// valid; colours are left as given, so a lobe turned on in black stays black.
@(test)
layers_resolve_zeros_to_their_defaults_only :: proc(t: ^testing.T) {
	none: Material_Layers
	testing.expect(t, material_layers_valid(none))
	r := material_layers_resolve(none)
	testing.expect(t, material_layers_valid(r))
	testing.expect_value(t, r.specular_ior, LAYER_SPECULAR_IOR)
	testing.expect_value(t, r.subsurface_radius, LAYER_SUBSURFACE_RADIUS)
	testing.expect_value(t, r.subsurface_weight, 0)
	testing.expect_value(t, r.sheen_color, [3]f32{})
	given := Material_Layers{specular_ior = 1.33, subsurface_radius = {0.1, 0.1, 0.1}}
	testing.expect_value(t, material_layers_resolve(given).specular_ior, f32(1.33))
	testing.expect_value(t, material_layers_resolve(given).subsurface_radius, [3]f32{0.1, 0.1, 0.1})
}

// Each kind of value a material cannot have is refused.
@(test)
layers_with_impossible_values_are_refused :: proc(t: ^testing.T) {
	bad := [?]Material_Layers {
		{coat_roughness = f32(math.nan_f32())},
		{sheen_color = {0, 1.2, 0}},
		{transmission_weight = -0.1},
		{subsurface_scale = -1},
		{coat_ior = 0.9},
		{thin_film_ior = 5},
		{thin_film_thickness = 2e4},
		{emission_luminance = -1},
		{subsurface_anisotropy = -1.5},
		{thin_walled = 2},
	}
	for l, i in bad do testing.expectf(t, !material_layers_valid(l), "case %d", i)
}
