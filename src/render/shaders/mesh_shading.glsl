// The body of mesh.frag and textured.frag (which defines TEXTURED first): an include,
// never compiled alone, so the sculpt mesh and textured meshes share every light, the
// studio, the tone map and cavity.
// SDL_GPU SPIR-V conventions: fragment uniform buffers live in set 3.
layout(location = 0) in vec3 in_view_normal;
layout(location = 1) in vec3 in_view_pos;
layout(location = 2) in float in_mask;
layout(location = 3) in vec4 in_paint;
layout(location = 4) flat in vec3 in_group;
layout(location = 5) in vec3 in_mesh_pos;
// The material slot of the triangle's polygroup (mesh.vert), 0 for the item's own material.
layout(location = 6) flat in uint in_slot;
#ifdef TEXTURED
// Where the pixel is in the maps (v up, as the UV layout keeps it), and the tangent in
// view space with the bitangent's side in w, unnormalized, as textured.vert passes them.
layout(location = 7) in vec2 in_uv;
layout(location = 8) in vec4 in_view_tangent;
#endif

// render.LIGHT_COUNT.
#define LIGHT_COUNT 8

layout(set = 3, binding = 0) uniform Material_Uniforms {
	vec4 base_color;
	vec4 params;  // x: ambient, y: specular strength (below 0: flat base_color, for lines), z: specular power, w: wrap
	vec4 surface; // x: metallic, y: roughness (0: the classic shading above, else physically based), z: 1 for flat shading, w: 1 for the matcap
	vec4 checker; // the density preview: xyz the first lattice point in mesh space, w the cell size (0: none)
	vec4 look;    // x: exposure in stops, y: cavity strength, z: ridge strength (0 to 1); all 0 is plain;
	              // w: how opaque a see-through object is drawn, 0 for fully (the scene's Transparency)
	// The studio's turn into view space, as the columns of a rotation, with the ambient
	// light's strength in light_x.w (render.Lights).
	vec4 light_x;
	vec4 light_y;
	vec4 light_z;
	// Each light (render.Lights), in view space: toward a sun, unit length, or where a
	// point or spot light is, with its kind in w (0 sun, 1 point, 2 spot); its colour in
	// linear light with its strength in w (0 for off); a spot's axis with the cosine of
	// half its cone in w; and its shape: x the distance at which it is as bright as a sun
	// of its strength, y where it fades to nothing (0: never), z the cosine where a spot's
	// edge starts to fade.
	vec4 light_pos[LIGHT_COUNT];
	vec4 light_color[LIGHT_COUNT];
	vec4 light_spot[LIGHT_COUNT];
	vec4 light_shape[LIGHT_COUNT];
	// Textured items: x, y, z 1 where the base colour, ORM and normal maps are bound, w the
	// view (1 the maps, 2 the normal map alone, 3 the UV checker); all 0 on the sculpt mesh.
	vec4 maps;
	// The image environment (render/environment.odin): x 1 while one is bound (0: the
	// studio below), y its strength as a factor, z its prefiltered levels less one.
	vec4 env;
	// The panorama's axes in view space, as the columns of a rotation: turned with the
	// light rig, never tilted.
	vec4 env_x;
	vec4 env_y;
	vec4 env_z;
	// Its diffuse light as nine spherical harmonics in the panorama's axes, already
	// convolved with the cosine lobe and over pi (app/environment_file.odin), rgb each.
	vec4 env_sh[9];
};

#ifndef TEXTURED
// Polygroups' own materials (render.Slot_Uniforms), by slot from 1: the colour, params
// and surface that stand in for the item's; read only behind in_slot > 0.
layout(set = 3, binding = 1) uniform Slot_Uniforms {
	vec4 slot_color[16];
	vec4 slot_params[16];
	vec4 slot_surface[16];
};
#endif

