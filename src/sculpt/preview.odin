package sculpt

import "core:math"
import "core:math/linalg"
import "core:slice"

import "../geom"

// A brush's picture made by the brush itself (the UI review's U6): one stroke across a
// small strip of clay, seen from in front and above, lit from the upper left and drawn
// into RGBA pixels on the CPU, so the brush browser's cards show what each brush does
// rather than a drawn guess. Smooth, which shows nothing on a flat strip, starts from a
// bumpy one; the plane brushes from a ridge beside a groove under the stroke, so Flatten
// takes both away, Fill only the groove and Scrape only the ridge; Morph starts from a
// strip with a ridge raised after its target was kept, so its stroke takes the ridge back
// down; Pinch from a ridge it draws together. Everything is
// serial and deterministic (no pool), so a thread can make many and the same brush always
// gives the same picture. Cloth and History, which need a simulation or an earlier step,
// make no picture: preview_render returns false for them.

// The picture's size, in pixels; the card shows it about 2.7 times as wide as it is tall.
PREVIEW_W :: 192
PREVIEW_H :: 72

// The strip: this many vertices across and down, over this half width and half depth.
@(private = "file")
PREVIEW_GRID :: [2]int{110, 44}
@(private = "file")
PREVIEW_HALF :: [2]f32{1.33, 0.7}
// The stroke's brush radius, and how far apart its dabs are as a share of it.
PREVIEW_RADIUS :: f32(0.2)
@(private = "file")
PREVIEW_SPACING :: f32(0.12)
// How deep the relief is drawn at least (preview_render), in the strip's units.
@(private = "file")
PREVIEW_DEPTH :: f32(0.05)
// How far the view looks down onto the strip from straight in front, in radians.
@(private = "file")
PREVIEW_TILT :: f32(0.75)

// What a strip starts as before the stroke.
Preview_Start :: enum u8 {
	Flat,
	Bumpy, // low waves and grain all over, which smoothing evens out
	Ridges, // a ridge beside a groove along the stroke, which a plane cuts and fills
}

// What the strip for `b` starts as: bumpy for Smooth, ridges for the plane brushes.
preview_start :: proc(b: Brush) -> Preview_Start {
	#partial switch b.kind {
	case .Smooth:                 return .Bumpy
	case .Flatten, .Trim_Dynamic: return .Ridges
	}
	return .Flat
}

// The stroke's path across the strip, `f` from 0 to 1: a shallow arc left to right.
@(private = "file")
preview_path :: proc(f: f32) -> [2]f32 {
	return {-0.92 + 1.84 * f, -0.06 + 0.16 * math.sin(f * math.PI)}
}

// Whether preview_render can make a picture of `kind`.
preview_offered :: proc(kind: Brush_Kind) -> bool {
	return kind != .Cloth && kind != .History
}

