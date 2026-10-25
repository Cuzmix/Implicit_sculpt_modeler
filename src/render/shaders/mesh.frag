#version 450
// SDL_GPU SPIR-V conventions: fragment uniform buffers live in set 3.
layout(location = 0) in vec3 in_view_normal;
layout(location = 1) in vec3 in_view_pos;
layout(location = 2) in float in_mask;

layout(set = 3, binding = 0) uniform Material_Uniforms {
	vec4 base_color;
	vec4 params; // x: ambient, y: specular strength (below 0: flat base_color, for lines), z: specular power, w: wrap
};

layout(location = 0) out vec4 out_color;

void main() {
	if (params.y < 0.0) {
		out_color = vec4(pow(base_color.rgb, vec3(1.0 / 2.2)), 1.0);
		return;
	}
	// Lights are fixed relative to the camera, like a studio clay render.
	vec3 n = normalize(in_view_normal);
	if (!gl_FrontFacing) n = -n;
	vec3 v = normalize(-in_view_pos);
	vec3 key_dir  = normalize(vec3(-0.5, 0.6, 0.6));
	vec3 fill_dir = normalize(vec3(0.7, -0.2, 0.4));

	// Wrap lets light reach past the side facing it, softening the terminator as wax
	// and skin do; 0 is plain Lambert.
	float wrap = params.w;
	float key  = max((dot(n, key_dir) + wrap) / (1.0 + wrap), 0.0);
	float fill = max((dot(n, fill_dir) + wrap) / (1.0 + wrap), 0.0) * 0.3;
	float rim  = pow(1.0 - max(dot(n, v), 0.0), 3.0) * 0.25;
	vec3 h     = normalize(key_dir + v);
	float spec = pow(max(dot(n, h), 0.0), params.z) * params.y;

	// Masked areas show darker, as in ZBrush.
	vec3 albedo = base_color.rgb * (1.0 - 0.7 * in_mask);
	vec3 color = albedo * (params.x + key + fill) + vec3(spec + rim) * (1.0 - 0.5 * in_mask);
	// Linear to sRGB; the viewport target is a UNORM texture shown as-is by ImGui.
	out_color = vec4(pow(color, vec3(1.0 / 2.2)), 1.0);
}
