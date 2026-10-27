package render

import "core:log"
import "core:math"
import "core:mem"
import sdl "vendor:sdl3"

// Sampling an environment by its brightness (stage 4.4b), so render mode's paths find a
// bright sun in a panorama, or the built-in studio's softbox, as often as they matter
// instead of only when a bounce happens to point at it. Each environment keeps a table
// over a small copy of its panorama: a texel is picked by its luminance times its share
// of the sphere (sin θ) through Vose's alias method, in constant time, and a direction
// is taken evenly within it. render_trace.comp reads the table (env_sample, env_pdf).

ENV_TABLE_FORMAT :: sdl.GPUTextureFormat.R32G32B32A32_FLOAT
// The table's size at most: fine enough to find a sun a degree or so across, and 2 MB.
ENV_TABLE_WIDTH :: 512
// The built-in studio's table: it is smooth but for its lights.
STUDIO_TABLE_WIDTH :: 256
// Every texel keeps at least this share of the mean, so no direction the environment
// lights has no chance of being picked.
@(private = "file")
ENV_TABLE_FLOOR :: 1e-3

// An environment's table: for each texel, rows from straight up, x the chance it keeps
// its pick, y the texel taken otherwise, z its chance times W H / (2π²), which over the
// sine of a direction's angle from straight up is the density of that direction; and
// the panorama's mean luminance over the sphere, for how much light it gives.
Env_Table :: struct {
	texels:        [][4]f32,
	width, height: int,
	mean:          f32,
}

// Builds the table over `lum`, luminances in rows from straight up, `width` by `height`.
env_table_build :: proc(lum: []f32, width, height: int, allocator := context.allocator) -> (t: Env_Table) {
	n := width * height
	assert(len(lum) == n && n > 0)
	t.width, t.height = width, height
	t.texels = make([][4]f32, n, allocator)
	weights := make([]f64, n, context.temp_allocator)
	sum_lum, sum_sin: f64
	for y in 0 ..< height {
		s := math.sin((f64(y) + 0.5) / f64(height) * math.PI)
		for x in 0 ..< width {
			sum_lum += f64(lum[y * width + x]) * s
			sum_sin += s
		}
	}
	t.mean = f32(sum_lum / sum_sin)
	floor := max(f64(t.mean), 1e-6) * ENV_TABLE_FLOOR
	// Each texel is weighed by its brightest neighbour's luminance, its own included
	// (round the panorama across, clamped at the poles): the shader's filtered lookups
	// carry a sun's edge half a texel into the sky beside it, and a direction there picked
	// as seldom as the sky would come back a thousand times too bright, a speckle.
	total: f64
	for y in 0 ..< height {
		s := math.sin((f64(y) + 0.5) / f64(height) * math.PI)
		for x in 0 ..< width {
			bright: f32
			for ny in max(y - 1, 0) ..= min(y + 1, height - 1) {
				for dx in -1 ..= 1 do bright = max(bright, lum[ny * width + (x + dx + width) % width])
			}
			i := y * width + x
			weights[i] = (f64(bright) + floor) * s
			total += weights[i]
		}
	}
	// Vose's alias method: every texel's scaled chance n p is split into what it keeps
	// and what a texel over 1 tops it up with, small and large ones paired in index order.
	scaled := make([]f64, n, context.temp_allocator)
	small := make([dynamic]int, 0, n, context.temp_allocator)
	large := make([dynamic]int, 0, n, context.temp_allocator)
	density := f64(width * height) / (2 * math.PI * math.PI)
	for i in 0 ..< n {
		p := weights[i] / total
		t.texels[i].z = f32(p * density)
		scaled[i] = p * f64(n)
		if scaled[i] < 1 do append(&small, i)
		else do append(&large, i)
	}
	for len(small) > 0 && len(large) > 0 {
		s, l := pop(&small), pop(&large)
		t.texels[s].x = f32(scaled[s])
		t.texels[s].y = f32(l)
		scaled[l] -= 1 - scaled[s]
		if scaled[l] < 1 do append(&small, l)
		else do append(&large, l)
	}
	// What rounding leaves keeps its own pick.
	for i in large do t.texels[i] = {1, f32(i), t.texels[i].z, 0}
	for i in small do t.texels[i] = {1, f32(i), t.texels[i].z, 0}
	return
}

