// A thin film's reflectance over a surface (soap bubbles, oil on water, anodised metal):
// light reflected off the film's top and off the surface under it interferes, brighter
// or darker by wavelength as the film's thickness and the angle change the path between
// them. Airy's formula for one film between air and the surface, for s- and
// p-polarised light averaged, at three wavelengths standing for red, green and blue; the
// surface's IOR per channel comes from its reflectance straight on (`f0`), real, so a
// metal is taken as a dielectric of its reflectance. `c1` is the cosine to the eye, `nm`
// the thickness in nanometres, `n2` the film's IOR.
float3 thin_film(float c1, float3 f0, float nm, float n2) {
	c1 = clamp(c1, 1e-4, 1.0);
	float s1 = 1.0 - c1 * c1;
	float c2 = sqrt(max(1.0 - s1 / (n2 * n2), 0.0));
	float3 root = sqrt(clamp(f0, float3(0.0), float3(0.98)));
	float3 n3 = (1.0 + root) / (1.0 - root);
	float3 c3 = sqrt(max(1.0 - s1 / (n3 * n3), float3(0.0)));
	float r12s = (c1 - n2 * c2) / (c1 + n2 * c2);
	float r12p = (n2 * c1 - c2) / (n2 * c1 + c2);
	float3 r23s = (n2 * c2 - n3 * c3) / (n2 * c2 + n3 * c3);
	float3 r23p = (n3 * c2 - n2 * c3) / (n3 * c2 + n2 * c3);
	float3 phase = 4.0 * PI * n2 * nm * c2 / float3(650.0, 532.0, 450.0);
	float3 cs = cos(phase);
	float3 rs = (r12s * r12s + r23s * r23s + 2.0 * r12s * r23s * cs) / (1.0 + r12s * r12s * r23s * r23s + 2.0 * r12s * r23s * cs);
	float3 rp = (r12p * r12p + r23p * r23p + 2.0 * r12p * r23p * cs) / (1.0 + r12p * r12p * r23p * r23p + 2.0 * r12p * r23p * cs);
	return saturate(0.5 * (rs + rp));
}
