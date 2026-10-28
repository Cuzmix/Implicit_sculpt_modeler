#version 450
#extension GL_GOOGLE_include_directive : require
// The finishing stack (render/finish.odin): what the viewport shows, finished as a
// camera's picture is. The source is either display values, mostly made with PBR
// Neutral, which neutral_inverse turns back into the exposed linear light they came
// from, or render mode's exposed linear light itself. In linear light, as a lens and a sensor see it,
// come the vignette, white balance, contrast and saturation; then the tone curve; then,
// on the encoded values, lift, gamma and gain, film grain and an ordered dither, so a
// curve that steepens a gradient shows no bands.
// SDL_GPU SPIR-V conventions: fragment samplers in set 2, uniform buffers in set 3.
layout(set = 2, binding = 0) uniform sampler2D source;

layout(set = 3, binding = 0) uniform Finish_Uniforms {
	// x: the tone curve (0 Neutral, 1 AgX, 2 ACES), y: 1 when the source is linear light,
	// z: contrast (1 none), w: saturation (1 none)
	vec4 params;
	// The white balance as the columns of a matrix on linear light (finish.odin).
	vec4 white_x;
	vec4 white_y;
	vec4 white_z;
	// x: the vignette's strength (0 none), y: its softness, z: the source's width over its height
	vec4 vignette;
	// x: lift (0 none), y: gamma (1 none), z: gain (1 none), w: the grain's strength (0 none)
	vec4 grade;
	// x: the grain's size in pixels (1 to 4), y: its pattern, which moves on only when the
	// picture changes, so a still view stays still and a moving one shows no fixed screen of it
	vec4 grain;
};

layout(location = 0) out vec4 out_color;

#include "display.glsl"

// AgX's method (Troy Sobotka's, Blender's default view since 4.0), built here from its
// published description: each colour pulled a fifth of the way toward its channels' mean
// (the inset), so bright saturated light runs toward white instead of skewing hue; log
// encoded over the 16.5 stops from -12.47 to +4.03 about mid grey; through a sigmoid,
// slope 2 at mid grey, which it puts at half the display's range, rolling into black and
// white as power hyperbolas (powers 3 and 2.85, a match to AgX's base contrast within half
// a percent); pushed back out twice as far from the mean as the inset pulled in, which
// gives back the colour the per-channel curve takes from the midtones, as Blender's AgX
// does since 4.0 (so clay stays clay-coloured), while bright light still runs to white;
// and the 2.2 power the sigmoid is made for undone. The two scales put the ends at exactly 0 and 1 (finish.odin's agx_scale).
float agx_sigmoid(float x) {
	const float PIVOT_X = 0.6060605707714036;
	const float SLOPE = 2.0;
	bool shoulder = x >= PIVOT_X;
	float scale = shoulder ? 0.5593522525840448 : 0.5122773845447605;
	float power = shoulder ? 2.85 : 3.0;
	float u = SLOPE * (x - PIVOT_X) / scale;
	return 0.5 + scale * u / pow(1.0 + pow(abs(u), power), 1.0 / power);
}

vec3 agx(vec3 c) {
	const float LOW = -12.47393;
	const float HIGH = 4.026069;
	vec3 inset = 0.8 * c + 0.2 * dot(c, vec3(1.0 / 3.0));
	vec3 x = (clamp(log2(max(inset, vec3(1e-10))), LOW, HIGH) - LOW) / (HIGH - LOW);
	vec3 s = vec3(agx_sigmoid(x.r), agx_sigmoid(x.g), agx_sigmoid(x.b));
	vec3 outset = (s - 0.4 * dot(s, vec3(1.0 / 3.0))) / 0.6;
	return pow(clamp(outset, 0.0, 1.0), vec3(2.2));
}

// ACES 1.x, its reference rendering and sRGB output transforms as Stephen Hill fitted
// them: into the ACES working colours, the fitted curve, and back to linear sRGB.
vec3 aces(vec3 c) {
	const mat3 IN = mat3(
		0.59719, 0.07600, 0.02840,
		0.35458, 0.90834, 0.13383,
		0.04823, 0.01566, 0.83777);
	const mat3 OUT = mat3(
		1.60475, -0.10208, -0.00327,
		-0.53108, 1.10813, -0.07276,
		-0.07367, -0.00605, 1.07602);
	vec3 v = IN * c;
	vec3 a = v * (v + 0.0245786) - 0.000090537;
	vec3 b = v * (0.983729 * v + 0.4329510) + 0.238081;
	return clamp(OUT * (a / b), 0.0, 1.0);
}

// What AgX's and ACES's light is scaled by first: mid grey (0.18) then shows as
// tone_map shows it (finish.odin's tests check both).
const float AGX_EXPOSURE = 0.5942082129838109;
const float ACES_EXPOSURE = 1.2159790709970744;

// Linear sRGB's luminance (Rec. 709).
float luminance(vec3 c) {
	return dot(c, vec3(0.2126, 0.7152, 0.0722));
}

// A value from -1 to 1 fixed to a lattice point and the grain's pattern.
float lattice_noise(ivec2 p) {
	uint h = uint(p.x) * 0x8da6b343u ^ uint(p.y) * 0xd8163841u ^ floatBitsToUint(grain.y) * 0xcb1ab31fu;
	h ^= h >> 15;
	h *= 0x2c1b3c6du;
	h ^= h >> 12;
	h *= 0x297a2d39u;
	h ^= h >> 15;
	return float(h) / 2147483647.5 - 1.0;
}