// The luminances of `pixels` (linear RGB rows from straight up, `width` by `height`)
// averaged down to at most ENV_TABLE_WIDTH across.
env_table_luminance :: proc(pixels: [][3]f32, width, height: int, allocator := context.allocator) -> (lum: []f32, w, h: int) {
	w = min(width, ENV_TABLE_WIDTH)
	h = max(w * height / max(width, 1), 1)
	lum = make([]f32, w * h, allocator)
	for y in 0 ..< h {
		y0, y1 := y * height / h, max((y + 1) * height / h, y * height / h + 1)
		for x in 0 ..< w {
			x0, x1 := x * width / w, max((x + 1) * width / w, x * width / w + 1)
			sum: f32
			for sy in y0 ..< y1 do for sx in x0 ..< x1 {
				c := pixels[sy * width + sx]
				sum += 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b
			}
			lum[y * w + x] = sum / f32((y1 - y0) * (x1 - x0))
		}
	}
	return
}

// The built-in studio's luminance in its own space (studio() in studio_env.glsl, at
// render_trace.comp's STUDIO_BLUR), for its table. Kept in step with the shader by hand:
// a difference costs only noise, never a wrong image, since the shader's own studio()
// gives the light and the table only where to look.
studio_luminance :: proc(dir: [3]f32, rough: f32) -> f32 {
	smoothstep :: proc(e0, e1, x: f32) -> f32 {
		t := clamp((x - e0) / (e1 - e0), 0, 1)
		return t * t * (3 - 2 * t)
	}
	norm :: proc(v: [3]f32) -> [3]f32 {return v / math.sqrt(v.x * v.x + v.y * v.y + v.z * v.z)}
	lobe :: proc(dir, toward, color: [3]f32, sharp, rough: f32) -> [3]f32 {
		e := sharp + (3 - sharp) * math.sqrt(rough)
		d := max(dir.x * toward.x + dir.y * toward.y + dir.z * toward.z, 0)
		return color * (math.pow(d, e) * (e + 2) / (sharp + 2))
	}
	w := 0.08 + 0.9 * rough
	up := smoothstep(-w, w, dir.y)
	c := [3]f32{0.07, 0.065, 0.06} + ([3]f32{0.40, 0.43, 0.48} - [3]f32{0.07, 0.065, 0.06}) * up
	c += [3]f32{0.13, 0.12, 0.11} * math.exp(-abs(dir.y) / (0.06 + 0.5 * rough))
	c += lobe(dir, norm({-0.75, 0.85, 0.15}), {4.0, 3.8, 3.5}, 300, rough)
	c += lobe(dir, norm({0.9, 0.35, -0.45}), {1.6, 1.8, 2.1}, 600, rough)
	c += lobe(dir, norm({0.1, -0.35, 1.0}), {0.5, 0.5, 0.5}, 4, rough)
	return 0.2126 * c.x + 0.7152 * c.y + 0.0722 * c.z
}

// The direction at the middle of panorama texel (x, y), as panorama_dir in panorama.glsl.
panorama_direction :: proc(x, y, width, height: int) -> [3]f32 {
	theta := (f32(y) + 0.5) / f32(height) * math.PI
	phi := ((f32(x) + 0.5) / f32(width) - 0.5) * 2 * math.PI
	s := math.sin(theta)
	return {math.sin(phi) * s, math.cos(theta), -math.cos(phi) * s}
}

// Uploads a table as an RGBA32F texture; nil, logged, when the device refuses.
env_table_texture :: proc(r: ^Renderer, t: Env_Table) -> ^sdl.GPUTexture {
	tex := sdl.CreateGPUTexture(r.device, {
		type = .D2, format = ENV_TABLE_FORMAT, usage = {.SAMPLER},
		width = u32(t.width), height = u32(t.height), layer_count_or_depth = 1, num_levels = 1,
	})
	if tex == nil {
		log.errorf("environment table %d x %d: %s", t.width, t.height, sdl.GetError())
		return nil
	}
	if !texture_upload(r, tex, mem.slice_to_bytes(t.texels), t.width, t.height, mips = false) {
		sdl.ReleaseGPUTexture(r.device, tex)
		return nil
	}
	return tex
}
