#version 450
// Glyphs and shapes take their coverage from the single-channel atlas (shapes sample its
// white corner); an image, such as the viewport, is drawn as it is, tinted by the colour.
layout(location = 0) in vec2 in_uv;
layout(location = 1) in vec4 in_color;

layout(set = 2, binding = 0) uniform sampler2D tex;

layout(set = 3, binding = 0) uniform Ui_Fragment_Uniforms {
	vec4 params; // xy: what turns the coordinates into 0 to 1 (one over the atlas size, or 1); z: 1 for an image
};

layout(location = 0) out vec4 out_color;

void main() {
	vec4 s = texture(tex, in_uv * params.xy);
	out_color = params.z > 0.5 ? in_color * s : vec4(in_color.rgb, in_color.a * s.r);
}
