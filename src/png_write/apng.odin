package png_write

// Animated PNG (APNG): a PNG whose first frame is its still picture, which every PNG
// reader shows, and whose further frames browsers and image viewers play. Written a
// frame at a time, so a long animation never has to sit in memory whole: each call
// appends its chunks to `out`, which the caller writes out and may clear between frames.
Apng :: struct {
	width, height: int,
	alpha:         bool,
	frames:        int, // how many frames the file says it holds
	plays:         int, // times it plays through; 0 for over and over
	delay:         [2]u16, // how long each frame shows: numerator and denominator of seconds
	written:       int, // frames appended so far
	sequence:      u32, // the next animation chunk's number
}

// Appends the signature, the header and the animation's frame count. Exactly
// `a.frames` frames must follow, or readers stop at the last one written.
apng_begin :: proc(out: ^[dynamic]u8, a: ^Apng) {
	assert(a.width > 0 && a.height > 0 && a.frames > 0)
	append(out, 0x89, 'P', 'N', 'G', '\r', '\n', 0x1a, '\n')
	head := header(a.width, a.height, 8, 6 if a.alpha else 2)
	chunk(out, "IHDR", head[:])
	control: [8]u8
	put_u32(control[0:], u32(a.frames))
	put_u32(control[4:], u32(a.plays))
	chunk(out, "acTL", control[:])
	a.written, a.sequence = 0, 0
}

// Appends the next frame (RGBA, 4 bytes a pixel, rows top to bottom, the whole picture),
// replacing the one before rather than drawn over it, so see-through parts stay so.
apng_frame :: proc(out: ^[dynamic]u8, a: ^Apng, pixels: []u8) {
	assert(a.written < a.frames && len(pixels) >= a.width * a.height * 4)
	control: [26]u8
	put_u32(control[0:], a.sequence)
	put_u32(control[4:], u32(a.width))
	put_u32(control[8:], u32(a.height))
	// No offset; delay; dispose_op 0 (none) and blend_op 0 (source).
	control[20], control[21] = u8(a.delay[0] >> 8), u8(a.delay[0])
	control[22], control[23] = u8(a.delay[1] >> 8), u8(a.delay[1])
	chunk(out, "fcTL", control[:])
	a.sequence += 1
	channels := 4 if a.alpha else 3
	data := zlib(filtered(pack(pixels, a.width, a.height, channels), a.width, a.height, channels), context.temp_allocator)
	if a.written == 0 {
		chunk(out, "IDAT", data)
	} else {
		body := make([]u8, 4 + len(data), context.temp_allocator)
		put_u32(body[0:], a.sequence)
		copy(body[4:], data)
		chunk(out, "fdAT", body)
		a.sequence += 1
	}
	a.written += 1
}

// Appends the end of the file.
apng_end :: proc(out: ^[dynamic]u8) {
	chunk(out, "IEND", nil)
}
