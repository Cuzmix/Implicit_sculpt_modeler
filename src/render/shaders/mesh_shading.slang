// The body of mesh.frag.slang and textured.frag.slang (which defines TEXTURED first): an
// include, never compiled alone, so the sculpt mesh and textured meshes share every light,
// the studio, the tone map and cavity. The inputs are mesh_io.slang's Mesh_Varyings.
#include "common.slang"
#include "mesh_io.slang"

// render.LIGHT_COUNT.
#define LIGHT_COUNT 8

// SDL_GPU SPIR-V conventions: fragment uniform buffers live in set 3.
[[vk::binding(0, 3)]] cbuffer Material_Uniforms {
	float4 base_color;
	float4 params;  // x: ambient, y: specular strength (below 0: flat base_color, for lines), z: specular power, w: wrap
	float4 surface; // x: metallic, y: roughness (0: the classic shading above, else physically based), z: 1 for flat shading, w: 1 for the matcap
	float4 checker; // the density preview: xyz the first lattice point in mesh space, w the cell size (0: none)
	float4 look;    // x: exposure in stops, y: cavity strength, z: ridge strength (0 to 1); all 0 is plain;
	              // w: how opaque a see-through object is drawn, 0 for fully (the scene's Transparency)
	// The studio's turn into view space, as the columns of a rotation, with the ambient
	// light's strength in light_x.w (render.Lights).
	float4 light_x;
	float4 light_y;
	float4 light_z;
	// Each light (render.Lights), in view space: toward a sun, unit length, or where a
	// point, spot or area light is, with its kind in w (0 sun, 1 point, 2 spot, 3 area);
	// its colour in linear light with its strength in w (0 for off); a spot's axis with the
	// cosine of half its cone in w, or an area's facing; and its shape: x the distance at which it is as bright as a sun
	// of its strength, y where it fades to nothing (0: never), z the cosine where a spot's
	// edge starts to fade, w its size: the sine of a sun's angular radius, or a point or
	// spot light's radius (0: no size).
	float4 light_pos[LIGHT_COUNT];
	float4 light_color[LIGHT_COUNT];
	float4 light_spot[LIGHT_COUNT];
	float4 light_shape[LIGHT_COUNT];
	// An area light's first edge with half its width in w; and each light's extra: x its
	// highlight less or more than usual (-1 to 1, 0 as usual), y 1 for no shadows (the
	// studio's and render mode's), z an area light's half height, w 1 for a disc.
	float4 light_axis[LIGHT_COUNT];
	float4 light_extra[LIGHT_COUNT];
	// Textured items: x, y, z 1 where the base colour, ORM and normal maps are bound, w the
	// view (1 the maps, 2 the normal map alone, 3 the UV checker); all 0 on the sculpt mesh.
	float4 maps;
	// The image environment (render/environment.odin): x 1 while one is bound (0: the
	// studio below), y its strength as a factor, z its prefiltered levels less one; and w,
	// whatever the environment, 1 under a parallel (orthographic) projection, where the
	// way to the eye is the view's own direction at every pixel.
	float4 env;
	// The panorama's axes in view space, as the columns of a rotation: turned with the
	// light rig, never tilted.
	float4 env_x;
	float4 env_y;
	float4 env_z;
	// Its diffuse light as nine spherical harmonics in the panorama's axes, already
	// convolved with the cosine lobe and over pi (app/environment_file.odin), rgb each.
	float4 env_sh[9];
	// The shading's style (render.Draw_Item.style): x the rim's strength, y how much of the
	// ambient light reaches a surface facing straight down, w 1 to use them (0: the
	// classic rim and an even ambient light); z 1 to draw masked parts as the rest.
	float4 style;
	// The viewport's pass (render.View_Pass) in x, 0 shaded as usual; y and z where the
	// Depth pass starts and ends, as distances from the eye; w a wipe compare (main below).
	float4 pass;
	// How far the view takes the colours toward clay (render.Draw_Item.fade): rgb the clay,
	// w how far, 0 for the colours whole; a polygroup shown keeps its colour.
	float4 fade;
#if defined(WIRE_BARY) || defined(CLIP)
	// The wireframe's colour, linear, drawn over the triangles' edges (wire_over below), and
	// in w 1 when tri_edges says which of them are polygon edges, 0 to draw them all. A
	// clipped variant declares it only to reach `clip` after it.
	float4 wire;
#endif
#ifdef CLIP
	// The mirror's planes through the mesh's origin (render.Draw_Item.clip): a pixel whose
	// mesh-space point has clip.a * p.a below 0 on any axis is not drawn. Only the clipped
	// variants (*_clip.frag) read it, so the rest keep their early depth test.
	float4 clip;
#endif
};

#ifndef TEXTURED
// Polygroups' own materials (render.Slot_Uniforms), by slot from 1: the colour, params
// and surface that stand in for the item's; read only behind frag_in.slot > 0.
[[vk::binding(1, 3)]] cbuffer Slot_Uniforms {
	float4 slot_color[16];
	float4 slot_params[16];
	float4 slot_surface[16];
};
#endif

// The matcap (render/matcap.odin): a lit sphere, sRGB, so it samples as linear light.
// SDL_GPU SPIR-V conventions: fragment samplers live in set 2.
[[vk::binding(0, 2)]] Sampler2D matcap;
// The image environment prefiltered by roughness, one level a fifth of the way up
// (render/environment.odin); a black 1 x 1 one while none is bound.
[[vk::binding(1, 2)]] Sampler2D environment_map;
#ifdef TEXTURED
// The textured mesh's maps (render.Texture_Map), defaults bound for missing ones.
[[vk::binding(2, 2)]] Sampler2D base_map;
[[vk::binding(3, 2)]] Sampler2D orm_map;
[[vk::binding(4, 2)]] Sampler2D normal_map;
// The texture paint layers' composite (render.Textured_Mesh.paint): colour premultiplied
// by its coverage, and roughness, its coverage, metal, its coverage, the values
// premultiplied too, so filtering at a painted edge does not darken it. Transparent
// black, painting nothing, while there is none.
[[vk::binding(5, 2)]] Sampler2D paint_map;
[[vk::binding(6, 2)]] Sampler2D paint_material_map;
// The texture paint layers' height (render.Textured_Mesh.paint_height): signed, in
// height units, 0 flat; a 1 x 1 default while none is painted.
[[vk::binding(7, 2)]] Sampler2D paint_height_map;

