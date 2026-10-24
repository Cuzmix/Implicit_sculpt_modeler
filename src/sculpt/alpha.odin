package sculpt

import "core:math"
import "core:math/linalg"

// Brush alphas, as in ZBrush (Blender calls them brush textures): a square grey image
// that shapes each dab in place of the round falloff. The image lies on the plane across
// the dab's area normal, its middle on the dab's centre and its sides one radius from
// it; a vertex gets the image's value where it falls on it, fading as it lies further
// off that plane. Values run 0 to 1 and an image is expected to fade to 0 at its edges,
// as the built-in ones (alpha_make) do.

Alpha :: struct {
	size:   int, // pixels a side
	values: []f32, // size × size, row by row from the top
	// How far from the middle, in radii, the image is above 0: dabs look for vertices
	// this far out, so an image that fades out inside its circle costs no more than
	// the round brush (alpha_measure).
	reach:  f32,
}

// The built-in alphas.
Alpha_Shape :: enum u8 {
	Square, // a flat-topped square: square stamps and edges
	Noise,  // bumps of every size: skin, stone, bark
	Rings,  // ridges around the middle
	Stripes, // ridges along the image's up: cloth folds and hair along a stroke
	Dots,   // a grid of round bumps: rivets, scales
	Star,   // a five-pointed star
}

ALPHA_SHAPE_NAMES := [Alpha_Shape]string {
	.Square  = "Square",
	.Noise   = "Noise",
	.Rings   = "Rings",
	.Stripes = "Stripes",
	.Dots    = "Dots",
	.Star    = "Star",
}

// Pixels a side of the built-in alphas, and at most of one made from an image: a dab
// rarely covers more vertices across than this, and 512² floats (1 MB) stay in cache.
ALPHA_SIZE :: 256
ALPHA_MAX_SIZE :: 512

alpha_destroy :: proc(a: ^Alpha, allocator := context.allocator) {
	delete(a.values, allocator)
	a^ = {}
}

// The value at (u, v), each from −1 to 1 across the image (v up), between pixels
// linearly; 0 outside.
alpha_sample :: #force_inline proc(a: ^Alpha, u, v: f32) -> f32 {
	if !(abs(u) < 1 && abs(v) < 1) do return 0
	last := f32(a.size - 1)
	x := (u * 0.5 + 0.5) * last
	y := (0.5 - v * 0.5) * last
	x0, y0 := min(int(x), a.size - 2), min(int(y), a.size - 2)
	fx, fy := x - f32(x0), y - f32(y0)
	row := a.values[y0 * a.size:]
	below := a.values[(y0 + 1) * a.size:]
	top := row[x0] + (row[x0 + 1] - row[x0]) * fx
	bottom := below[x0] + (below[x0 + 1] - below[x0]) * fx
	return top + (bottom - top) * fy
}

// One of the built-in alphas, `size` pixels a side (at least 2).
alpha_make :: proc(shape: Alpha_Shape, size := ALPHA_SIZE, allocator := context.allocator) -> Alpha {
	a := Alpha{size = max(size, 2)}
	a.values = make([]f32, a.size * a.size, allocator)
	last := f32(a.size - 1)
	for j in 0 ..< a.size {
		for i in 0 ..< a.size {
			// −1 to 1 across, v up.
			u := 2 * f32(i) / last - 1
			v := 1 - 2 * f32(j) / last
			r2 := u * u + v * v
			// Fades every pattern but the square to 0 at the circle through the edges'
			// middles, so a stamp has no rim.
			round := falloff(r2)
			value: f32
			switch shape {
			case .Square:
				// Flat inside 0.6 of the way to the edge, then a smooth step down.
				t := clamp((1 - max(abs(u), abs(v))) / 0.4, 0, 1)
				value = t * t * (3 - 2 * t)
			case .Noise:
				value = clamp(0.5 + 0.9 * (fractal_noise(u * 3 + 11.3, v * 3 + 7.1) - 0.5), 0, 1) * round
			case .Rings:
				value = (0.5 + 0.5 * math.cos(2 * math.PI * 4 * math.sqrt(r2))) * round
			case .Stripes:
				value = (0.5 + 0.5 * math.cos(2 * math.PI * 3 * u)) * round
			case .Dots:
				// Four bumps across, each a falloff over its cell.
				cu, cv := 4 * (u * 0.5 + 0.5), 4 * (v * 0.5 + 0.5)
				du, dv := 2 * (cu - math.floor(cu)) - 1, 2 * (cv - math.floor(cv)) - 1
				value = falloff(du * du + dv * dv) * round
			case .Star:
				// Inside a radius that swings five times around the middle, softly.
				angle := math.atan2(u, v) // 0 straight up: a point at the top
				edge := 0.62 + 0.3 * math.cos(5 * angle)
				value = clamp((edge - math.sqrt(r2)) / 0.12, 0, 1)
			}
			a.values[j * a.size + i] = value
		}
	}
	alpha_measure(&a)
	return a
}

