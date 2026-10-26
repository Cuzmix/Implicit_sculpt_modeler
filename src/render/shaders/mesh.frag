#version 450
// SDL_GPU SPIR-V conventions: fragment uniform buffers live in set 3.
layout(location = 0) in vec3 in_view_normal;
layout(location = 1) in vec3 in_view_pos;
layout(location = 2) in float in_mask;
layout(location = 3) in vec4 in_paint;
layout(location = 4) flat in vec3 in_group;
layout(location = 5) in vec3 in_mesh_pos;

layout(set = 3, binding = 0) uniform Material_Uniforms {
	vec4 base_color;
	vec4 params;  // x: ambient, y: specular strength (below 0: flat base_color, for lines), z: specular power, w: wrap
	vec4 surface; // x: metallic, y: roughness (0: the classic shading above, else physically based), z: 1 for flat shading
	vec4 checker; // the density preview: xyz the first lattice point in mesh space, w the cell size (0: none)
};

layout(location = 0) out vec4 out_color;

const float PI = 3.14159265;

// Lights are fixed relative to the camera, like a studio clay render.
const vec3 KEY_DIR  = normalize(vec3(-0.5, 0.6, 0.6));
const vec3 FILL_DIR = normalize(vec3(0.7, -0.2, 0.4));

// The studio the physically based materials reflect, in view space: a grey sky over a
// dark floor and a large softbox behind the key light. `rough` (0 to 1) blurs it, standing
// in for a prefiltered environment map at no memory and a few instructions.
vec3 studio(vec3 dir, float rough) {
	float w = 0.08 + 0.9 * rough;
	float up = smoothstep(-w, w, dir.y);
	vec3 c = mix(vec3(0.05, 0.05, 0.055), vec3(0.42, 0.44, 0.48), up);
	// A brighter band at the horizon reads as the far wall of the studio.
	c += vec3(0.12) * exp(-abs(dir.y) / (0.06 + 0.5 * rough));
	// The softbox: a lobe whose width grows with roughness while its energy stays about
	// the same, as a blurred reflection of a bright light does.
	float e = mix(400.0, 3.0, sqrt(rough));
	c += vec3(4.0, 3.9, 3.7) * pow(max(dot(dir, KEY_DIR), 0.0), e) * (e + 2.0) / 402.0;
	return c;
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

void main() {
	if (params.y < 0.0) {
		out_color = vec4(pow(base_color.rgb, vec3(1.0 / 2.2)), 1.0);
		return;
	}
	vec3 v = normalize(-in_view_pos);
	vec3 n;
	if (surface.z > 0.5) {
		// Flat shading: the triangle's own normal from how the position changes across
		// the screen, so faceting costs no vertex data or extra pass.
		n = normalize(cross(dFdx(in_view_pos), dFdy(in_view_pos)));
		if (dot(n, v) < 0.0) n = -n;
	} else {
		n = normalize(in_view_normal);
		if (!gl_FrontFacing) n = -n;
	}

	// Paint covers the clay as far as it reaches; groups show instead of both.
	vec3 albedo = mix(base_color.rgb, in_paint.rgb, in_paint.a);
	if (in_group.r >= 0.0) albedo = in_group;
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
	// Masked areas show darker, as in ZBrush.
	albedo *= 1.0 - 0.7 * in_mask;
	float highlight = 1.0 - 0.5 * in_mask;

	if (surface.y > 0.0) {
		float metallic = clamp(surface.x, 0.0, 1.0);
		float rough = clamp(surface.y, 0.04, 1.0);
		float a = rough * rough;
		vec3 diffuse = albedo * (1.0 - metallic);
		vec3 f0 = mix(vec3(0.04), albedo, metallic);
		float n_dot_v = max(dot(n, v), 1e-4);

		vec3 color = direct(n, v, KEY_DIR, diffuse, f0, a) * 3.0;
		color += direct(n, v, FILL_DIR, diffuse, f0, a) * 0.35;
		// Light from the whole studio: its blurriest version for the diffuse part, and
		// the reflection blurred by roughness for the specular.
		vec3 r = reflect(-v, n);
		vec2 ab = env_brdf(n_dot_v, rough);
		color += diffuse * studio(n, 1.0) * 0.7;
		color += studio(r, rough) * (f0 * ab.x + ab.y) * highlight;
		// Filmic curve (Narkowicz's ACES fit) so bright reflections roll off instead of clipping.
		color = clamp((color * (2.51 * color + 0.03)) / (color * (2.43 * color + 0.59) + 0.14), 0.0, 1.0);
		out_color = vec4(pow(color, vec3(1.0 / 2.2)), 1.0);
		return;
	}

	// The classic studio clay shading: wrap lets light reach past the side facing it,
	// softening the terminator as wax and skin do; 0 is plain Lambert.
	float wrap = params.w;
	float key  = max((dot(n, KEY_DIR) + wrap) / (1.0 + wrap), 0.0);
	float fill = max((dot(n, FILL_DIR) + wrap) / (1.0 + wrap), 0.0) * 0.3;
	float rim  = pow(1.0 - max(dot(n, v), 0.0), 3.0) * 0.25;
	vec3 h     = normalize(KEY_DIR + v);
	float spec = pow(max(dot(n, h), 0.0), params.z) * params.y;
	vec3 color = albedo * (params.x + key + fill) + vec3(spec + rim) * highlight;
	// Linear to sRGB; the viewport target is a UNORM texture the interface shows as-is.
	out_color = vec4(pow(color, vec3(1.0 / 2.2)), 1.0);
}