// The tangent-space normal the painted height gives at `uv` (image rows down): four taps a
// texel apart, the slope one height unit a 64th of the UV square makes, so the relief is
// the same at any texture size; the bitangent points up the image (toward +v).
float2 paint_height_slope(float2 uv) {
	uint w, h;
	paint_height_map.GetDimensions(w, h);
	if (w <= 1u) return float2(0.0, 0.0);
	float2 px = float2(1.0 / float(w), 1.0 / float(h));
	float l = paint_height_map.Sample(uv - float2(px.x, 0.0)).r;
	float r = paint_height_map.Sample(uv + float2(px.x, 0.0)).r;
	float up = paint_height_map.Sample(uv - float2(0.0, px.y)).r;
	float down = paint_height_map.Sample(uv + float2(0.0, px.y)).r;
	float k = float(w) / 64.0;
	return float2(r - l, up - down) * 0.5 * k;
}

// A checker laid out by the UVs: 8 by 8 cells over the square, every other one darker,
// each edged with a thin line and tinted by its column (hue) and row (lightness), so
// stretching, mirrored charts and seams read at a glance. Where cells shrink under about
// three pixels it fades to its mean, as the density checker does.
float3 uv_checker(float2 uv) {
	float2 c = uv * 8.0;
	float2 width = max(fwidth(c), float2(1e-6));
	float per_px = max(width.x, width.y);
	float2 f = frac(c);
	float2 edge = min(f, 1.0 - f) / width;
	float line = (1.0 - smoothstep(0.5, 1.5, min(edge.x, edge.y))) * (1.0 - smoothstep(1.0 / 16.0, 1.0 / 8.0, per_px));
	float2 cell = floor(c);
	float odd = glsl_mod(cell.x + cell.y, 2.0);
	float h = (cell.x + 0.5) / 8.0;
	float3 hue = clamp(abs(frac(h + float3(0.0, 2.0, 1.0) / 3.0) * 6.0 - 3.0) - 1.0, 0.0, 1.0);
	float3 tint = lerp(float3(1.0), hue, 0.35) * lerp(0.7, 1.0, (cell.y + 0.5) / 8.0);
	float shade = lerp(1.0, 0.72, odd) * (1.0 - 0.5 * line);
	return lerp(tint * shade, float3(0.75), smoothstep(0.2, 0.4, per_px));
}
#endif

// The fragment's inputs, kept where every function here can read them.
static Mesh_Varyings frag_in;
static float4 frag_coord;
static bool front_facing;

#ifdef SKINNED
// The detail skin (sculpt/skin.odin): each sample's normal in the mesh's space, octahedral
// in two signed 16-bit halves (x low), and per triangle its three edges (number << 1, the
// low bit set where the triangle runs the edge against its owner) and in w which corner of
// the triangle as drawn is its first in the mesh (polygroups start a triangle at its lead
// corner). The layout is sculpt.skin_sample's.
[[vk::binding(2, 2)]] StructuredBuffer<uint> skin_normals;
[[vk::binding(3, 2)]] StructuredBuffer<uint4> skin_tris;

float3 skin_normal_at(uint x) {
	uint p = skin_normals[x];
	float2 e = max(float2(int2(int(p << 16) >> 16, int(p) >> 16)) / 32767.0, float2(-1.0));
	return oct_decode(e);
}

// The skin's normal at the pixel, in view space (not unit length): the three samples of the
// small triangle it lies in, mixed by where it lies in it.
float3 skin_view_normal() {
	uint S = frag_in.skin_meta.x, V = frag_in.skin_meta.y, E = frag_in.skin_meta.z;
	uint tri = frag_in.skin_tri.x;
	uint3 x;
	float3 w;
	skin_grid_corners(S, V, E, tri, skin_tris[tri], frag_in.bary, frag_in.skin_tri.yzw, x, w);
	float3 n = skin_normal_at(x.x) * w.x + skin_normal_at(x.y) * w.y + skin_normal_at(x.z) * w.z;
	return n.x * frag_in.turn_x + n.y * frag_in.turn_y + n.z * frag_in.turn_z;
}
#endif

