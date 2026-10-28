// The last of the finishing stack (render/finish.odin), on encoded values: film grain and a
// dither. finish.frag.slang ends with them, or sharpen.frag.slang does when it runs, since
// sharpening grain would only coarsen it.

// A value from -1 to 1 fixed to a lattice point and the grain's pattern `seed`.
float lattice_noise(int2 p, uint seed) {
	uint h = uint(p.x) * 0x8da6b343u ^ uint(p.y) * 0xd8163841u ^ seed * 0xcb1ab31fu;
	h ^= h >> 15;
	h *= 0x2c1b3c6du;
	h ^= h >> 12;
	h *= 0x297a2d39u;
	h ^= h >> 15;
	return float(h) / 2147483647.5 - 1.0;
}

// The grain at a pixel: lattice noise `size` pixels across, smoothly blended between
// lattice points, so a larger size reads as coarser film rather than blocks.
float grain_at(float2 px, float size, uint seed) {
	float2 at = px / size;
	int2 q = int2(floor(at));
	float2 f = at - float2(q);
	f = f * f * (3.0 - 2.0 * f);
	float a = lerp(lattice_noise(q, seed), lattice_noise(q + int2(1, 0), seed), f.x);
	float b = lerp(lattice_noise(q + int2(0, 1), seed), lattice_noise(q + int2(1, 1), seed), f.x);
	return lerp(a, b, f.y);
}

// Jimenez's interleaved gradient noise, from 0 to 1: a dither fixed to the pixel that does
// not line up with the ordered one clear.frag.slang already put in the source.
float gradient_noise(float2 px) {
	return frac(52.9829189 * frac(dot(px, float2(0.06711056, 0.00583715))));
}

// Encoded values `e` at pixel `px` with film grain of `strength` (0 none to 1) and `size`
// pixels in pattern `seed`, strongest in the midtones, as film's is, and none in black or
// white; then a dither of one 8-bit step, so a curve that steepens a gradient shows no bands.
float3 grain_and_dither(float3 e, float2 px, float strength, float size, uint seed) {
	if (strength > 0.0) {
		float l = clamp(dot(e, float3(0.2126, 0.7152, 0.0722)), 0.0, 1.0);
		e += 0.12 * strength * 4.0 * l * (1.0 - l) * grain_at(px, size, seed);
	}
	return e + (gradient_noise(px) - 0.5) / 255.0;
}
