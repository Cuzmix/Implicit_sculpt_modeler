package hdri

import "core:hash"
import "core:mem"
import "core:testing"

// The OpenEXR fixtures were written by the OpenEXR library itself (its Python binding,
// 3.5.2): a 64 x 32 sky with a sun of 40 in half floats under every compression the
// reader takes, in floats with alpha (ZIP) and under PIZ, as luminance alone, and a
// 128 x 64 field of noise under PIZ, which fills more than one chunk and uses long codes.
// Each must read to the pixels the library read back, by the FNV-1a hash of their floats.
@(private = "file")
EXR_FIXTURES := [?]struct {
	name: string,
	data: []u8,
	hash: u64,
} {
	{"half none", #load("testdata/exr/sky_half_none.exr"), 0xda1ca01877bf8e7c},
	{"half RLE", #load("testdata/exr/sky_half_rle.exr"), 0xda1ca01877bf8e7c},
	{"half ZIPS", #load("testdata/exr/sky_half_zips.exr"), 0xda1ca01877bf8e7c},
	{"half ZIP", #load("testdata/exr/sky_half_zip.exr"), 0xda1ca01877bf8e7c},
	{"half PIZ", #load("testdata/exr/sky_half_piz.exr"), 0xda1ca01877bf8e7c},
	{"float RGBA ZIP", #load("testdata/exr/sky_float_rgba_zip.exr"), 0x9aec0d2d4ebc2aa5},
	{"float PIZ", #load("testdata/exr/sky_float_piz.exr"), 0x9aec0d2d4ebc2aa5},
	{"Y PIZ", #load("testdata/exr/sky_y_piz.exr"), 0x8b2c8049ffd7c6d9},
	{"noise PIZ", #load("testdata/exr/noise_half_piz.exr"), 0x16bf3cfc54f7099a},
}

// The lossy compressions, tiles and several parts, written by the same library: PXR24 over
// halves (kept whole) and floats (cut to 24 bits); B44 at 64 x 32 and at 66 x 33 (blocks cut
// at the edges), B44A over a flat half, B44 with a perceptually linear R and a float alpha;
// tiles of one level under ZIP and B44 cut at the edges, a mipmapped file under PIZ (the
// full-size level read), and two parts whose second is the picture. Each reads to what the
// library read back, bit for bit.
@(private = "file")
EXR_MORE := [?]struct {
	name: string,
	data: []u8,
	hash: u64,
} {
	{"half PXR24", #load("testdata/exr/sky_half_pxr24.exr"), 0xda1ca01877bf8e7c},
	{"float PXR24", #load("testdata/exr/sky_float_pxr24.exr"), 0x07eb48ec2c9a82c8},
	{"half B44", #load("testdata/exr/sky_half_b44.exr"), 0xe722d19f310c191a},
	{"66 x 33 B44", #load("testdata/exr/sky66_half_b44.exr"), 0x075b06a4369f41a8},
	{"flat B44A", #load("testdata/exr/flat_half_b44a.exr"), 0x2c644f7968607d08},
	{"perceptually linear B44", #load("testdata/exr/sky_plinear_b44.exr"), 0x4ab4b89564fdeb1b},
	{"Y DWAB", #load("testdata/exr/sky_y_dwab.exr"), 0xdd14ce7f09bee0bf},
	{"tiled ZIP", #load("testdata/exr/sky_tiled_zip.exr"), 0xda1ca01877bf8e7c},
	{"tiled B44", #load("testdata/exr/sky66_tiled_b44.exr"), 0x03a750d5879715d2},
	{"mipmapped PIZ", #load("testdata/exr/sky66_mip_piz.exr"), 0xced664b5e04884e6},
	{"two parts", #load("testdata/exr/sky_parts.exr"), 0xda1ca01877bf8e7c},
}

// DWAA and DWAB over halves, floats, an odd size, alpha and depth beside RGB, noise, tiles
// cut at the edges and a tiled second part. The reference's inverse cosine transform runs
// in a different order on x86 (AVX) than on ARM (plain C, which the reader follows), so a
// handful of values a file differ from what the x86 library read back by a step or two of
// the perceptual half before it turns linear. Each must read to its own hash every time,
// and against the library's values (kept losslessly in an `_expect` file) differ in at
// most one value in a thousand, by at most four half steps.
@(private = "file")
EXR_DWA := [?]struct {
	name:   string,
	data:   []u8,
	hash:   u64,
	expect: []u8,
} {
	{"half DWAA", #load("testdata/exr/sky_half_dwaa.exr"), 0xb74ee1c4ac671b14, #load("testdata/exr/sky_half_dwaa_expect.exr")},
	{"float DWAA", #load("testdata/exr/sky_float_dwaa.exr"), 0xb74ee1c4ac671b14, #load("testdata/exr/sky_half_dwaa_expect.exr")},
	{"RGBAZ DWAA", #load("testdata/exr/sky_rgbaz_dwaa.exr"), 0xb74ee1c4ac671b14, #load("testdata/exr/sky_half_dwaa_expect.exr")},
	{"66 x 33 DWAB", #load("testdata/exr/sky66_half_dwab.exr"), 0x616b7b984549d23e, #load("testdata/exr/sky66_half_dwab_expect.exr")},
	{"noise DWAB", #load("testdata/exr/noise_half_dwab.exr"), 0x2b3b84cff174224e, #load("testdata/exr/noise_half_dwab_expect.exr")},
	{"tiled DWAA", #load("testdata/exr/sky66_tiled_dwaa.exr"), 0xec8089a9846c8c90, #load("testdata/exr/sky66_tiled_dwaa_expect.exr")},
	{"tiled part DWAB", #load("testdata/exr/sky_parts_tiled.exr"), 0x21e0b75502191966, #load("testdata/exr/sky_parts_tiled_expect.exr")},
}

@(test)
exr_reads_every_compression :: proc(t: ^testing.T) {
	for f in EXR_FIXTURES {
		img, why := decode(f.data, 1 << 12)
		defer image_destroy(&img)
		defer delete(why)
		if !testing.expectf(t, why == "", "%s: %s", f.name, why) do continue
		got := hash.fnv64a(mem.slice_to_bytes(img.pixels))
		testing.expectf(t, got == f.hash, "%s: the pixels hash to %x, not %x", f.name, got, f.hash)
	}
	for f in EXR_MORE {
		img, why := decode(f.data, 1 << 12)
		defer image_destroy(&img)
		defer delete(why)
		if !testing.expectf(t, why == "", "%s: %s", f.name, why) do continue
		got := hash.fnv64a(mem.slice_to_bytes(img.pixels))
		testing.expectf(t, got == f.hash, "%s: the pixels hash to %x, not %x", f.name, got, f.hash)
	}
	for f in EXR_DWA {
		img, why := decode(f.data, 1 << 12)
		defer image_destroy(&img)
		defer delete(why)
		if !testing.expectf(t, why == "", "%s: %s", f.name, why) do continue
		got := hash.fnv64a(mem.slice_to_bytes(img.pixels))
		testing.expectf(t, got == f.hash, "%s: the pixels hash to %x, not %x", f.name, got, f.hash)
		want, why2 := decode(f.expect, 1 << 12)
		defer image_destroy(&want)
		defer delete(why2)
		if !testing.expectf(t, len(want.pixels) == len(img.pixels), "%s: the expected picture differs in size", f.name) do continue
		differ, most := 0, 0
		for p, i in img.pixels {
			for k in 0 ..< 3 {
				a := int(transmute(u16)f16(p[k]))
				b := int(transmute(u16)f16(want.pixels[i][k]))
				if a != b do differ += 1
				most = max(most, abs(a - b))
			}
		}
		testing.expectf(t, differ * 1000 <= 3 * len(img.pixels) && most <= 4, "%s: %d values differ from the library's, by up to %d half steps", f.name, differ, most)
	}
	// Halved on the way in, as a Radiance file is: half as wide, each pixel a 2 x 2 mean.
	half, why := decode(EXR_FIXTURES[3].data, 32)
	defer image_destroy(&half)
	defer delete(why)
	testing.expect_value(t, why, "")
	testing.expect_value(t, half.width, 32)
	testing.expect_value(t, half.height, 16)
}

// Deep files, the newest compressions and a cut or damaged file are refused with a reason,
// and nothing is read past the data.
@(test)
exr_refuses_what_it_does_not_read :: proc(t: ^testing.T) {
	refused :: proc(t: ^testing.T, data: []u8, words: string, loc := #caller_location) {
		img, why := decode(data, 1 << 12)
		defer image_destroy(&img)
		defer delete(why)
		testing.expectf(t, why != "" && img.pixels == nil, "read when it should not be (%s)", words, loc = loc)
	}
	// A deep file, and a scanline file claiming tiles or several parts it does not have.
	for flag in ([]u8{0x02, 0x08, 0x10}) {
		flagged := make([]u8, len(EXR_FIXTURES[3].data))
		defer delete(flagged)
		copy(flagged, EXR_FIXTURES[3].data)
		flagged[5] |= flag
		refused(t, flagged, "a flag")
	}
	// HTJ2K and ZSTD: the compression attribute's byte set to 10 and 13.
	for kind in ([]u8{10, 13}) {
		newer := make([]u8, len(EXR_FIXTURES[3].data))
		defer delete(newer)
		copy(newer, EXR_FIXTURES[3].data)
		name := "compression\x00compression\x00"
		for i in 0 ..< len(newer) - len(name) - 5 {
			if string(newer[i:][:len(name)]) == name {
				newer[i + len(name) + 4] = kind
				break
			}
		}
		refused(t, newer, "a newer compression")
	}
	for f in EXR_FIXTURES[:5] {
		for cut in ([]int{6, 100, len(f.data) / 2, len(f.data) - 1}) do refused(t, f.data[:cut], f.name)
	}
	// (A mipmapped file's smaller levels lie last, and the full-size level is all it needs.)
	for f in EXR_MORE {
		for cut in ([]int{100, len(f.data) / 2}) do refused(t, f.data[:cut], f.name)
	}
	for f in EXR_DWA {
		for cut in ([]int{100, len(f.data) / 2, len(f.data) - 1}) do refused(t, f.data[:cut], f.name)
	}
	// A damaged PIZ chunk: every byte past the header flipped in turn must be refused or
	// read, never read past the data.
	flipped :: proc(data: []u8, step: int) {
		copy_of := make([]u8, len(data))
		defer delete(copy_of)
		for i := 300; i < len(data); i += step {
			copy(copy_of, data)
			copy_of[i] ~= 0x5a
			img, why := decode(copy_of, 1 << 12)
			image_destroy(&img)
			delete(why)
		}
	}
	flipped(EXR_FIXTURES[4].data, 97)
	// The same for each lossy coding, tiles and parts.
	for f in EXR_MORE do flipped(f.data, 211)
	for f in EXR_DWA do flipped(f.data, 149)
}