// Skin detail (View_Pass.Skin_Detail): what a detail skin adds to its mesh's normal, as a
// tangent-space normal map shows it, flat lavender (0.5, 0.5, 1) where the skin holds
// nothing, the sideways part doubled so fine detail reads. The frame is built in the
// mesh's own space from its smoothed normal, so the colours stay put as the view turns.
// Without a skin the whole surface is flat lavender: nothing is in a skin there. Lit only
// a little, by how squarely it faces the eye, so the form still reads. `n` is the shaded
// normal and `v` the way to the eye, both in view space.
float3 skin_detail_color(float3 n, float3 v) {
	float3 flat_n = normalize(frag_in.view_normal);
	if (!front_facing) flat_n = -flat_n;
	float3 rgb = float3(0.5, 0.5, 1.0);
#ifdef SKINNED
	// Back into the mesh's space: the turn's rows are a rotation times the uniform scale.
	float3 tx = frag_in.turn_x, ty = frag_in.turn_y, tz = frag_in.turn_z;
	float3 m = normalize(float3(dot(flat_n, tx), dot(flat_n, ty), dot(flat_n, tz)));
	float3 s = normalize(float3(dot(n, tx), dot(n, ty), dot(n, tz)));
	float3 ref = abs(m.y) < 0.99 ? float3(0.0, 1.0, 0.0) : float3(1.0, 0.0, 0.0);
	float3 t = normalize(cross(ref, m));
	float3 b = cross(m, t);
	float3 d = float3(clamp(2.0 * dot(s, t), -1.0, 1.0), clamp(2.0 * dot(s, b), -1.0, 1.0), dot(s, m));
	rgb = d * 0.5 + 0.5;
	// A carried skin's heat (sculpt.Skin.heat, in the record's high 16 bits): how far the
	// triangle's skin strays from the surface it came from, over a grid step, from green
	// (none) through yellow to red (a step or more), laid over the detail colours.
	uint heat = skin_tris[frag_in.skin_tri.x].w >> 16u;
	if (heat > 0u) {
		float h = float(heat - 1u) / 65534.0;
		float3 ramp = h < 0.5 ? lerp(float3(0.15, 0.75, 0.25), float3(0.95, 0.85, 0.2), h * 2.0) : lerp(float3(0.95, 0.85, 0.2), float3(0.9, 0.15, 0.1), h * 2.0 - 1.0);
		rgb = lerp(rgb, ramp, 0.7);
	}
#endif
	return rgb * (0.7 + 0.3 * clamp(dot(flat_n, v), 0.0, 1.0));
}

#include "display.slang"
#include "panorama.slang"

static const float PI = 3.14159265;

#include "studio_env.slang"
#include "ggx_albedo.slang"

// What the physically based materials reflect along view-space `dir` at `rough`: the
// image environment at the level prefiltered for that roughness when one is bound, else
// the studio, turned into the rig's space by `to_rig`.
float3 reflected(float3 dir, float rough, float3x3 to_rig) {
	if (env.x > 0.5) {
		float3 d = mul(dir, transpose(float3x3(env_x.xyz, env_y.xyz, env_z.xyz)));
		return environment_map.SampleLevel(panorama_uv(d), rough * env.z).rgb * env.y;
	}
	return studio(mul(dir, to_rig), rough);
}

// The image environment's diffuse light on a white surface facing view-space `n`, from
// its nine spherical harmonics (Ramamoorthi and Hanrahan 2001).
float3 irradiance(float3 n) {
	float3 d = mul(n, transpose(float3x3(env_x.xyz, env_y.xyz, env_z.xyz)));
	float3 e = env_sh[0].rgb * 0.282095
		+ env_sh[1].rgb * (0.488603 * d.y) + env_sh[2].rgb * (0.488603 * d.z) + env_sh[3].rgb * (0.488603 * d.x)
		+ env_sh[4].rgb * (1.092548 * d.x * d.y) + env_sh[5].rgb * (1.092548 * d.y * d.z)
		+ env_sh[6].rgb * (0.315392 * (3.0 * d.z * d.z - 1.0)) + env_sh[7].rgb * (1.092548 * d.x * d.z)
		+ env_sh[8].rgb * (0.546274 * (d.x * d.x - d.y * d.y));
	return max(e, float3(0.0)) * env.y;
}

// Karis's fit of the split-sum environment BRDF (Unreal, "Mobile" shading): the scale and
// bias applied to F0 for the reflected environment.
float2 env_brdf(float n_dot_v, float rough) {
	const float4 c0 = float4(-1.0, -0.0275, -0.572, 0.022);
	const float4 c1 = float4(1.0, 0.0425, 1.04, -0.04);
	float4 r = rough * c0 + c1;
	float a004 = min(r.x * r.x, exp2(-9.28 * n_dot_v)) * r.x + r.y;
	return float2(-1.04, 1.04) * a004 + r.zw;
}

// What a lit colour shows as: scaled by the exposure, tone mapped, sRGB encoded.
// How opaque the surface is drawn: see-through only while look.w says so.
float opacity() {
	return look.w > 0.0 ? look.w : 1.0;
}

float4 display(float3 c) {
	return float4(display_color(c, look.x), opacity());
}

// How much the surface bends where this pixel sees it, as the angle the normal turns
// across one pixel (radians), positive where it bulges toward the eye and negative in
// creases: the change of the normal along each screen direction, projected on the way the
// surface itself moves along it. Sub-pixel grooves and pores give large values and broad
// forms small ones, which is what cavity shading should pick out.
float curvature(float3 n, float3 p) {
	float3 dpx = ddx(p), dpy = ddy(p);
	float3 dnx = ddx(n), dny = ddy(n);
	float lx = length(dpx), ly = length(dpy);
	float c = 0.0;
	if (lx > 0.0) c += dot(dnx, dpx) / lx;
	if (ly > 0.0) c += dot(dny, dpy) / ly;
	return c;
}

// Turns per pixel below CURVE_START leave the shading alone, so smooth broad forms are
// untouched; by CURVE_FULL a crease or ridge takes the whole strength. The ramp is wide, as
// ZBrush's cavity is, so the small bends a dense mesh's triangles make across a pixel stay
// near zero instead of drawing dark hairlines along the edges.
static const float CURVE_START = 0.02;
static const float CURVE_FULL = 0.24;