// An alpha from a grey image `width` by `height` (`grey` row by row from the top, 0 to
// 1): padded with 0 to a square about its middle, then averaged down to at most
// ALPHA_MAX_SIZE a side. False for an empty image.
alpha_from_grey :: proc(grey: []f32, width, height: int, allocator := context.allocator) -> (a: Alpha, ok: bool) {
	if width <= 0 || height <= 0 || len(grey) < width * height do return {}, false
	side := max(width, height)
	a.size = max(min(side, ALPHA_MAX_SIZE), 2)
	a.values = make([]f32, a.size * a.size, allocator)
	// Source pixels of the padded square per alpha pixel, and where the image starts in it.
	scale := f32(side) / f32(a.size)
	ox, oy := (side - width) / 2, (side - height) / 2
	for j in 0 ..< a.size {
		y0 := int(f32(j) * scale)
		y1 := max(int(f32(j + 1) * scale), y0 + 1)
		for i in 0 ..< a.size {
			x0 := int(f32(i) * scale)
			x1 := max(int(f32(i + 1) * scale), x0 + 1)
			sum: f32
			for y in y0 ..< y1 {
				sy := y - oy
				if sy < 0 || sy >= height do continue
				for x in x0 ..< x1 {
					sx := x - ox
					if sx >= 0 && sx < width do sum += grey[sy * width + sx]
				}
			}
			a.values[j * a.size + i] = clamp(sum / f32((y1 - y0) * (x1 - x0)), 0, 1)
		}
	}
	alpha_measure(&a)
	return a, true
}

// Sets the alpha's reach from its values: the farthest corner of a pixel above 0, as
// alpha_sample blends toward its neighbours, at most the image's corners (√2).
alpha_measure :: proc(a: ^Alpha) {
	a.reach = 0
	last := f32(a.size - 1)
	for j in 0 ..< a.size {
		for i in 0 ..< a.size {
			if a.values[j * a.size + i] <= 0 do continue
			// One pixel further out, where the blend reaches 0.
			u := (abs(2 * f32(i) / last - 1) + 2 / last)
			v := (abs(2 * f32(j) / last - 1) + 2 / last)
			a.reach = max(a.reach, u * u + v * v)
		}
	}
	a.reach = min(math.sqrt(a.reach), math.SQRT_TWO)
}

// Value noise summed over four octaves, about 0 to 1.
@(private = "file")
fractal_noise :: proc(x, y: f32) -> f32 {
	sum, amplitude, total: f32 = 0, 1, 0
	fx, fy := x, y
	for _ in 0 ..< 4 {
		sum += amplitude * value_noise(fx, fy)
		total += amplitude
		amplitude *= 0.5
		fx, fy = fx * 2 + 17.7, fy * 2 + 3.3
	}
	return sum / total
}

// A random value at each integer point, blended smoothly between them.
@(private = "file")
value_noise :: proc(x, y: f32) -> f32 {
	ix, iy := math.floor(x), math.floor(y)
	fx, fy := x - ix, y - iy
	sx, sy := fx * fx * (3 - 2 * fx), fy * fy * (3 - 2 * fy)
	a := lattice(i32(ix), i32(iy))
	b := lattice(i32(ix) + 1, i32(iy))
	c := lattice(i32(ix), i32(iy) + 1)
	d := lattice(i32(ix) + 1, i32(iy) + 1)
	return linalg.lerp(linalg.lerp(a, b, sx), linalg.lerp(c, d, sx), sy)
}

// A fixed random value in [0, 1) for each lattice point (an integer hash).
@(private = "file")
lattice :: proc(x, y: i32) -> f32 {
	h := u32(x) * 0x8da6b343 ~ u32(y) * 0xd8163841
	h ~= h >> 13
	h *= 0x5bd1e995
	h ~= h >> 15
	return f32(h & 0xffffff) / f32(0x1000000)
}
