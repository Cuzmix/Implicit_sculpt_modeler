// The web build's viewport (src/render/webgpu): one lit mesh and the brush ring. A
// stand-in until render's own shaders reach the web through Slang's WGSL output, kept to
// what a clay preview needs: the light comes from the view, as a matcap's does, so the
// shape reads the same from every side.

struct Frame {
	view_proj: mat4x4<f32>,
	view:      mat4x4<f32>,
	// The brush's centre in world space and its radius; a radius of 0 hides the ring.
	cursor:    vec4<f32>,
	// The clay's colour, linear RGB.
	clay:      vec4<f32>,
};

@group(0) @binding(0) var<uniform> frame: Frame;

struct Varyings {
	@builtin(position) position: vec4<f32>,
	@location(0) normal: vec3<f32>,
	@location(1) world:  vec3<f32>,
};

@vertex
fn vs_main(@location(0) position: vec3<f32>, @location(1) normal: vec3<f32>) -> Varyings {
	var out: Varyings;
	out.position = frame.view_proj * vec4<f32>(position, 1.0);
	out.normal = normal;
	out.world = position;
	return out;
}

@fragment
fn fs_main(v: Varyings, @builtin(front_facing) front: bool) -> @location(0) vec4<f32> {
	var n = normalize(v.normal);
	if (!front) {
		n = -n;
	}
	// View space: x right, y up, z toward the viewer.
	let vn = normalize((frame.view * vec4<f32>(n, 0.0)).xyz);
	let key = normalize(vec3<f32>(0.45, 0.6, 0.66));
	let fill = normalize(vec3<f32>(-0.7, 0.1, 0.4));
	let wrap = 0.15;
	let diffuse = max((dot(vn, key) + wrap) / (1.0 + wrap), 0.0);
	let fill_light = max(dot(vn, fill), 0.0) * 0.12;
	let sky = 0.035 + 0.03 * vn.y;
	let half_vec = normalize(key + vec3<f32>(0.0, 0.0, 1.0));
	let spec = pow(max(dot(vn, half_vec), 0.0), 48.0) * 0.12;
	let rim = pow(1.0 - max(vn.z, 0.0), 4.0) * 0.12;
	var color = frame.clay.rgb * (diffuse * 0.95 + fill_light + sky) + vec3<f32>(spec + rim);
	if (!front) {
		color *= 0.55;
	}

	// The brush ring: a line a pixel and a half wide where the surface is the radius away
	// from the centre, over a faint tint inside.
	let r = frame.cursor.w;
	if (r > 0.0) {
		let d = distance(v.world, frame.cursor.xyz);
		let w = max(fwidth(d), 1e-6);
		let ring = 1.0 - smoothstep(0.0, 1.5 * w, abs(d - r));
		let inside = select(0.0, 0.08, d < r);
		color = mix(color, vec3<f32>(1.0, 0.86, 0.55), max(ring * 0.9, inside));
	}
	// The canvas is not sRGB: encode by hand.
	return vec4<f32>(pow(max(color, vec3<f32>(0.0)), vec3<f32>(1.0 / 2.2)), 1.0);
}
