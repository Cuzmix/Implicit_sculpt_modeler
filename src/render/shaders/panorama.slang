// Equirectangular panoramas (render/environment.odin), shared by mesh_shading.slang,
// clear.frag.slang and env_prefilter.frag.slang: an include, never compiled alone.
// Directions are unit vectors with +Y up and -Z straight ahead, as
// app/environment_file.odin's environment_direction makes them.

// Where direction `d` falls: u from behind (0) round through straight ahead (0.5), v from
// straight up (0) to straight down (1).
float2 panorama_uv(float3 d) {
	// Straight up or down atan has no defined answer; any u is right there, so a tiny
	// offset picks one.
	return float2(atan2(d.x, -d.z - 1e-20) * 0.15915494 + 0.5, acos(clamp(d.y, -1.0, 1.0)) * 0.31830989);
}

// The direction at `uv`, panorama_uv's inverse.
float3 panorama_dir(float2 uv) {
	float theta = uv.y * 3.14159265;
	float phi = (uv.x - 0.5) * 6.28318531;
	float s = sin(theta);
	return float3(sin(phi) * s, cos(theta), -cos(phi) * s);
}