// One light's GGX (Trowbridge-Reitz) specular and Lambert diffuse, Cook-Torrance style;
// `shine` scales the specular, the light's Highlight (1 as usual), and `comp` gives it back
// the light its microfacets scatter between them (energy_compensation).
float3 direct(float3 n, float3 v, float3 l, float3 diffuse, float3 f0, float a, float shine, float3 comp) {
	float n_dot_l = max(dot(n, l), 0.0);
	if (n_dot_l <= 0.0) return float3(0.0);
	float3 h = normalize(l + v);
	float n_dot_v = max(dot(n, v), 1e-4);
	float n_dot_h = max(dot(n, h), 0.0);
	float a2 = a * a;
	float d = n_dot_h * n_dot_h * (a2 - 1.0) + 1.0;
	float D = a2 / (PI * d * d);
	float V = 0.5 / max(lerp(2.0 * n_dot_l * n_dot_v, n_dot_l + n_dot_v, a), 1e-4); // Smith, height-correlated (fast fit)
	float3 F = f0 + (1.0 - f0) * pow(1.0 - max(dot(v, h), 0.0), 5.0);
	return (diffuse / PI + D * V * F * comp * shine) * n_dot_l;
}

// The direction inside a light seen as a disc of angular radius asin(spread) about `l`
// that is nearest the mirror direction `r`: Karis's representative point ("Real Shading
// in Unreal Engine 4"), as Filament shades its sun's disc. Where the mirror direction
// falls inside the light it is the mirror direction itself.
float3 nearest_in_light(float3 l, float3 r, float spread) {
	float cos_r = sqrt(max(1.0 - spread * spread, 0.0));
	float l_dot_r = dot(l, r);
	if (l_dot_r >= cos_r) return r;
	float3 s = r - l_dot_r * l;
	float s2 = dot(s, s);
	// The mirror direction straight away from the light has no nearest side.
	if (s2 < 1e-12) return l;
	return normalize(l * cos_r + s * (rsqrt(s2) * spread));
}

// How much a light's size spreads a highlight of GGX width `a`: the width it is widened
// to, so the energy the representative point adds is taken out again, (a / a')^2.
float widened(float a, float spread) {
	float wide = min(a + 0.5 * spread, 1.0);
	return (a * a) / (wide * wide);
}

// direct() for a light with a size: the diffuse part from `l`, the specular from `ls`, the
// point of it nearest the mirror direction (nearest_in_light, area_mirror), normalized by
// how much it widens.
float3 direct_sized(float3 n, float3 v, float3 l, float3 ls, float spread, float3 diffuse, float3 f0, float a, float shine, float3 comp) {
	float3 color = diffuse / PI * max(dot(n, l), 0.0);
	float n_dot_l = max(dot(n, ls), 0.0);
	if (n_dot_l <= 0.0) return color;
	float3 h = normalize(ls + v);
	float n_dot_v = max(dot(n, v), 1e-4);
	float n_dot_h = max(dot(n, h), 0.0);
	float a2 = a * a;
	float d = n_dot_h * n_dot_h * (a2 - 1.0) + 1.0;
	float D = a2 / (PI * d * d) * widened(a, spread);
	float V = 0.5 / max(lerp(2.0 * n_dot_l * n_dot_v, n_dot_l + n_dot_v, a), 1e-4);
	float3 F = f0 + (1.0 - f0) * pow(1.0 - max(dot(v, h), 0.0), 5.0);
	return color + D * V * F * comp * n_dot_l * shine;
}

// The point of area light `i` (its rectangle, or its disc where light_extra.w is 1) nearest
// `q`, given as offsets along its edges from its middle.
float2 area_clamp(int i, float2 q) {
	float hw = light_axis[i].w;
	if (light_extra[i].w > 0.5) {
		float len = length(q);
		return len > hw ? q * (hw / len) : q;
	}
	return clamp(q, float2(-hw, -light_extra[i].z), float2(hw, light_extra[i].z));
}

// The direction from this pixel to the point of area light `i` its mirror direction `r`
// meets, or where it misses, the nearest the light comes to where it would: the
// representative point of Karis's "Real Shading in Unreal Engine 4" for a rectangle, so a
// softbox's highlight takes the softbox's shape.
float3 area_mirror(int i, float3 r) {
	float3 c = light_pos[i].xyz;
	float3 f = light_spot[i].xyz;
	float3 u = light_axis[i].xyz;
	float3 w = cross(f, u);
	float3 to = c - frag_in.view_pos;
	float facing = dot(r, f);
	// The mirror ray meets the light's plane ahead when it runs toward its face; else the
	// point as far along it as the light's middle is.
	float t = facing < -1e-4 ? dot(to, f) / facing : length(to);
	float3 hit = frag_in.view_pos + r * t - c;
	float2 q = area_clamp(i, float2(dot(hit, u), dot(hit, w)));
	return normalize(to + u * q.x + w * q.y);
}

// Area light `i` at this pixel, as light_at gives the others: toward the point of it
// nearest the pixel, so a surface beside a broad light is lit across it; its strength
// falls with the square of the distance from its middle (the distance it equals a sun at,
// light_shape.x), never closer than its disc's radius so it stays finite against it, times
// the cosine at its face, nothing behind it; its reach as a point light's. `spread` is its
// disc's size seen from here.
float area_at(int i, out float3 l, out float spread) {
	float3 c = light_pos[i].xyz;
	float3 f = light_spot[i].xyz;
	float3 u = light_axis[i].xyz;
	float3 w = cross(f, u);
	float4 shape = light_shape[i];
	float3 d = frag_in.view_pos - c;
	spread = 0.0;
	l = f;
	if (dot(d, f) <= 0.0) return 0.0;
	float2 q = area_clamp(i, float2(dot(d, u), dot(d, w)));
	float3 to = c + u * q.x + w * q.y - frag_in.view_pos;
	l = normalize(to);
	float dist2 = max(dot(d, d), shape.w * shape.w);
	spread = min(shape.w * rsqrt(dist2), 1.0);
	float k = shape.x * shape.x / max(dist2, 1e-8) * max(dot(-l, f), 0.0);
	if (shape.y > 0.0) {
		float x = dist2 / (shape.y * shape.y);
		float win = clamp(1.0 - x * x, 0.0, 1.0);
		k *= win * win;
	}
	return k;
}