// The grain at a pixel: lattice noise `size` pixels across, smoothly blended between
// lattice points, so a larger size reads as coarser film rather than blocks.
float grain_at(vec2 px, float size) {
	vec2 at = px / size;
	ivec2 q = ivec2(floor(at));
	vec2 f = at - vec2(q);
	f = f * f * (3.0 - 2.0 * f);
	float a = mix(lattice_noise(q), lattice_noise(q + ivec2(1, 0)), f.x);
	float b = mix(lattice_noise(q + ivec2(0, 1)), lattice_noise(q + ivec2(1, 1)), f.x);
	return mix(a, b, f.y);
}

// Jimenez's interleaved gradient noise, from 0 to 1: a dither fixed to the pixel that does
// not line up with the ordered one clear.frag already put in the source.
float gradient_noise(vec2 px) {
	return fract(52.9829189 * fract(dot(px, vec2(0.06711056, 0.00583715))));
}

// Linear light through the controls that work on light, then the tone curve: what the
// display shows of it.
vec3 graded(vec3 c) {
	// The vignette, as a lens darkens toward the corners: by the distance from the middle,
	// 1 in a corner, over the outer `softness` of it.
	if (vignette.x > 0.0) {
		vec2 uv = (gl_FragCoord.xy / vec2(textureSize(source, 0)) - 0.5) * vec2(vignette.z, 1.0);
		float r = length(uv) / length(vec2(vignette.z, 1.0) * 0.5);
		float soft = max(vignette.y, 0.05);
		c *= 1.0 - vignette.x * smoothstep(0.0, 1.0, (r - (1.0 - soft)) / soft);
	}
	c = mat3(white_x.xyz, white_y.xyz, white_z.xyz) * c;
	// Contrast about mid grey in stops, so it steepens the middle without clipping either end.
	if (params.z != 1.0) c = 0.18 * pow(max(c, vec3(0.0)) / 0.18, vec3(params.z));
	c = max(mix(vec3(luminance(c)), c, params.w), vec3(0.0));

	// AgX and ACES take the light scaled so mid grey shows as Neutral shows it (sRGB 0.41),
	// so changing the curve changes how light rolls off, not how bright the picture is.
	if (params.x > 1.5) return aces(c * ACES_EXPOSURE);
	if (params.x > 0.5) return agx(c * AGX_EXPOSURE);
	return tone_map(c);
}

void main() {
	ivec2 px = ivec2(gl_FragCoord.xy);
	vec4 s = texelFetch(source, px, 0);
	vec3 c;
	// What Neutral gives back short of the colour shown: nothing for its own colours but
	// what an 8-bit step loses near white, where the shoulder is steep; much for a colour
	// it never shows (a MatCap's highlight, a wire, a picked background), whose light is
	// a guess. Laid back over the curve's result, it keeps such colours as they were, and
	// with every control at none, the picture to its 8-bit step.
	vec3 shown = vec3(0.0);
	vec3 residual = vec3(0.0);
	if (params.y > 0.5) {
		c = max(s.rgb, vec3(0.0));
	} else {
		shown = srgb_decode(s.rgb);
		c = neutral_inverse(shown);
		residual = shown - tone_map(c);
	}

	vec3 kept = graded(c) + residual;
	if (params.y < 0.5) {
		// Two places Neutral's guess cannot be trusted: a colour far from any it shows,
		// and anything near white, where its shoulder sends lights of every purity to
		// nearly the same colour, so an 8-bit step can turn a pink highlight's guess into
		// pure red light. The guessed light's colour would then show through a curve that
		// rolls it off differently (a MatCap's highlight going red at its rim), so there
		// the colour shown is instead scaled, channel by channel, as the finish changes a
		// grey of its brightness: its hue and purity stay, and the white balance, vignette
		// and curve still reach it.
		vec3 grey = neutral_inverse(vec3(luminance(shown)));
		vec3 scaled = shown * graded(grey) / max(tone_map(grey), vec3(1e-4));
		float off = smoothstep(0.01, 0.05, max(abs(residual.r), max(abs(residual.g), abs(residual.b))));
		float bright = smoothstep(0.85, 0.97, max(shown.r, max(shown.g, shown.b)));
		kept = mix(kept, scaled, max(off, bright));
	}
	vec3 e = srgb_encode(kept);

	// Lift, gamma and gain on the encoded values, as a grading panel's three wheels.
	e = pow(max(grade.z * (e + grade.x * (1.0 - e)), vec3(0.0)), vec3(1.0 / grade.y));
	// Film grain, strongest in the midtones, as film's is, and none in black or white.
	if (grade.w > 0.0) {
		float l = clamp(dot(e, vec3(0.2126, 0.7152, 0.0722)), 0.0, 1.0);
		e += 0.12 * grade.w * 4.0 * l * (1.0 - l) * grain_at(gl_FragCoord.xy, grain.x);
	}
	e += (gradient_noise(gl_FragCoord.xy) - 0.5) / 255.0;
	out_color = vec4(e, s.a);
}