// The matcap (render/matcap.odin): a lit sphere, sRGB, so it samples as linear light.
// SDL_GPU SPIR-V conventions: fragment samplers live in set 2.
layout(set = 2, binding = 0) uniform sampler2D matcap;
// The image environment prefiltered by roughness, one level a fifth of the way up
// (render/environment.odin); a black 1 x 1 one while none is bound.
layout(set = 2, binding = 1) uniform sampler2D environment_map;
#ifdef TEXTURED
// The textured mesh's maps (render.Texture_Map), defaults bound for missing ones.
layout(set = 2, binding = 2) uniform sampler2D base_map;
layout(set = 2, binding = 3) uniform sampler2D orm_map;
layout(set = 2, binding = 4) uniform sampler2D normal_map;

// A checker laid out by the UVs: 8 by 8 cells over the square, every other one darker,
// each edged with a thin line and tinted by its column (hue) and row (lightness), so
// stretching, mirrored charts and seams read at a glance. Where cells shrink under about
// three pixels it fades to its mean, as the density checker does.
vec3 uv_checker(vec2 uv) {
	vec2 c = uv * 8.0;
	vec2 width = max(fwidth(c), vec2(1e-6));
	float per_px = max(width.x, width.y);
	vec2 f = fract(c);
	vec2 edge = min(f, 1.0 - f) / width;
	float line = (1.0 - smoothstep(0.5, 1.5, min(edge.x, edge.y))) * (1.0 - smoothstep(1.0 / 16.0, 1.0 / 8.0, per_px));
	vec2 cell = floor(c);
	float odd = mod(cell.x + cell.y, 2.0);
	float h = (cell.x + 0.5) / 8.0;
	vec3 hue = clamp(abs(fract(h + vec3(0.0, 2.0, 1.0) / 3.0) * 6.0 - 3.0) - 1.0, 0.0, 1.0);
	vec3 tint = mix(vec3(1.0), hue, 0.35) * mix(0.7, 1.0, (cell.y + 0.5) / 8.0);
	float shade = mix(1.0, 0.72, odd) * (1.0 - 0.5 * line);
	return mix(tint * shade, vec3(0.75), smoothstep(0.2, 0.4, per_px));
}
#endif

layout(location = 0) out vec4 out_color;

#include "display.glsl"
#include "panorama.glsl"

const float PI = 3.14159265;

// The studio the physically based materials reflect, in its own space (turned into view
// space by light_x, y and z: by default not at all), as a photographer
// would light a product: a cool sky over a dark floor, a warm softbox above and to the
// side of the default key light (not on it, or the key's highlight would be counted twice), a
// cool strip light behind on the right that catches edges, and a bounce card behind the
// camera, so a face turned to the viewer reflects something rather than the black floor.
// `rough` (0 to 1) blurs it, standing in for a prefiltered environment map at no memory
// and a few instructions.
const vec3 SOFTBOX_DIR = normalize(vec3(-0.75, 0.85, 0.15));
const vec3 STRIP_DIR   = normalize(vec3(0.9, 0.35, -0.45));
const vec3 CARD_DIR    = normalize(vec3(0.1, -0.35, 1.0));

// A light of `color` seen as a lobe around `toward`, `sharp` at the sharpest; it widens
// with roughness while its energy stays about the same, as a blurred reflection of a
// bright light does.
vec3 lobe(vec3 dir, vec3 toward, vec3 color, float sharp, float rough) {
	float e = mix(sharp, 3.0, sqrt(rough));
	return color * pow(max(dot(dir, toward), 0.0), e) * (e + 2.0) / (sharp + 2.0);
}

vec3 studio(vec3 dir, float rough) {
	float w = 0.08 + 0.9 * rough;
	float up = smoothstep(-w, w, dir.y);
	vec3 c = mix(vec3(0.07, 0.065, 0.06), vec3(0.40, 0.43, 0.48), up);
	// A brighter band at the horizon reads as the far wall of the studio.
	c += vec3(0.13, 0.12, 0.11) * exp(-abs(dir.y) / (0.06 + 0.5 * rough));
	c += lobe(dir, SOFTBOX_DIR, vec3(4.0, 3.8, 3.5), 300.0, rough);
	c += lobe(dir, STRIP_DIR, vec3(1.6, 1.8, 2.1), 600.0, rough);
	c += lobe(dir, CARD_DIR, vec3(0.5, 0.5, 0.5), 4.0, rough);
	return c;
}

