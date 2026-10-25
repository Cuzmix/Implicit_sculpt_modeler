package png_write

import "core:bytes"
import "core:image"
import core_png "core:image/png"
import "core:testing"

@(test)
encode_round_trips :: proc(t: ^testing.T) {
	for alpha in ([2]bool{false, true}) {
		W, H :: 173, 61
		pixels := make([]u8, W * H * 4)
		defer delete(pixels)
		for y in 0 ..< H {
			for x in 0 ..< W {
				p := pixels[(y * W + x) * 4:]
				// A flat part, a gradient and noise, so every kind of match and literal shows up.
				switch {
				case x < 50: p[0], p[1], p[2], p[3] = 30, 31, 36, 255
				case x < 120: p[0], p[1], p[2], p[3] = u8(x), u8(y * 3), u8(x + y), 200
				case: p[0], p[1], p[2], p[3] = u8(x * 7919 ~ y * 104729), u8(x * y), u8(y * 13), u8(x)
				}
			}
		}
		data := encode(pixels, W, H, alpha)
		defer delete(data)
		img, err := core_png.load_from_bytes(data)
		defer image.destroy(img)
		testing.expectf(t, err == nil, "alpha %v: %v", alpha, err)
		if err != nil do continue
		testing.expect(t, img.width == W && img.height == H && img.depth == 8 && img.channels == (4 if alpha else 3))
		got := bytes.buffer_to_bytes(&img.pixels)
		bad := 0
		for i in 0 ..< W * H do for c in 0 ..< img.channels do if got[i * img.channels + c] != pixels[i * 4 + c] do bad += 1
		testing.expectf(t, bad == 0, "alpha %v: %d values differ", alpha, bad)
	}
}

// A 16-bit greyscale image reads back sample for sample (core:image keeps them big-endian
// in its bytes, two a pixel).
@(test)
encode_gray16_round_trips :: proc(t: ^testing.T) {
	W, H :: 97, 33
	values := make([]u16, W * H)
	defer delete(values)
	for y in 0 ..< H do for x in 0 ..< W do values[y * W + x] = u16(32768 + (x - 48) * 600 + y * 7) if x % 9 != 0 else u16(x * y * 31)
	data := encode_gray16(values, W, H)
	defer delete(data)
	img, err := core_png.load_from_bytes(data)
	defer image.destroy(img)
	testing.expectf(t, err == nil, "%v", err)
	if err != nil do return
	testing.expectf(t, img.width == W && img.height == H && img.depth == 16, "%d x %d, depth %d, %d channels", img.width, img.height, img.depth, img.channels)
	got := bytes.buffer_to_bytes(&img.pixels)
	bad := 0
	for v, i in values {
		// core:image hands 16-bit samples back in the machine's order, grey spread to
		// every channel it gives.
		at := 2 * img.channels * i
		x := u16(got[at]) | u16(got[at + 1]) << 8
		if x != v do bad += 1
	}
	testing.expectf(t, bad == 0, "%d samples differ", bad)
}
