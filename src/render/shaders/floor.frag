#version 450
// One plane of the floor grid: each pixel's ray meets the plane, and the point it meets
// is lit where it lies on a grid line. Lines are anti-aliased by how far the plane's
// coordinates move across a pixel, so they stay one pixel wide at any distance or slant;
// the minor lines fade out where their cells get too small to tell apart, and every line
// fades out toward the edge of the area round the scene. The point's own depth is
// written, so a mesh in front of the plane hides it and one behind it is crossed by it.

// SDL_GPU SPIR-V conventions: fragment uniform buffers live in set 3.
layout(set = 3, binding = 0) uniform Floor_Uniforms {
	mat4 inv_view_proj;
	mat4 view_proj;
	vec4 plane;  // x: the axis across the plane (0, 1 or 2), y: where along it the plane sits
	vec4 grid;   // x: a cell's size, y: the radius the lines fade out by, z: 1 to draw the axes
	vec4 center; // xyz: the middle of the area the grid covers
};

layout(location = 0) in vec2 in_ndc;
layout(location = 0) out vec4 out_color;

// The share of the pixel a line at every whole multiple of the coordinates covers, from
// the coordinates in cells and how many cells a pixel spans.
float lines(vec2 cells, vec2 per_pixel) {
	vec2 off = abs(fract(cells - 0.5) - 0.5) / max(per_pixel, vec2(1e-6));
	return 1.0 - min(min(off.x, off.y), 1.0);
}

void main() {
	vec4 a = inv_view_proj * vec4(in_ndc, 0.0, 1.0);
	vec4 b = inv_view_proj * vec4(in_ndc, 1.0, 1.0);
	vec3 from = a.xyz / a.w;
	vec3 dir = b.xyz / b.w - from;
	int k = int(plane.x + 0.5);
	// The ray runs from the near plane (t = 0) to the far one (t = 1), for a perspective
	// and an orthographic view alike. Nothing is discarded until the derivatives below are
	// taken, as they are undefined where neighbouring pixels have left the shader.
	float across = abs(dir[k]) < 1e-9 ? 1e-9 : dir[k];
	float t = (plane.y - from[k]) / across;
	vec3 hit = from + t * dir;
	// The plane's own two axes, in the order X, Y, Z.
	int i = k == 0 ? 1 : 0;
	int j = k == 2 ? 1 : 2;
	vec2 uv = vec2(hit[i], hit[j]);

	float cell = grid.x;
	vec2 minor_cells = uv / cell;
	vec2 minor_px = fwidth(minor_cells);
	vec2 uv_px = fwidth(uv);
	vec2 major_cells = minor_cells / 5.0;
	vec2 major_px = minor_px / 5.0;
	// Cells under about four pixels across blur into a flat tint: fade them out first, and
	// the major ones likewise further off.
	float minor = lines(minor_cells, minor_px) * (1.0 - smoothstep(0.12, 0.3, max(minor_px.x, minor_px.y)));
	float major = lines(major_cells, major_px) * (1.0 - smoothstep(0.12, 0.3, max(major_px.x, major_px.y)));

	vec2 mid = vec2(center[i], center[j]);
	float fade = 1.0 - smoothstep(0.55, 1.0, length(uv - mid) / max(grid.y, 1e-6));

	vec3 color = vec3(0.62);
	float alpha = max(minor * 0.22, major * 0.45);
	if (grid.z > 0.5) {
		// The line where the plane's first coordinate is 0 runs along its second axis, and
		// the other way round: each in that axis's colour (X red, Y green, Z blue).
		const vec3 AXIS[3] = vec3[3](vec3(0.86, 0.3, 0.3), vec3(0.42, 0.8, 0.36), vec3(0.32, 0.52, 0.95));
		vec2 off = abs(uv) / max(uv_px, vec2(1e-6));
		float along_j = 1.0 - min(off.x / 1.5, 1.0);
		float along_i = 1.0 - min(off.y / 1.5, 1.0);
		if (along_j > 0.0 || along_i > 0.0) {
			color = along_j >= along_i ? AXIS[j] : AXIS[i];
			alpha = max(alpha, max(along_i, along_j) * 0.9);
		}
	}
	alpha *= fade;

	vec4 clip = view_proj * vec4(hit, 1.0);
	float depth = clip.z / clip.w;
	// Parallel to the plane, behind the eye or past the far plane, or no line here.
	if (abs(dir[k]) < 1e-9 || t < 0.0 || t > 1.0 || depth < 0.0 || depth > 1.0 || alpha <= 0.002) discard;
	gl_FragDepth = depth;
	out_color = vec4(color, alpha);
}