// What the physically based materials reflect along view-space `dir` at `rough`: the
// image environment at the level prefiltered for that roughness when one is bound, else
// the studio, turned into the rig's space by `to_rig`.
vec3 reflected(vec3 dir, float rough, mat3 to_rig) {
	if (env.x > 0.5) {
		vec3 d = transpose(mat3(env_x.xyz, env_y.xyz, env_z.xyz)) * dir;
		return textureLod(environment_map, panorama_uv(d), rough * env.z).rgb * env.y;
	}
	return studio(to_rig * dir, rough);
}

// The image environment's diffuse light on a white surface facing view-space `n`, from
// its nine spherical harmonics (Ramamoorthi and Hanrahan 2001).
vec3 irradiance(vec3 n) {
	vec3 d = transpose(mat3(env_x.xyz, env_y.xyz, env_z.xyz)) * n;
	vec3 e = env_sh[0].rgb * 0.282095
		+ env_sh[1].rgb * (0.488603 * d.y) + env_sh[2].rgb * (0.488603 * d.z) + env_sh[3].rgb * (0.488603 * d.x)
		+ env_sh[4].rgb * (1.092548 * d.x * d.y) + env_sh[5].rgb * (1.092548 * d.y * d.z)
		+ env_sh[6].rgb * (0.315392 * (3.0 * d.z * d.z - 1.0)) + env_sh[7].rgb * (1.092548 * d.x * d.z)
		+ env_sh[8].rgb * (0.546274 * (d.x * d.x - d.y * d.y));
	return max(e, vec3(0.0)) * env.y;
}

// Karis's fit of the split-sum environment BRDF (Unreal, "Mobile" shading): the scale and
// bias applied to F0 for the reflected environment.
vec2 env_brdf(float n_dot_v, float rough) {
	const vec4 c0 = vec4(-1.0, -0.0275, -0.572, 0.022);
	const vec4 c1 = vec4(1.0, 0.0425, 1.04, -0.04);
	vec4 r = rough * c0 + c1;
	float a004 = min(r.x * r.x, exp2(-9.28 * n_dot_v)) * r.x + r.y;
	return vec2(-1.04, 1.04) * a004 + r.zw;
}

// What a lit colour shows as: scaled by the exposure, tone mapped, sRGB encoded.
// How opaque the surface is drawn: see-through only while look.w says so.
float opacity() {
	return look.w > 0.0 ? look.w : 1.0;
}

vec4 display(vec3 c) {
	return vec4(display_color(c, look.x), opacity());
}

// How much the surface bends where this pixel sees it, as the angle the normal turns
// across one pixel (radians), positive where it bulges toward the eye and negative in
// creases: the change of the normal along each screen direction, projected on the way the
// surface itself moves along it. Sub-pixel grooves and pores give large values and broad
// forms small ones, which is what cavity shading should pick out.
float curvature(vec3 n, vec3 p) {
	vec3 dpx = dFdx(p), dpy = dFdy(p);
	vec3 dnx = dFdx(n), dny = dFdy(n);
	float lx = length(dpx), ly = length(dpy);
	float c = 0.0;
	if (lx > 0.0) c += dot(dnx, dpx) / lx;
	if (ly > 0.0) c += dot(dny, dpy) / ly;
	return c;
}

// Turns per pixel below CURVE_START leave the shading alone, so smooth broad forms are
// untouched; by CURVE_FULL a crease or ridge takes the whole strength.
const float CURVE_START = 0.01;
const float CURVE_FULL = 0.12;

