// How much of the light a GGX lobe with Fresnel 1 reflects in all (its directional albedo
// E), seen at cosine `mu` with perceptual roughness `r`, for the height-correlated Smith
// masking both the viewport and the path tracer use. A single-scattering microfacet lobe
// loses the light that bounces between microfacets, up to a fifth of it at mid roughness and
// more at full, so rough metals read darker than they are; multiplying the specular by
// energy_compensation puts it back (Kulla and Conty 2017, as Fdez-Aguera 2019 and Filament
// apply it to the split-sum).
//
// A degree-5 polynomial in r and mu fitted to the albedo integrated by Monte Carlo over
// r in 0.04..1 and mu in 0.03..1: 0.7 % mean error, at most 3.5 % for mu above 0.1 (only
// grazing smooth surfaces, which the Fresnel term brightens anyway, are further off). A
// polynomial rather than a lookup table, because every mesh shader and the trace kernels
// read it, and a texture would take a sampler from each (the kernels have two left).
float ggx_albedo(float mu, float r) {
	mu = clamp(mu, 0.03, 1.0);
	r = clamp(r, 0.0, 1.0);
	float p0 = 3.837022 + mu * (-8.9461 + mu * (-10.0286 + mu * (27.37651 + mu * (-13.70529 + mu * (2.404873)))));
	float p1 = -13.97328 + mu * (57.33845 + mu * (-32.69089 + mu * (-23.42685 + mu * (6.778399))));
	float p2 = 14.98354 + mu * (-75.88366 + mu * (71.32111 + mu * (4.006107)));
	float p3 = -2.249466 + mu * (25.23996 + mu * (-33.6537));
	float p4 = -3.070033 + mu * (4.508398);
	float p5 = 0.5243375;
	float loss = r * r * (p0 + r * (p1 + r * (p2 + r * (p3 + r * (p4 + r * p5)))));
	return clamp(1.0 - loss, 0.05, 1.0);
}

// The factor that gives a GGX specular with reflectance `f0` back the energy its single
// scattering loses: 1 + f0 (1 / E - 1), which a perfect mirror (r = 0) leaves at 1.
float3 energy_compensation(float3 f0, float mu, float r) {
	return 1.0 + f0 * (1.0 / ggx_albedo(mu, r) - 1.0);
}