// Draws one stroke of `brush` (its kind, strength and the rest; its radius, symmetry and
// view-dependent fields are the preview's own) across a strip and its picture into
// `pixels`, PREVIEW_W by PREVIEW_H RGBA8, rows top to bottom, display-encoded; where the
// strip does not reach, alpha is 0. Allocates with context.allocator and frees all it
// made. False, with `pixels` untouched, for a kind it cannot show.
preview_render :: proc(brush: Brush, pixels: []u8) -> bool {
	if !preview_offered(brush.kind) || len(pixels) < PREVIEW_W * PREVIEW_H * 4 do return false
	start := preview_start(brush)
	mesh := preview_strip(start)
	defer geom.mesh_destroy(&mesh)
	geom.mesh_recompute_normals(&mesh)
	s: Sculptor
	sculptor_init(&s, &mesh, nil)
	defer sculptor_destroy(&s)
	b := brush
	b.radius = PREVIEW_RADIUS
	b.symmetry, b.radial, b.sym_center = {}, 0, {}
	b.tilt, b.projected, b.facing, b.alpha = {}, {}, {}, nil
	b.detail = 0
	if b.kind == .Morph || b.kind == .Pinch {
		// Morph's target is the strip as it is, and a ridge raised after it is what the
		// stroke undoes; Pinch draws the ridge's sides together.
		if b.kind == .Morph do _ = sculptor_morph_store(&s)
		ridge := Brush{kind = .Draw, radius = 0.42 if b.kind == .Morph else 0.3, strength = 0.6}
		for x := f32(-1.2); x <= 1.2; x += 0.08 do _ = apply_dab(&s, ridge, preview_on(&s, {x, 0.05}))
		_ = sculptor_flush(&s)
	}
	sculptor_stroke_begin(&s)
	path := preview_path
	length: f32 = 0
	prev := path(0)
	for i in 1 ..= 64 {
		q := path(f32(i) / 64)
		length += linalg.length(q - prev)
		prev = q
	}
	dabs := max(int(length / (PREVIEW_RADIUS * PREVIEW_SPACING)), 2)
	switch b.kind {
	case .Grab, .Elastic:
		// Picked up left of the middle and pulled up and to the right.
		at := preview_on(&s, {-0.25, -0.05})
		_ = sculptor_grab_begin(&s, b, at)
		for i in 1 ..= 12 {
			_ = sculptor_grab_move(&s, f32(i) / 12 * Vec3{0.32, 0.12, 0.16})
			_ = sculptor_flush(&s)
		}
		sculptor_grab_end(&s)
	case .Draw, .Smooth, .Clay, .Flatten, .Inflate, .Pinch, .Crease, .Mask, .Layer, .Snake_Hook, .Morph, .Paint, .Clay_Strips, .Trim_Dynamic, .Cloth, .History:
		last := preview_on(&s, path(0))
		for i in 0 ..< dabs {
			f := f32(i) / f32(dabs - 1)
			at := preview_on(&s, path(f))
			b.stroke_dir = at - last if i > 0 else Vec3{1, 0, 0}
			// A hook pulls up out of the strip as it goes.
			if b.kind == .Snake_Hook do b.drag = Vec3{0, 0, PREVIEW_RADIUS * 0.06} + 0.3 * (at - last)
			_ = apply_dab(&s, b, at)
			last = at
			// The app flushes once a frame, about every four dabs, and a dab reads the
			// normals as the last flush left them.
			if i % 4 == 3 do _ = sculptor_flush(&s)
		}
	}
	_ = sculptor_stroke_end(&s)
	_ = sculptor_flush(&s)
	for len(s.waiting_cones) > 0 do _ = sculptor_flush(&s)
	// A gentle brush at its own strength raises the strip by a hair, which reads as nothing
	// on a card: on a flat strip the relief is drawn up to five times as deep, the deepest
	// at a fixed height, so a soft stroke shows and a strong one is drawn as it is. A strip
	// that starts with relief already shows what its brush took away.
	deepest: f32 = 0
	for p in mesh.positions do deepest = max(deepest, abs(p.z))
	if start == .Flat && deepest > 0 && deepest < PREVIEW_DEPTH {
		k := min(PREVIEW_DEPTH / deepest, 5)
		for &p in mesh.positions do p.z *= k
		geom.mesh_recompute_normals(&mesh)
	}
	preview_draw(&s, pixels)
	return true
}

// The strip's surface under `p` (x, y): straight down onto it, or the plane z = 0 where
// nothing is hit.
@(private = "file")
preview_on :: proc(s: ^Sculptor, p: [2]f32) -> Vec3 {
	hit, ok := sculptor_raycast(s, {p.x, p.y, 2}, {0, 0, -1})
	return hit if ok else Vec3{p.x, p.y, 0}
}

// The strip: a grid in z = 0 facing +z, starting as `start` says: bumps made of waves and
// a fixed hash so they are the same every time, or a ridge and a groove a little either
// side of the stroke's path, both within its reach.
@(private = "file")
preview_strip :: proc(start: Preview_Start) -> (m: geom.Mesh) {
	n := PREVIEW_GRID
	half := PREVIEW_HALF
	m.positions = make([dynamic]Vec3, 0, n.x * n.y)
	m.normals = make([dynamic]Vec3, 0, n.x * n.y)
	m.indices = make([dynamic]u32, 0, (n.x - 1) * (n.y - 1) * 6)
	for j in 0 ..< n.y {
		for i in 0 ..< n.x {
			x := -half.x + 2 * half.x * f32(i) / f32(n.x - 1)
			y := -half.y + 2 * half.y * f32(j) / f32(n.y - 1)
			z: f32 = 0
			switch start {
			case .Flat:
			case .Bumpy:
				h := u32(i * 73856093) ~ u32(j * 19349663)
				h = (h ~ (h >> 13)) * 0x5bd1e995
				z = 0.016 * math.sin(26 * x) * math.cos(23 * y) + 0.006 * math.sin(61 * x - 29 * y) + 0.005 * (f32(h & 1023) / 1023 - 0.5)
			case .Ridges:
				on := preview_path(clamp((x + 0.92) / 1.84, 0, 1)).y
				SPREAD :: 0.035
				up, down := y - (on + 0.06), y - (on - 0.06)
				z = 0.05 * (math.exp(-up * up / (2 * SPREAD * SPREAD)) - math.exp(-down * down / (2 * SPREAD * SPREAD)))
			}
			append(&m.positions, Vec3{x, y, z})
			append(&m.normals, Vec3{0, 0, 1})
		}
	}
	for j in 0 ..< n.y - 1 {
		for i in 0 ..< n.x - 1 {
			a := u32(j * n.x + i)
			b, c, d := a + 1, a + u32(n.x), a + u32(n.x) + 1
			append(&m.indices, a, b, d, a, d, c)
		}
	}
	return
}

