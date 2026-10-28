// The finishing stack (render/finish.odin): what the viewport shows, finished as a
// camera's picture is. The source is either display values, mostly made with PBR
// Neutral, which neutral_inverse turns back into the exposed linear light they came
// from, or render mode's exposed linear light itself. In linear light, as a lens and a
// sensor see it, come the chromatic aberration, the bloom, the vignette, white balance,
// contrast and saturation, the order Unreal's post stack keeps; then the tone curve; then,
// on the encoded values, lift, gamma and gain, film grain and a dither, so a curve that
// steepens a gradient shows no bands. When sharpening runs, sharpen.frag.slang takes the
// grain and the dither, and this pass writes its encoded values unrounded.
// SDL_GPU SPIR-V conventions: fragment samplers in set 2, uniform buffers in set 3.
#include "common.slang"
#include "finish_grain.slang"
// Filtered bilinearly: the aberration's taps fall between pixels. Exact pixels are read with Load.
[[vk::binding(0, 2)]] Sampler2D source;
// The bloom chain's last upsample, half the source's size or less, in linear light.
[[vk::binding(1, 2)]] Sampler2D bloom;

[[vk::binding(0, 3)]] cbuffer Finish_Uniforms {
	// x: the tone curve (0 Neutral, 1 AgX, 2 ACES), y: 1 when the source is linear light,
	// z: contrast (1 none), w: saturation (1 none)
	float4 params;
	// The white balance as the columns of a matrix on linear light (finish.odin).
	float4 white_x;
	float4 white_y;
	float4 white_z;
	// x: the vignette's strength (0 none), y: its softness, z: the source's width over its height
	float4 vignette;
	// x: lift (0 none), y: gamma (1 none), z: gain (1 none), w: the grain's strength (0 none)
	float4 grade;
	// x: the grain's size in pixels (1 to 4), y: its pattern, which moves on only when the
	// picture changes, so a still view stays still and a moving one shows no fixed screen of it
	float4 grain;
	// x: the share of the light the bloom replaces (0 none), y: the chromatic aberration's
	// spread, as a share of the distance from the middle (0 none), z: 1 when this pass ends
	// the picture with the grain and dither, 0 when sharpening follows, w: the bloom's
	// threshold in linear light (0 none)
	float4 effects;
};

#include "display.slang"
#include "bloom.slang"

// AgX's method (Troy Sobotka's, Blender's default view since 4.0), built here from its
// published description: each colour pulled a fifth of the way toward its channels' mean
// (the inset), so bright saturated light runs toward white instead of skewing hue; log
// encoded over the 16.5 stops from -12.47 to +4.03 about mid grey; through a sigmoid,
// slope 2 at mid grey, which it puts at half the display's range, rolling into black and
// white as power hyperbolas (powers 3 and 2.85, a match to AgX's base contrast within half
// a percent); pushed back out twice as far from the mean as the inset pulled in, which
// gives back the colour the per-channel curve takes from the midtones, as Blender's AgX
// does since 4.0 (so clay stays clay-coloured), while bright light still runs to white;
// and the 2.2 power the sigmoid is made for undone. The two scales put the ends at
// exactly 0 and 1 (finish.odin's agx_scale).
float agx_sigmoid(float x) {
	const float PIVOT_X = 0.6060605707714036;
	const float SLOPE = 2.0;
	bool shoulder = x >= PIVOT_X;
	float scale = shoulder ? 0.5593522525840448 : 0.5122773845447605;
	float power = shoulder ? 2.85 : 3.0;
	float u = SLOPE * (x - PIVOT_X) / scale;
	return 0.5 + scale * u / pow(1.0 + pow(abs(u), power), 1.0 / power);
}

float3 agx(float3 c) {
	const float LOW = -12.47393;
	const float HIGH = 4.026069;
	float3 inset = 0.8 * c + 0.2 * dot(c, float3(1.0 / 3.0));
	float3 x = (clamp(log2(max(inset, float3(1e-10))), LOW, HIGH) - LOW) / (HIGH - LOW);
	float3 s = float3(agx_sigmoid(x.r), agx_sigmoid(x.g), agx_sigmoid(x.b));
	float3 outset = (s - 0.4 * dot(s, float3(1.0 / 3.0))) / 0.6;
	return pow(clamp(outset, 0.0, 1.0), float3(2.2));
}