// Light `i` at this pixel: toward it in `l`, and how much of its strength arrives. A sun
// arrives whole. A point or spot light falls off with the square of the distance, equal to
// a sun at light_shape.x, faded smoothly to nothing at its reach (Karis's window, so a far
// light never pops off), and a spot only inside its cone, its edge faded over the blend.
// `spread` is how big the light looks from here, the sine of its angular radius: a sun's
// is fixed, a point or spot light's grows as the surface nears it, all of the sky once
// the surface is inside it; 0 for a light with no size.
float light_at(int i, out float3 l, out float spread) {
	float4 p = light_pos[i];
	float4 shape = light_shape[i];
		if (p.w < 0.5) {
		l = p.xyz;
		spread = shape.w;
		return 1.0;
	}
	float3 d = p.xyz - frag_in.view_pos;
	float dist2 = max(dot(d, d), 1e-8);
	float inv = rsqrt(dist2);
	l = d * inv;
	spread = min(shape.w * inv, 1.0);
	float k = shape.x * shape.x / dist2;
	if (shape.y > 0.0) {
		float x = dist2 / (shape.y * shape.y);
		float w = clamp(1.0 - x * x, 0.0, 1.0);
		k *= w * w;
	}
	if (p.w > 1.5) k *= smoothstep(light_spot[i].w, shape.z, dot(-l, light_spot[i].xyz));
	return k;
}

// How far `n` faces the rig's up axis, 0 straight down to 1 straight up.
float sky_facing(float3 n, float3x3 rig) {
	return 0.5 + 0.5 * dot(n, rig[1]);
}

// The share of the ambient light a surface facing `n` gets under a style: style.y facing
// straight down, all of it facing up.
float underside(float3 n, float3x3 rig) {
	return lerp(style.y, 1.0, sky_facing(n, rig));
}

#ifdef WIRE_BARY
// The wireframe drawn in the shading itself (mesh_wire.frag.slang), on devices whose
// fragment stage knows where it lies between the triangle's corners: the edges in one pass
// with no second draw of the triangles as lines. Each corner's weight over its change per
// pixel is how many pixels away the edge across from it is, so a line a little over a
// pixel wide is anti-aliased whatever the triangle's size. Where the triangles shrink to a
// pixel or two the lines would cover all of it in a moire of rings, so they even out to
// WIRE_DENSE of the colour there: the surface reads as dense and its form still shows.
#define WIRE_DENSE 0.5
// Per triangle, four bits (eight triangles a word, the first lowest): bit k set where the
// edge across from corner k is a polygon's edge, clear where it cuts a polygon into
// triangles (a quad's diagonal), which the wireframe leaves out (render.Mesh_Buffers.tri_edges).
[[vk::binding(2, 2)]] StructuredBuffer<uint> tri_edges;

// render.WIRE_ALL_EDGES: a draw of triangles with no polygons behind them (a simplified copy).
#define WIRE_ALL_EDGES 0xffffffffu

float4 wire_over(float4 c, float3 bary, uint primitive) {
	float3 per_px = max(fwidth(bary), float3(1e-8));
	float3 px = bary / per_px;
	if (wire.w > 0.5 && frag_in.tri_base != WIRE_ALL_EDGES) {
		uint tri = frag_in.tri_base + primitive;
		uint drawn = (tri_edges[tri >> 3u] >> ((tri & 7u) * 4u)) & 7u;
		// An edge left out (a polygon's diagonal) is never the near one.
		float far = 1e8;
		if ((drawn & 1u) == 0u) px.x = far;
		if ((drawn & 2u) == 0u) px.y = far;
		if ((drawn & 4u) == 0u) px.z = far;
	}
	float near = min(px.x, min(px.y, px.z));
	// The triangle's narrowest height in pixels, roughly.
	float size = 1.0 / max(per_px.x, max(per_px.y, per_px.z));
	float cover = lerp(WIRE_DENSE, saturate(1.2 - near), saturate((size - 1.5) / 3.0));
	return float4(lerp(c.rgb, srgb_encode(wire.rgb), cover), c.a);
}

float4 shade(Mesh_Varyings v_in, float4 position, bool is_front);

float4 main(Mesh_Varyings v_in, float4 position : SV_Position, bool is_front : SV_IsFrontFace, float3 bary : SV_Barycentrics, uint primitive : SV_PrimitiveID) : SV_Target0 {
	float4 c = shade(v_in, position, is_front);
	return wire_over(c, bary, primitive);
}