// Draws the sculptor's mesh into `pixels`: an orthographic view from in front and
// PREVIEW_TILT above, each triangle filled with a depth test, its normal and colour
// interpolated, lit by one light from the upper left and a soft fill, the clay's colour
// tinted by the paint and darkened by the mask.
@(private = "file")
preview_draw :: proc(s: ^Sculptor, pixels: []u8) {
	W, H :: PREVIEW_W, PREVIEW_H
	mesh := s.mesh
	nv := len(mesh.positions)
	cos_t, sin_t := math.cos(PREVIEW_TILT), math.sin(PREVIEW_TILT)
	scale := f32(W) / (2 * PREVIEW_HALF.x)
	screen := make([][3]f32, nv)
	defer delete(screen)
	albedo := make([][3]f32, nv)
	defer delete(albedo)
	CLAY :: [3]f32{0.74, 0.52, 0.42} // linear light
	for p, v in mesh.positions {
		up := p.y * cos_t + p.z * sin_t
		depth := -p.y * sin_t + p.z * cos_t
		screen[v] = {f32(W) * 0.5 + p.x * scale, f32(H) * 0.5 - up * scale, depth}
		c := CLAY
		if s.color != nil {
			pc := s.color[v]
			if pc.a > 0 {
				paint := [3]f32{srgb_to_linear(pc.r), srgb_to_linear(pc.g), srgb_to_linear(pc.b)}
				c = linalg.lerp(c, paint, f32(pc.a) / 255)
			}
		}
		if s.mask != nil do c *= 1 - 0.72 * f32(s.mask[v]) / 255
		albedo[v] = c
	}
	zbuf := make([]f32, W * H)
	defer delete(zbuf)
	slice.fill(zbuf, -1e30)
	normal := make([][3]f32, W * H)
	defer delete(normal)
	base := make([][3]f32, W * H)
	defer delete(base)
	for t := 0; t + 2 < len(mesh.indices); t += 3 {
		ia, ib, ic := mesh.indices[t], mesh.indices[t + 1], mesh.indices[t + 2]
		a, b, c := screen[ia], screen[ib], screen[ic]
		area := (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)
		if abs(area) < 1e-12 do continue
		x0, x1 := max(int(math.floor(min(a.x, b.x, c.x))), 0), min(int(math.ceil(max(a.x, b.x, c.x))), W - 1)
		y0, y1 := max(int(math.floor(min(a.y, b.y, c.y))), 0), min(int(math.ceil(max(a.y, b.y, c.y))), H - 1)
		for py in y0 ..= y1 {
			for px in x0 ..= x1 {
				q := [2]f32{f32(px) + 0.5, f32(py) + 0.5}
				w0 := ((b.x - q.x) * (c.y - q.y) - (b.y - q.y) * (c.x - q.x)) / area
				w1 := ((c.x - q.x) * (a.y - q.y) - (c.y - q.y) * (a.x - q.x)) / area
				w2 := 1 - w0 - w1
				if w0 < -1e-5 || w1 < -1e-5 || w2 < -1e-5 do continue
				z := w0 * a.z + w1 * b.z + w2 * c.z
				at := py * W + px
				if z <= zbuf[at] do continue
				zbuf[at] = z
				normal[at] = w0 * mesh.normals[ia] + w1 * mesh.normals[ib] + w2 * mesh.normals[ic]
				base[at] = w0 * albedo[ia] + w1 * albedo[ib] + w2 * albedo[ic]
			}
		}
	}
	light := linalg.normalize(Vec3{-0.5, 0.6, 0.5})
	toward := Vec3{0, -sin_t, cos_t} // toward the viewer
	half_v := linalg.normalize(light + toward)
	for at in 0 ..< W * H {
		o := pixels[at * 4:][:4]
		if zbuf[at] < -1e29 {
			o[0], o[1], o[2], o[3] = 0, 0, 0, 0
			continue
		}
		n := linalg.normalize0(normal[at])
		diffuse := max(linalg.dot(n, light), 0)
		spec := math.pow(max(linalg.dot(n, half_v), 0), 24) * 0.18
		lit := base[at] * (0.2 + 1.0 * diffuse) + spec
		o[0], o[1], o[2], o[3] = linear_to_srgb(lit.r), linear_to_srgb(lit.g), linear_to_srgb(lit.b), 255
	}
}

@(private = "file")
srgb_to_linear :: proc(c: u8) -> f32 {
	f := f32(c) / 255
	return f / 12.92 if f <= 0.04045 else math.pow((f + 0.055) / 1.055, 2.4)
}

@(private = "file")
linear_to_srgb :: proc(v: f32) -> u8 {
	f := clamp(v, 0, 1)
	s := f * 12.92 if f <= 0.0031308 else 1.055 * math.pow(f, 1 / 2.4) - 0.055
	return u8(math.round(s * 255))
}