// ACES 1.x, its reference rendering and sRGB output transforms as Stephen Hill fitted
// them (MIT, assets/licenses/ACES-fit-LICENSE.txt): into the ACES working colours, the
// fitted curve, and back to linear sRGB. Each matrix is written as its columns, the
// transpose of its maths, so mul(v, M) applies it.
float3 aces(float3 c) {
	const float3x3 IN = float3x3(
		0.59719, 0.07600, 0.02840,
		0.35458, 0.90834, 0.13383,
		0.04823, 0.01566, 0.83777);
	const float3x3 OUT = float3x3(
		1.60475, -0.10208, -0.00327,
		-0.53108, 1.10813, -0.07276,
		-0.07367, -0.00605, 1.07602);
	float3 v = mul(c, IN);
	float3 a = v * (v + 0.0245786) - 0.000090537;
	float3 b = v * (0.983729 * v + 0.4329510) + 0.238081;
	return clamp(mul(a / b, OUT), 0.0, 1.0);
}

// What AgX's and ACES's light is scaled by first: mid grey (0.18) then shows as
// tone_map shows it (finish.odin's tests check both).
static const float AGX_EXPOSURE = 0.5942082129838109;
static const float ACES_EXPOSURE = 1.2159790709970744;

// Linear sRGB's luminance (Rec. 709).
float luminance(float3 c) {
	return dot(c, float3(0.2126, 0.7152, 0.0722));
}

// Linear light at pixel `frag` through the controls that work on light, then the tone
// curve: what the display shows of it.
float3 graded(float3 c, float2 frag) {
	// The vignette, as a lens darkens toward the corners: by the distance from the middle,
	// 1 in a corner, over the outer `softness` of it.
	if (vignette.x > 0.0) {
		float2 uv = (frag / float2(texture_size(source)) - 0.5) * float2(vignette.z, 1.0);
		float r = length(uv) / length(float2(vignette.z, 1.0) * 0.5);
		float soft = max(vignette.y, 0.05);
		c *= 1.0 - vignette.x * smoothstep(0.0, 1.0, (r - (1.0 - soft)) / soft);
	}
	c = mul(c, float3x3(white_x.xyz, white_y.xyz, white_z.xyz));
	// Contrast about mid grey in stops, so it steepens the middle without clipping either end.
	if (params.z != 1.0) c = 0.18 * pow(max(c, float3(0.0)) / 0.18, float3(params.z));
	c = max(lerp(float3(luminance(c)), c, params.w), float3(0.0));

	// AgX and ACES take the light scaled so mid grey shows as Neutral shows it (sRGB 0.41),
	// so changing the curve changes how light rolls off, not how bright the picture is.
	if (params.x > 1.5) return aces(c * ACES_EXPOSURE);
	if (params.x > 0.5) return agx(c * AGX_EXPOSURE);
	return tone_map(c);
}

// What source value `v` holds: its exposed linear light `c`, and for display values the
// colour shown and what Neutral gives back short of it (main says why that matters).
void decode(float3 v, out float3 c, out float3 shown, out float3 residual) {
	shown = float3(0.0);
	residual = float3(0.0);
	if (params.y > 0.5) {
		c = max(v, float3(0.0));
	} else {
		shown = srgb_decode(v);
		c = neutral_inverse(shown);
		residual = shown - tone_map(c);
	}
}

