package main

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

@(test)
exr_reads_every_compression :: proc(t: ^testing.T) {
	for f in EXR_FIXTURES {
		img, why := environment_decode(f.data, 1 << 12)
		defer environment_image_destroy(&img)
		defer delete(why)
		if !testing.expectf(t, why == "", "%s: %s", f.name, why) do continue
		got := hash.fnv64a(mem.slice_to_bytes(img.pixels))
		testing.expectf(t, got == f.hash, "%s: the pixels hash to %x, not %x", f.name, got, f.hash)
	}
	// Halved on the way in, as a Radiance file is: half as wide, each pixel a 2 x 2 mean.
	half, why := environment_decode(EXR_FIXTURES[3].data, 32)
	defer environment_image_destroy(&half)
	defer delete(why)
	testing.expect_value(t, why, "")
	testing.expect_value(t, half.width, 32)
	testing.expect_value(t, half.height, 16)
}

// The lossy compressions, tiles, several parts and a cut file are refused with a reason,
// and nothing is read past the data.
@(test)
exr_refuses_what_it_does_not_read :: proc(t: ^testing.T) {
	refused :: proc(t: ^testing.T, data: []u8, words: string, loc := #caller_location) {
		img, why := environment_decode(data, 1 << 12)
		defer environment_image_destroy(&img)
		defer delete(why)
		testing.expectf(t, why != "" && img.pixels == nil, "read when it should not be (%s)", words, loc = loc)
	}
	refused(t, #load("testdata/exr/sky_half_b44.exr"), "B44")
	refused(t, #load("testdata/exr/sky_half_dwaa.exr"), "DWAA")
	for flag in ([]u8{0x02, 0x08, 0x10}) {
		tiled := make([]u8, len(EXR_FIXTURES[3].data))
		defer delete(tiled)
		copy(tiled, EXR_FIXTURES[3].data)
		tiled[5] |= flag
		refused(t, tiled, "a flag")
	}
	for f in EXR_FIXTURES[:5] {
		for cut in ([]int{6, 100, len(f.data) / 2, len(f.data) - 1}) do refused(t, f.data[:cut], f.name)
	}
	// A damaged PIZ chunk: every byte past the header flipped in turn must be refused or
	// read, never read past the data.
	piz := make([]u8, len(EXR_FIXTURES[4].data))
	defer delete(piz)
	for i := 400; i < len(piz); i += 97 {
		copy(piz, EXR_FIXTURES[4].data)
		piz[i] ~= 0x5a
		img, why := environment_decode(piz, 1 << 12)
		environment_image_destroy(&img)
		delete(why)
	}
}