float4 shade(Mesh_Varyings v_in, float4 position, bool is_front) {
#else
float4 main(Mesh_Varyings v_in, float4 position : SV_Position, bool is_front : SV_IsFrontFace) : SV_Target0 {
#endif
#ifdef CLIP
	if (any(clip.xyz * v_in.mesh_pos < float3(0.0))) discard;
#endif
	frag_in = v_in;
	frag_coord = position;
	front_facing = is_front;
	if (params.y < 0.0) {
		// Lines: the flat colour, encoded but not lit, exposed or tone mapped.
		return float4(srgb_encode(base_color.rgb), 1.0);
	}
	// A polygroup with a material of its own takes its colour, shading and metal and
	// roughness; flat shading stays the item's, and it is lit even on a matcap item (the
	// one sampler is the item's matcap).
	float4 base = base_color;
	float4 shading = params;
	float4 surf = surface;
#ifndef TEXTURED
	if (frag_in.slot > 0u) {
		base = slot_color[frag_in.slot];
		shading = slot_params[frag_in.slot];
		surf.xy = slot_surface[frag_in.slot].xy;
		surf.w = 0.0;
	}
	// Painted roughness and metal over the material's, on the physically based path only:
	// the classic one has neither.
	if (surf.y > 0.0) surf.xy = paint_surface(surf.xy, frag_in.material);
#endif
	// The way to the eye. In parallel projection it is the view's own axis everywhere: the
	// eye sits close to the target there (zooming moves it in, even past the surface), so
	// the way to its point would turn sideways toward the outline and point away from
	// what lies behind it, which turned flat shading's normals, the rim and the
	// highlights inside out.
	float3 v = env.w > 0.5 ? float3(0.0, 0.0, 1.0) : normalize(-frag_in.view_pos);
	float3 n;
	// How much of the studio's ambient light reaches the pixel (a textured mesh's baked
	// occlusion); 1 on the sculpt mesh.
	float ao = 1.0;
#ifdef TEXTURED
	// The maps' view (render.Texture_View) and where the pixel is in them: image rows run
	// top to bottom, the UVs bottom to top.
	int view_mode = int(maps.w + 0.5);
	float2 uv = float2(frag_in.uv.x, 1.0 - frag_in.uv.y);
	// Flat shading does not apply: the normal comes from the vertices, then the normal
	// map, in the frame the bake solved for (MikkTSpace's: the interpolated normal and
	// tangent, unnormalized, and the bitangent from their cross product), turned to the
	// side the eye sees.
	{
		float3 nv = frag_in.view_normal;
		float3 tv = frag_in.view_tangent.xyz;
		n = normalize(nv);
		if (view_mode == 1 || view_mode == 2) {
			float3 tn = maps.z > 0.5 ? normal_map.Sample(uv).xyz * 2.0 - 1.0 : float3(0.0, 0.0, 1.0);
			// The painted height's relief over the map's, as a UDN blend adds detail normals.
			float2 slope = paint_height_slope(uv);
			tn.xy -= slope;
			if (maps.z > 0.5 || any(slope != 0.0)) {
				float3 bv = frag_in.view_tangent.w * cross(nv, tv);
				float3 mapped = tn.x * tv + tn.y * bv + tn.z * nv;
				if (dot(mapped, mapped) > 0.0) n = normalize(mapped);
			}
		}
		// The back of the surface: the mapped normal turned round whole, so the map is not
		// mirrored there.
		if (!front_facing) n = -n;
	}
	if (view_mode == 1 && maps.y > 0.5) {
		float3 orm = orm_map.Sample(uv).rgb;
		ao = orm.r;
		surf.x = orm.b;
		surf.y = max(orm.g, 0.04);
	}
	// Painted roughness and metal over the material's, on the physically based path only:
	// the vertex layers', then the texture layers' over them.
	if (view_mode == 1 && surf.y > 0.0) {
		surf.xy = paint_surface(surf.xy, frag_in.material);
		float4 m = paint_material_map.Sample(uv);
		surf.x = surf.x * (1.0 - m.w) + m.z;
		surf.y = max(surf.y * (1.0 - m.y) + m.x, 0.04);
	}
#elif defined(SKINNED)
	// A detail skin's normal carries its detail, which flat shading would throw away with
	// the smoothed normal it replaces, so the skin shades the same with it on or off.
	n = normalize(skin_view_normal());
	if (!front_facing) n = -n;
#else
	if (surface.z > 0.5) {
		// Flat shading: the triangle's own normal from how the position changes across
		// the screen, so faceting costs no vertex data or extra pass.
		n = normalize(cross(ddx(frag_in.view_pos), ddy(frag_in.view_pos)));
		if (dot(n, v) < 0.0) n = -n;
	} else {
		n = normalize(frag_in.view_normal);
		if (!front_facing) n = -n;
	}
#endif
	// Derivatives are taken here, where every pixel of a quad runs: cavity and the
	// specular filtering below both use them. With flat shading the normal only changes
	// between triangles, so neither applies.
	float3 dndx = ddx(n), dndy = ddy(n);
	float bend = curvature(n, frag_in.view_pos);
#if !defined(TEXTURED) && !defined(SKINNED)
	if (surface.z > 0.5) {
		dndx = float3(0.0);
		dndy = float3(0.0);
		bend = 0.0;
	}
#endif
	// A diagnostic pass shows one quantity plainly, unlit and not tone mapped, so the
	// form reads without the lights' help; the colours are written as shown.
	int view_pass = int(pass.x + 0.5);
	// A wipe compare: pass.w is 0 when off, else 1 + the pass right of its line + 16 times
	// the line's pixel column, and the pixels from that column on show that pass instead.
	if (pass.w > 0.5) {
		float wipe = pass.w - 1.0;
		float line_px = floor(wipe / 16.0);
		if (frag_coord.x >= line_px) view_pass = int(wipe - line_px * 16.0 + 0.5);
	}
	// Unlit (7) is no diagnostic pass: it shows the colour, below, once it is known.
	if (view_pass != 0 && view_pass != 7) {
		float3 shown = float3(0.0);
		if (view_pass == 1) {
			// Normals: the view-space normal as a colour, as Blender's and ZBrush's show it.
			shown = n * 0.5 + 0.5;
		} else if (view_pass == 2) {
			// Depth: near white, far black, across the scene's depth from the eye.
			float t = clamp((-frag_in.view_pos.z - pass.y) / max(pass.z - pass.y, 1e-6), 0.0, 1.0);
			shown = float3(1.0 - t);
		} else if (view_pass == 3) {
			// Curvature: flat mid grey, creases toward blue and crests toward orange, full
			// by CURVE_FULL. Under flat shading the smoothed normal still says how it bends.
			float c = bend;
#if !defined(TEXTURED) && !defined(SKINNED)
			if (surface.z > 0.5) {
				float3 smooth_n = normalize(frag_in.view_normal);
				if (!front_facing) smooth_n = -smooth_n;
				c = curvature(smooth_n, frag_in.view_pos);
			}
#endif
			// Crests fade toward the outline, where every convex form bends fast across
			// the pixels, as the shaded ridge does.
			float k = clamp(c / CURVE_FULL, -1.0, 1.0);
			if (k > 0.0) k *= smoothstep(0.1, 0.4, max(dot(n, v), 0.0));
			shown = lerp(float3(0.5), k < 0.0 ? float3(0.15, 0.35, 0.85) : float3(0.95, 0.55, 0.15), abs(k));
		} else if (view_pass == 4) {
			// AO: a plain light grey, which the live occlusion darkens after the frame.
			shown = float3(0.85);
		} else if (view_pass == 6) {
			shown = skin_detail_color(n, v);
		} else {
			// Silhouette: near-black, as the thumbnail's.
			shown = float3(0.06);
		}
		return float4(shown, opacity());
	}
	// Cavity darkens creases and ridge lightens crests, as ZBrush's materials and
	// Blender's cavity shading do, so fine sculpted detail reads at any light angle.
	// A ridge is faded toward the silhouette, where every convex form bends fast
	// across the pixels and would otherwise get a bright outline.
	float facing = max(dot(n, v), 0.0);
	float cavity = look.y * smoothstep(CURVE_START, CURVE_FULL, -bend);
	float ridge = look.z * smoothstep(CURVE_START, CURVE_FULL, bend) * smoothstep(0.1, 0.4, facing);
	float relief = (1.0 - 0.75 * cavity) * (1.0 + 0.6 * ridge);

	// Paint covers the clay as far as it reaches; groups show instead of both.
	float3 albedo = lerp(base.rgb, frag_in.paint.rgb, frag_in.paint.a);
	if (frag_in.group.r >= 0.0) albedo = frag_in.group;
#ifdef TEXTURED
	// The base colour map, times the item's colour (the app passes its tint over the
	// material, white for none), as glTF multiplies factor and texture.
	if (view_mode == 1 && maps.x > 0.5) albedo = base.rgb * base_map.Sample(uv).rgb;
	// The texture paint layers stand over everything else (render.Textured_Mesh.paint).
	if (view_mode == 1) {
		float4 p = paint_map.Sample(uv);
		albedo = albedo * (1.0 - p.a) + p.rgb;
	}
	if (view_mode == 3) albedo *= uv_checker(uv);
#endif
	// The view's Colour: the paint, the textures and the material's colour taken toward
	// clay, so the form reads under them (a uniform branch, skipped at full colour).
	if (fade.w > 0.0 && frag_in.group.r < 0.0) albedo = lerp(albedo, fade.rgb, fade.w);
	// The density preview: the cells a remesh would build, every other one darker and
	// each edged with a thin line, so a cell reads as about one vertex of the result.
	// Where cells shrink under about three pixels the pattern fades to its mean rather
	// than shimmer; the panel still says the size.
	if (checker.w > 0.0) {
		float3 c = (frag_in.mesh_pos - checker.xyz) / checker.w;
		float3 width = max(fwidth(c), float3(1e-6)); // cells per pixel, along each axis
		float per_px = max(max(width.x, width.y), width.z);
		float3 f = frac(c);
		float3 edge = min(f, 1.0 - f) / width; // pixels to the nearest cell face
		// The edge lines only while cells are big enough for a line to leave room for the
		// cell: from 16 pixels across they show in full, under 8 none.
		float line = (1.0 - smoothstep(0.5, 1.5, min(min(edge.x, edge.y), edge.z))) * (1.0 - smoothstep(1.0 / 16.0, 1.0 / 8.0, per_px));
		float3 cell = floor(c);
		float odd = glsl_mod(cell.x + cell.y + cell.z, 2.0);
		float shade = lerp(1.0, 0.72, odd) * (1.0 - 0.35 * line);
		float tiny = smoothstep(0.2, 0.4, per_px);
		albedo *= lerp(shade, 0.86, tiny);
	}
	float3x3 rig = float3x3(light_x.xyz, light_y.xyz, light_z.xyz);
	float ambient = light_x.w;
	// Masked areas show darker, as in ZBrush, unless the view leaves the mask out (style.z).
	float shown_mask = frag_in.mask * (1.0 - style.z);
	albedo *= 1.0 - 0.7 * shown_mask;
	float highlight = 1.0 - 0.5 * shown_mask;
	// Unlit: the Flat look, the colour as it is with no light, as Blender's Flat lighting
	// shows it; exposed, with cavity and ridge, but not tone mapped.
	if (view_pass == 7) return float4(srgb_encode(albedo * relief * exp2(look.x)), opacity());

	if (surf.w > 0.5) {
		// The matcap's sphere where it faces the way this pixel's normal does as the eye
		// sees it: Blender's basis around the ray to the eye, which keeps the lookup right
		// toward the edges of a perspective view instead of sliding with it. The picture's
		// own light and sheen stand in for the lights, tinted by the colour (and paint and
		// mask); it is already a finished look, so it is exposed but not tone mapped.
		float k = 1.0 / (1.0 + v.z);
		float b = -v.x * v.y * k;
		float2 m = float2(dot(float3(1.0 - v.x * v.x * k, b, -v.x), n), dot(float3(b, 1.0 - v.y * v.y * k, -v.y), n));
		float3 lit = matcap.Sample(float2(0.5 + 0.496 * m.x, 0.5 - 0.496 * m.y)).rgb;
		return float4(srgb_encode(lit * albedo * relief * exp2(look.x)), opacity());
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
		float3 diffuse = albedo * (1.0 - metallic);
		float3 f0 = lerp(float3(0.04), albedo, metallic);
		float n_dot_v = max(dot(n, v), 1e-4);
		float3 r = reflect(-v, n);
		float3 comp = energy_compensation(f0, n_dot_v, rough);

		float3 color = float3(0.0);
#ifdef AREA_LIGHTS
		// The area lights in a loop of their own, compiled only into the shaders drawn
		// while one is on (mesh_area and textured_area), so the others run as lean as
		// before area lights: their code in this shader at all, even skipped, cost a scene
		// of none about a third more fragment time on SwiftShader, and its registers would
		// be held on every GPU.
		for (int i = 0; i < LIGHT_COUNT; i++) {
			float s = light_color[i].w;
			if (s <= 0.0 || light_pos[i].w < 2.5) continue;
			float3 l;
			float spread;
			float k = area_at(i, l, spread);
			if (k <= 0.0) continue;
			color += direct_sized(n, v, l, area_mirror(i, r), spread, diffuse, f0, a, 1.0 + light_extra[i].x, comp) * light_color[i].rgb * (3.0 * (s * k));
		}
#endif
		for (int i = 0; i < LIGHT_COUNT; i++) {
			float s = light_color[i].w;
			if (s <= 0.0 || light_pos[i].w > 2.5) continue;
			float3 l;
			float spread;
			float k = light_at(i, l, spread);
			if (k <= 0.0) continue;
			float shine = 1.0 + light_extra[i].x;
			float3 lit;
			if (spread > 0.0) {
				lit = direct_sized(n, v, l, nearest_in_light(l, r, spread), spread, diffuse, f0, a, shine, comp);
			} else {
				lit = direct(n, v, l, diffuse, f0, a, shine, comp);
			}
			color += lit * light_color[i].rgb * (3.0 * (s * k));
		}
		// Light from the whole studio or image environment, which turns with the rig: the
		// studio's blurriest version scaled by the ambient light (or the image's harmonics)
		// for the diffuse part, and the reflection blurred by roughness for the specular.
		// The studio's diffuse is dimmed to sit with its lights; an image's is taken at its
		// own Strength, so a white surface in a white environment reads white.
		float2 ab = env_brdf(n_dot_v, rough);
		float3x3 to_rig = transpose(rig);
		if (env.x > 0.5) {
			color += diffuse * irradiance(n) * ao;
		} else if (style.w > 0.5) {
			color += diffuse * studio(mul(n, to_rig), 1.0) * (0.7 * ao * ambient * underside(n, rig));
		} else {
			color += diffuse * studio(mul(n, to_rig), 1.0) * (0.7 * ao * ambient);
		}
		// The reflection's own compensation, from the split-sum fit it is scaled by (its
		// albedo at Fresnel 1 is ab.x + ab.y, not ggx_albedo), as Filament takes it from
		// its own lookup: a white metal in a white environment then reflects exactly white.
		float3 env_comp = 1.0 + f0 * (1.0 / max(ab.x + ab.y, 0.05) - 1.0);
		color += reflected(r, rough, to_rig) * ((f0 * ab.x + ab.y) * env_comp) * (highlight * ao);
		return display(color * relief);
	}

	// The classic studio clay shading: wrap lets light reach past the side facing it,
	// softening the terminator as wax and skin do; 0 is plain Lambert. Each light adds
	// its share in its colour, and a highlight of its own.
	float wrap = shading.w;
	float3 lit = float3(shading.x * ao * ambient);
	float3 spec = float3(0.0);
	float3 mirror = reflect(-v, n);
#ifdef AREA_LIGHTS
	// The area lights first, in their own loop, as in the physically based path above.
	float classic_a = sqrt(2.0 / (shading.z + 2.0));
	for (int i = 0; i < LIGHT_COUNT; i++) {
		float s = light_color[i].w;
		if (s <= 0.0 || light_pos[i].w < 2.5) continue;
		float3 l;
		float spread;
		s *= area_at(i, l, spread);
		if (s <= 0.0) continue;
		lit += light_color[i].rgb * (max((dot(n, l) + wrap) / (1.0 + wrap), 0.0) * s);
		float3 h = normalize(area_mirror(i, mirror) + v);
		float shrink = (1.0 + light_extra[i].x) * widened(classic_a, spread);
		spec += light_color[i].rgb * (pow(max(dot(n, h), 0.0), shading.z) * shading.y * s * shrink);
	}
#endif
	for (int i = 0; i < LIGHT_COUNT; i++) {
		float s = light_color[i].w;
		if (s <= 0.0 || light_pos[i].w > 2.5) continue;
		float3 l;
		float spread;
		s *= light_at(i, l, spread);
		if (s <= 0.0) continue;
		lit += light_color[i].rgb * (max((dot(n, l) + wrap) / (1.0 + wrap), 0.0) * s);
		// A light with a size: the highlight from its point nearest the mirror direction,
		// dimmed as it widens, taking the Blinn-Phong power as a GGX width
		// (a = sqrt(2 / (power + 2)), Walter et al.); every light's Highlight scales it.
		float3 h = normalize(l + v);
		float shrink = 1.0 + light_extra[i].x;
		if (spread > 0.0) {
			h = normalize(nearest_in_light(l, mirror, spread) + v);
			shrink *= widened(sqrt(2.0 / (shading.z + 2.0)), spread);
		}
		spec += light_color[i].rgb * (pow(max(dot(n, h), 0.0), shading.z) * shading.y * s * shrink);
	}
	float rim  = pow(1.0 - max(dot(n, v), 0.0), 3.0) * 0.25;
	if (style.w > 0.5) {
		// A styled look, as in a studio's sculpt photographs: the ambient light falls off
		// under the forms, so a chin shades the neck, and the rim is narrower and gathers on
		// the upper silhouettes, where a light from above and behind would catch them.
		lit -= float3(shading.x * ao * ambient * (1.0 - underside(n, rig)));
		rim = pow(1.0 - max(dot(n, v), 0.0), 4.0) * style.x * lerp(0.3, 1.0, sky_facing(n, rig));
	}
	float3 color = albedo * lit + (spec + rim) * highlight;
	// The viewport texture is a UNORM texture the interface shows as-is, so the shader
	// encodes for the display itself.
	return display(color * relief);
}