// Lateral chromatic aberration, as a lens that bends each wavelength by a little more than
// the last: the source read at five scales about the middle, each a band of the spectrum
// from red (scaled least) to blue (most), the bands of each channel weighing one in all, so
// white stays white and the middle of the picture stays sharp. In linear light, and on what
// main reads of each pixel, so the fringes reach every path through it.
static const int ABERRATION_TAPS = 5;
void aberrated(float2 frag, out float3 c, out float3 shown, out float3 residual) {
	float2 size = float2(texture_size(source));
	float2 from_middle = frag / size - 0.5;
	c = float3(0.0);
	shown = float3(0.0);
	residual = float3(0.0);
	float3 total = float3(0.0);
	for (int i = 0; i < ABERRATION_TAPS; i++) {
		float t = float(i) / float(ABERRATION_TAPS - 1);
		float3 w = float3(saturate(1.0 - 2.0 * t), 1.0 - abs(2.0 * t - 1.0), saturate(2.0 * t - 1.0));
		float2 at = 0.5 + from_middle * (1.0 + effects.y * (t - 0.5));
		float3 tc, ts, tr;
		decode(source.SampleLevel(at, 0.0).rgb, tc, ts, tr);
		c += w * tc;
		shown += w * ts;
		residual += w * tr;
		total += w;
	}
	c /= total;
	shown /= total;
	residual /= total;
}

// Bloom, as light scattered in a lens and a sensor: a share of each pixel's light above the
// threshold swapped for that light blurred around it, so it brightens nothing in all and glows
// only where bright light meets dark (Unity HDRP's energy-conserving mix, which with no
// threshold is a plain lerp). Light under the threshold stays where it is, unscattered.
float3 bloomed(float3 c, float2 frag) {
	if (effects.x <= 0.0) return c;
	float3 b = bloom.SampleLevel(frag / float2(texture_size(source)), 0.0).rgb;
	return c + effects.x * (b - above_threshold(c, effects.w));
}

float4 main(float4 frag_coord : SV_Position) : SV_Target0 {
	int2 px = int2(frag_coord.xy);
	float4 s = source.Load(int3(px, 0));
	// What Neutral gives back short of the colour shown: nothing for its own colours but
	// what an 8-bit step loses near white, where the shoulder is steep; much for a colour
	// it never shows (a MatCap's highlight, a wire, a picked background), whose light is
	// a guess. Laid back over the curve's result, it keeps such colours as they were, and
	// with every control at none, the picture to its 8-bit step.
	float3 c, shown, residual;
	if (effects.y > 0.0) aberrated(frag_coord.xy, c, shown, residual);
	else decode(s.rgb, c, shown, residual);
	float3 kept = graded(bloomed(c, frag_coord.xy), frag_coord.xy) + residual;
	if (params.y < 0.5) {
		// Two places Neutral's guess cannot be trusted: a colour far from any it shows,
		// and anything near white, where its shoulder sends lights of every purity to
		// nearly the same colour, so an 8-bit step can turn a pink highlight's guess into
		// pure red light. The guessed light's colour would then show through a curve that
		// rolls it off differently (a MatCap's highlight going red at its rim), so there
		// the colour shown is instead scaled, channel by channel, as the finish changes a
		// grey of its brightness: its hue and purity stay, and the white balance, vignette
		// and curve still reach it. The bloom adds to it what it adds to that grey.
		float3 grey = neutral_inverse(float3(luminance(shown)));
		float3 grey_graded = graded(grey, frag_coord.xy);
		float3 scaled = shown * grey_graded / max(tone_map(grey), float3(1e-4));
		if (effects.x > 0.0) scaled += graded(bloomed(grey, frag_coord.xy), frag_coord.xy) - grey_graded;
		float off = smoothstep(0.01, 0.05, max(abs(residual.r), max(abs(residual.g), abs(residual.b))));
		float bright = smoothstep(0.85, 0.97, max(shown.r, max(shown.g, shown.b)));
		kept = lerp(kept, scaled, max(off, bright));
	}
	float3 e = srgb_encode(kept);

	// Lift, gamma and gain on the encoded values, as a grading panel's three wheels.
	e = pow(max(grade.z * (e + grade.x * (1.0 - e)), float3(0.0)), float3(1.0 / grade.y));
	if (effects.z > 0.5) e = grain_and_dither(e, frag_coord.xy, grade.w, grain.x, asuint(grain.y));
	return float4(e, s.a);
}