// One light's GGX (Trowbridge-Reitz) specular and Lambert diffuse, Cook-Torrance style.
vec3 direct(vec3 n, vec3 v, vec3 l, vec3 diffuse, vec3 f0, float a) {
	float n_dot_l = max(dot(n, l), 0.0);
	if (n_dot_l <= 0.0) return vec3(0.0);
	vec3 h = normalize(l + v);
	float n_dot_v = max(dot(n, v), 1e-4);
	float n_dot_h = max(dot(n, h), 0.0);
	float a2 = a * a;
	float d = n_dot_h * n_dot_h * (a2 - 1.0) + 1.0;
	float D = a2 / (PI * d * d);
	float V = 0.5 / max(mix(2.0 * n_dot_l * n_dot_v, n_dot_l + n_dot_v, a), 1e-4); // Smith, height-correlated (fast fit)
	vec3 F = f0 + (1.0 - f0) * pow(1.0 - max(dot(v, h), 0.0), 5.0);
	return (diffuse / PI + D * V * F) * n_dot_l;
}

// Light `i` at this pixel: toward it in `l`, and how much of its strength arrives. A sun
// arrives whole. A point or spot light falls off with the square of the distance, equal to
// a sun at light_shape.x, faded smoothly to nothing at its reach (Karis's window, so a far
// light never pops off), and a spot only inside its cone, its edge faded over the blend.
float light_at(int i, out vec3 l) {
	vec4 p = light_pos[i];
	if (p.w < 0.5) {
		l = p.xyz;
		return 1.0;
	}
	vec3 d = p.xyz - in_view_pos;
	float dist2 = max(dot(d, d), 1e-8);
	l = d * inversesqrt(dist2);
	vec4 shape = light_shape[i];
	float k = shape.x * shape.x / dist2;
	if (shape.y > 0.0) {
		float x = dist2 / (shape.y * shape.y);
		float w = clamp(1.0 - x * x, 0.0, 1.0);
		k *= w * w;
	}
	if (p.w > 1.5) k *= smoothstep(light_spot[i].w, shape.z, dot(-l, light_spot[i].xyz));
	return k;
}

void main() {
	if (params.y < 0.0) {
		// Lines: the flat colour, encoded but not lit, exposed or tone mapped.
		out_color = vec4(srgb_encode(base_color.rgb), 1.0);
		return;
	}
	// A polygroup with a material of its own takes its colour, shading and metal and
	// roughness; flat shading stays the item's, and it is lit even on a matcap item (the
	// one sampler is the item's matcap).
	vec4 base = base_color;
	vec4 shading = params;
	vec4 surf = surface;
#ifndef TEXTURED
	if (in_slot > 0u) {
		base = slot_color[in_slot];
		shading = slot_params[in_slot];
		surf.xy = slot_surface[in_slot].xy;
		surf.w = 0.0;
	}
#endif
	vec3 v = normalize(-in_view_pos);
	vec3 n;
	// How much of the studio's ambient light reaches the pixel (a textured mesh's baked
	// occlusion); 1 on the sculpt mesh.
	float ao = 1.0;
#ifdef TEXTURED
	// The maps' view (render.Texture_View) and where the pixel is in them: image rows run
	// top to bottom, the UVs bottom to top.
	int view_mode = int(maps.w + 0.5);
	vec2 uv = vec2(in_uv.x, 1.0 - in_uv.y);
	// Flat shading does not apply: the normal comes from the vertices, then the normal
	// map, in the frame the bake solved for (MikkTSpace's: the interpolated normal and
	// tangent, unnormalized, and the bitangent from their cross product), turned to the
	// side the eye sees.
	{
		vec3 nv = in_view_normal;
		vec3 tv = in_view_tangent.xyz;
		n = normalize(nv);
		if ((view_mode == 1 || view_mode == 2) && maps.z > 0.5) {
			vec3 tn = texture(normal_map, uv).xyz * 2.0 - 1.0;
			vec3 bv = in_view_tangent.w * cross(nv, tv);
			vec3 mapped = tn.x * tv + tn.y * bv + tn.z * nv;
			if (dot(mapped, mapped) > 0.0) n = normalize(mapped);
		}
		// The back of the surface: the mapped normal turned round whole, so the map is not
		// mirrored there.
		if (!gl_FrontFacing) n = -n;
	}
	if (view_mode == 1 && maps.y > 0.5) {
		vec3 orm = texture(orm_map, uv).rgb;
		ao = orm.r;
		surf.x = orm.b;
		surf.y = max(orm.g, 0.04);
	}
#else
	if (surface.z > 0.5) {
		// Flat shading: the triangle's own normal from how the position changes across
		// the screen, so faceting costs no vertex data or extra pass.
		n = normalize(cross(dFdx(in_view_pos), dFdy(in_view_pos)));
		if (dot(n, v) < 0.0) n = -n;
	} else {
		n = normalize(in_view_normal);
		if (!gl_FrontFacing) n = -n;
	}
#endif
	// Derivatives are taken here, where every pixel of a quad runs: cavity and the
	// specular filtering below both use them. With flat shading the normal only changes
	// between triangles, so neither applies.
	vec3 dndx = dFdx(n), dndy = dFdy(n);
	float bend = curvature(n, in_view_pos);
#ifndef TEXTURED
	if (surface.z > 0.5) {
		dndx = vec3(0.0);
		dndy = vec3(0.0);
		bend = 0.0;
	}
#endif
	// Cavity darkens creases and ridge lightens crests, as ZBrush's materials and
	// Blender's cavity shading do, so fine sculpted detail reads at any light angle.
	// A ridge is faded toward the silhouette, where every convex form bends fast
	// across the pixels and would otherwise get a bright outline.
	float facing = max(dot(n, v), 0.0);
	float cavity = look.y * smoothstep(CURVE_START, CURVE_FULL, -bend);
	float ridge = look.z * smoothstep(CURVE_START, CURVE_FULL, bend) * smoothstep(0.1, 0.4, facing);
	float relief = (1.0 - 0.75 * cavity) * (1.0 + 0.6 * ridge);

	// Paint covers the clay as far as it reaches; groups show instead of both.
	vec3 albedo = mix(base.rgb, in_paint.rgb, in_paint.a);
	if (in_group.r >= 0.0) albedo = in_group;
#ifdef TEXTURED
	// The base colour map, times the item's colour (the app passes its tint over the
	// material, white for none), as glTF multiplies factor and texture.
	if (view_mode == 1 && maps.x > 0.5) albedo = base.rgb * texture(base_map, uv).rgb;
	if (view_mode == 3) albedo *= uv_checker(uv);
#endif
	// The density preview: the cells a remesh would build, every other one darker and
	// each edged with a thin line, so a cell reads as about one vertex of the result.
	// Where cells shrink under about three pixels the pattern fades to its mean rather
	// than shimmer; the panel still says the size.
	if (checker.w > 0.0) {
		vec3 c = (in_mesh_pos - checker.xyz) / checker.w;
		vec3 width = max(fwidth(c), vec3(1e-6)); // cells per pixel, along each axis
		float per_px = max(max(width.x, width.y), width.z);
		vec3 f = fract(c);
		vec3 edge = min(f, 1.0 - f) / width; // pixels to the nearest cell face
		// The edge lines only while cells are big enough for a line to leave room for the
		// cell: from 16 pixels across they show in full, under 8 none.
		float line = (1.0 - smoothstep(0.5, 1.5, min(min(edge.x, edge.y), edge.z))) * (1.0 - smoothstep(1.0 / 16.0, 1.0 / 8.0, per_px));
		vec3 cell = floor(c);
		float odd = mod(cell.x + cell.y + cell.z, 2.0);
		float shade = mix(1.0, 0.72, odd) * (1.0 - 0.35 * line);
		float tiny = smoothstep(0.2, 0.4, per_px);
		albedo *= mix(shade, 0.86, tiny);
	}
	mat3 rig = mat3(light_x.xyz, light_y.xyz, light_z.xyz);
	float ambient = light_x.w;
	// Masked areas show darker, as in ZBrush.
	albedo *= 1.0 - 0.7 * in_mask;
	float highlight = 1.0 - 0.5 * in_mask;

	if (surf.w > 0.5) {
		// The matcap's sphere where it faces the way this pixel's normal does as the eye
		// sees it: Blender's basis around the ray to the eye, which keeps the lookup right
		// toward the edges of a perspective view instead of sliding with it. The picture's
		// own light and sheen stand in for the lights, tinted by the colour (and paint and
		// mask); it is already a finished look, so it is exposed but not tone mapped.
		float k = 1.0 / (1.0 + v.z);
		float b = -v.x * v.y * k;
		vec2 m = vec2(dot(vec3(1.0 - v.x * v.x * k, b, -v.x), n), dot(vec3(b, 1.0 - v.y * v.y * k, -v.y), n));
		vec3 lit = texture(matcap, vec2(0.5 + 0.496 * m.x, 0.5 - 0.496 * m.y)).rgb;
		out_color = vec4(srgb_encode(lit * albedo * relief * exp2(look.x)), opacity());
		return;
	}

	if (surf.y > 0.0) {
		float metallic = clamp(surf.x, 0.0, 1.0);
		// Specular anti-aliasing (Tokuyoshi and Kaplanyan 2021, as Filament does it): where
		// the normal varies within a pixel, as on a dense sculpt seen from afar, widen the
		// highlight by that variance so it stays a highlight instead of sparkling.
		float variance = 0.25 * (dot(dndx, dndx) + dot(dndy, dndy));
		float a = surf.y * surf.y;
		float rough = clamp(sqrt(sqrt(clamp(a * a + min(2.0 * variance, 0.18), 0.0, 1.0))), 0.04, 1.0);
		a = rough * rough;
		vec3 diffuse = albedo * (1.0 - metallic);
		vec3 f0 = mix(vec3(0.04), albedo, metallic);
		float n_dot_v = max(dot(n, v), 1e-4);

		vec3 color = vec3(0.0);
		for (int i = 0; i < LIGHT_COUNT; i++) {
			float s = light_color[i].w;
			if (s <= 0.0) continue;
			vec3 l;
			float k = light_at(i, l);
			if (k > 0.0) color += direct(n, v, l, diffuse, f0, a) * light_color[i].rgb * (3.0 * (s * k));
		}
		// Light from the whole studio or image environment, which turns with the rig: the
		// studio's blurriest version scaled by the ambient light (or the image's harmonics)
		// for the diffuse part, and the reflection blurred by roughness for the specular.
		// The studio's diffuse is dimmed to sit with its lights; an image's is taken at its
		// own Strength, so a white surface in a white environment reads white.
		vec3 r = reflect(-v, n);
		vec2 ab = env_brdf(n_dot_v, rough);
		mat3 to_rig = transpose(rig);
		if (env.x > 0.5) {
			color += diffuse * irradiance(n) * ao;
		} else {
			color += diffuse * studio(to_rig * n, 1.0) * (0.7 * ao * ambient);
		}
		color += reflected(r, rough, to_rig) * (f0 * ab.x + ab.y) * (highlight * ao);
		out_color = display(color * relief);
		return;
	}

	// The classic studio clay shading: wrap lets light reach past the side facing it,
	// softening the terminator as wax and skin do; 0 is plain Lambert. Each light adds
	// its share in its colour, and a highlight of its own.
	float wrap = shading.w;
	vec3 lit = vec3(shading.x * ao * ambient);
	vec3 spec = vec3(0.0);
	for (int i = 0; i < LIGHT_COUNT; i++) {
		float s = light_color[i].w;
		if (s <= 0.0) continue;
		vec3 l;
		s *= light_at(i, l);
		if (s <= 0.0) continue;
		lit += light_color[i].rgb * (max((dot(n, l) + wrap) / (1.0 + wrap), 0.0) * s);
		spec += light_color[i].rgb * (pow(max(dot(n, normalize(l + v)), 0.0), shading.z) * shading.y * s);
	}
	float rim  = pow(1.0 - max(dot(n, v), 0.0), 3.0) * 0.25;
	vec3 color = albedo * lit + (spec + rim) * highlight;
	// The viewport texture is a UNORM texture the interface shows as-is, so the shader
	// encodes for the display itself.
	out_color = display(color * relief);
}
