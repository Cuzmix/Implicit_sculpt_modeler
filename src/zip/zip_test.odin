package zip

import "core:hash"
import "core:strings"
import "core:testing"

import "../png_write"

// One entry of an archive the tests make: its bytes, stored or deflated, and what the
// archive should claim about them where a test lies (a size, a CRC, flags, a method).
@(private = "file")
Item :: struct {
	name:    string,
	data:    []u8,
	deflate: bool,
	flags:   u16,
	method:  int, // when not 0, the method the archive claims
	size:    int, // when not 0, the size the archive claims
	crc:     u32, // when not 0, the CRC the archive claims
}

// An archive of `items` as a zip tool writes it: local headers with their data, then the
// central directory, then the end record.
@(private = "file")
archive :: proc(items: []Item, allocator := context.temp_allocator) -> []u8 {
	out := make([dynamic]u8, allocator)
	u16le :: proc(out: ^[dynamic]u8, v: int) {append(out, u8(v), u8(v >> 8))}
	u32le :: proc(out: ^[dynamic]u8, v: int) {append(out, u8(v), u8(v >> 8), u8(v >> 16), u8(v >> 24))}
	Fields :: struct {
		method, crc, packed, size, local: int,
		packed_bytes:                     []u8,
	}
	fields := make([]Fields, len(items), context.temp_allocator)
	for it, i in items {
		f := &fields[i]
		f.packed_bytes = png_write.deflate(it.data, context.temp_allocator) if it.deflate else it.data
		f.method = it.method if it.method != 0 else (8 if it.deflate else 0)
		f.crc = int(it.crc if it.crc != 0 else hash.crc32(it.data))
		f.packed = len(f.packed_bytes)
		f.size = it.size if it.size != 0 else len(it.data)
		f.local = len(out)
		u32le(&out, 0x04034b50)
		u16le(&out, 20)
		u16le(&out, int(it.flags))
		u16le(&out, f.method)
		u32le(&out, 0) // time and date
		u32le(&out, f.crc)
		u32le(&out, f.packed)
		u32le(&out, f.size)
		u16le(&out, len(it.name))
		u16le(&out, 0)
		append(&out, it.name)
		append(&out, ..f.packed_bytes)
	}
	dir := len(out)
	for it, i in items {
		f := fields[i]
		u32le(&out, 0x02014b50)
		u16le(&out, 20)
		u16le(&out, 20)
		u16le(&out, int(it.flags))
		u16le(&out, f.method)
		u32le(&out, 0)
		u32le(&out, f.crc)
		u32le(&out, f.packed)
		u32le(&out, f.size)
		u16le(&out, len(it.name))
		for _ in 0 ..< 4 do u16le(&out, 0) // extra, comment, disk, internal attributes
		u32le(&out, 0) // external attributes
		u32le(&out, f.local)
		append(&out, it.name)
	}
	u32le(&out, 0x06054b50)
	u16le(&out, 0)
	u16le(&out, 0)
	u16le(&out, len(items))
	u16le(&out, len(items))
	u32le(&out, len(out) - 12 - dir)
	u32le(&out, dir)
	u16le(&out, 0)
	return out[:]
}

@(private = "file")
LIMITS :: Limits{entries = 64, total = 64 << 20}

// What reading every entry of `data` comes to: the first error, from the directory or
// from an entry.
@(private = "file")
read_all :: proc(data: []u8, limits := LIMITS) -> Error {
	list, err := entries(data, limits)
	if err != .None do return err
	defer delete(list)
	for e in list {
		bytes := read(data, e) or_return
		delete(bytes)
	}
	return .None
}

@(private = "file")
text :: proc(s: string) -> []u8 {return transmute([]u8)s}

// An archive with a folder, a deflated file and a stored one reads back as written, the
// deflated file through our own deflate as the writer.
@(test)
reads_stored_and_deflated :: proc(t: ^testing.T) {
	long := strings.repeat("name Rocks\nauthor Bolt\n", 50, context.temp_allocator)
	data := archive({{name = "alphas/"}, {name = "pack.txt", data = text(long), deflate = true}, {name = "alphas/r.txt", data = text("stored bytes")}})
	list, err := entries(data, LIMITS)
	defer delete(list)
	testing.expect_value(t, err, Error.None)
	testing.expect_value(t, len(list), 3)
	if len(list) != 3 do return
	testing.expect_value(t, list[0].name, "alphas/")
	testing.expect_value(t, list[1].method, u16(8))
	testing.expect(t, list[1].packed < list[1].size, "the file was not deflated")
	for e, i in list {
		bytes, read_err := read(data, e)
		defer delete(bytes)
		testing.expect_value(t, read_err, Error.None)
		testing.expect_value(t, string(bytes), ([]string{"", long, "stored bytes"})[i])
	}
	free_all(context.temp_allocator)
}

// Python's zipfile writing to a stream (data descriptors after each entry, zero sizes in
// the local headers, its own deflate, an archive comment): the sizes come from the
// central directory, so it reads as another tool wrote it.
@(test)
reads_what_python_writes :: proc(t: ^testing.T) {
	data := []u8 {
		0x50, 0x4b, 0x03, 0x04, 0x14, 0x00, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x21, 0x00, 0x00, 0x00,
		0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x07, 0x00, 0x00, 0x00, 0x61, 0x6c,
		0x70, 0x68, 0x61, 0x73, 0x2f, 0x50, 0x4b, 0x07, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
		0x00, 0x00, 0x00, 0x00, 0x00, 0x50, 0x4b, 0x03, 0x04, 0x14, 0x00, 0x08, 0x00, 0x08, 0x00, 0x74,
		0x02, 0x5b, 0x5d, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x08,
		0x00, 0x00, 0x00, 0x70, 0x61, 0x63, 0x6b, 0x2e, 0x74, 0x78, 0x74, 0xcb, 0x4b, 0xcc, 0x4d, 0x55,
		0x08, 0xca, 0x4f, 0xce, 0x2e, 0xe6, 0x4a, 0x2c, 0x2d, 0xc9, 0xc8, 0x2f, 0x52, 0x70, 0xca, 0xcf,
		0x29, 0xe1, 0x2a, 0x4b, 0x2d, 0x2a, 0xce, 0xcc, 0xcf, 0x53, 0x30, 0xe4, 0xca, 0xa3, 0x58, 0x01,
		0x00, 0x50, 0x4b, 0x07, 0x08, 0x8c, 0xd0, 0xbd, 0xb7, 0x26, 0x00, 0x00, 0x00, 0x63, 0x00, 0x00,
		0x00, 0x50, 0x4b, 0x03, 0x04, 0x14, 0x00, 0x08, 0x00, 0x00, 0x00, 0x74, 0x02, 0x5b, 0x5d, 0x00,
		0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x0c, 0x00, 0x00, 0x00, 0x61,
		0x6c, 0x70, 0x68, 0x61, 0x73, 0x2f, 0x72, 0x2e, 0x74, 0x78, 0x74, 0x73, 0x74, 0x6f, 0x72, 0x65,
		0x64, 0x20, 0x62, 0x79, 0x74, 0x65, 0x73, 0x50, 0x4b, 0x07, 0x08, 0x78, 0x77, 0xa6, 0x0f, 0x0c,
		0x00, 0x00, 0x00, 0x0c, 0x00, 0x00, 0x00, 0x50, 0x4b, 0x01, 0x02, 0x14, 0x03, 0x14, 0x00, 0x08,
		0x00, 0x00, 0x00, 0x00, 0x00, 0x21, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
		0x00, 0x00, 0x00, 0x07, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x80,
		0x01, 0x00, 0x00, 0x00, 0x00, 0x61, 0x6c, 0x70, 0x68, 0x61, 0x73, 0x2f, 0x50, 0x4b, 0x01, 0x02,
		0x14, 0x03, 0x14, 0x00, 0x08, 0x00, 0x08, 0x00, 0x74, 0x02, 0x5b, 0x5d, 0x8c, 0xd0, 0xbd, 0xb7,
		0x26, 0x00, 0x00, 0x00, 0x63, 0x00, 0x00, 0x00, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
		0x00, 0x00, 0x00, 0x00, 0x80, 0x01, 0x35, 0x00, 0x00, 0x00, 0x70, 0x61, 0x63, 0x6b, 0x2e, 0x74,
		0x78, 0x74, 0x50, 0x4b, 0x01, 0x02, 0x14, 0x03, 0x14, 0x00, 0x08, 0x00, 0x00, 0x00, 0x74, 0x02,
		0x5b, 0x5d, 0x78, 0x77, 0xa6, 0x0f, 0x0c, 0x00, 0x00, 0x00, 0x0c, 0x00, 0x00, 0x00, 0x0c, 0x00,
		0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x80, 0x01, 0x91, 0x00, 0x00, 0x00,
		0x61, 0x6c, 0x70, 0x68, 0x61, 0x73, 0x2f, 0x72, 0x2e, 0x74, 0x78, 0x74, 0x50, 0x4b, 0x05, 0x06,
		0x00, 0x00, 0x00, 0x00, 0x03, 0x00, 0x03, 0x00, 0xa5, 0x00, 0x00, 0x00, 0xd7, 0x00, 0x00, 0x00,
		0x0e, 0x00, 0x6d, 0x61, 0x64, 0x65, 0x20, 0x62, 0x79, 0x20, 0x70, 0x79, 0x74, 0x68, 0x6f, 0x6e,
	}
	list, err := entries(data, LIMITS)
	defer delete(list)
	testing.expect_value(t, err, Error.None)
	testing.expect_value(t, len(list), 3)
	if len(list) != 3 do return
	pack, pack_err := read(data, list[1])
	defer delete(pack)
	testing.expect_value(t, pack_err, Error.None)
	testing.expect_value(t, string(pack), "name Rocks\nauthor Bolt\nversion 1\nname Rocks\nauthor Bolt\nversion 1\nname Rocks\nauthor Bolt\nversion 1\n")
	stored, stored_err := read(data, list[2])
	defer delete(stored)
	testing.expect_value(t, stored_err, Error.None)
	testing.expect_value(t, string(stored), "stored bytes")
	free_all(context.temp_allocator)
}

// A zip bomb: an entry that says it holds 10 bytes but inflates to 4 MB is refused
// without inflating it all; one that inflates to less than it says is damaged; and
// honest entries past the total limit are refused before any is read.
@(test)
refuses_lies_about_sizes :: proc(t: ^testing.T) {
	zeros := make([]u8, 4 << 20, context.temp_allocator)
	testing.expect_value(t, read_all(archive({{name = "bomb.png", data = zeros, deflate = true, size = 10}})), Error.Too_Big)
	testing.expect_value(t, read_all(archive({{name = "short.png", data = text("only a little"), deflate = true, size = 50}})), Error.Damaged)
	testing.expect_value(t, read_all(archive({{name = "big.png", data = zeros, deflate = true}}), Limits{entries = 64, total = 1 << 20}), Error.Too_Big)
	testing.expect_value(t, read_all(archive({{name = "big.png", data = zeros, deflate = true}})), Error.None)
	// A stored entry cannot claim a size other than the bytes it has.
	testing.expect_value(t, read_all(archive({{name = "s.txt", data = text("abc"), size = 9}})), Error.Damaged)
	free_all(context.temp_allocator)
}

@(test)
refuses_bad_bytes_and_features :: proc(t: ^testing.T) {
	testing.expect_value(t, read_all(archive({{name = "a.txt", data = text("abc"), crc = 1}})), Error.Bad_Crc)
	testing.expect_value(t, read_all(archive({{name = "a.txt", data = text("abc"), deflate = true, crc = 1}})), Error.Bad_Crc)
	testing.expect_value(t, read_all(archive({{name = "a.txt", data = text("abc"), flags = 1}})), Error.Unsupported)
	testing.expect_value(t, read_all(archive({{name = "a.txt", data = text("abc"), method = 12}})), Error.Unsupported)
	testing.expect_value(t, read_all(text("not an archive at all, just some text")), Error.Not_Zip)
	testing.expect_value(t, read_all(nil), Error.Not_Zip)

	// Cut short, the end record is gone; with the end record kept but the data cut out
	// from under it, the records no longer fit.
	whole := archive({{name = "a.txt", data = text("some bytes here")}})
	testing.expect_value(t, read_all(whole[:len(whole) - 5]), Error.Not_Zip)
	cut := make([dynamic]u8, context.temp_allocator)
	append(&cut, ..whole[:10])
	append(&cut, ..whole[len(whole) - 22:])
	testing.expect_value(t, read_all(cut[:]), Error.Damaged)

	many := make([]Item, 65, context.temp_allocator)
	for &it, i in many do it = {name = strings.concatenate({"f", string([]u8{u8('a' + i / 26), u8('a' + i % 26)})}, context.temp_allocator)}
	testing.expect_value(t, read_all(archive(many)), Error.Too_Many)
	testing.expect_value(t, read_all(archive(many[:64])), Error.None)
	free_all(context.temp_allocator)
}

// Names that would climb out of the folder a pack unpacks into (zip slip), or would mean
// something else on another OS, are refused, and so are two that differ only in case.
@(test)
refuses_names_that_escape_or_clash :: proc(t: ^testing.T) {
	for name in ([]string{"alphas/a.png", "pack.txt", "alphas/", "a b/c.d.png", "Ü/ß.png", ".hidden"}) {
		testing.expectf(t, name_safe(name), "%q was refused", name)
	}
	bad := []string {
		"", "/etc/passwd", "../up.png", "alphas/../../up.png", "a/./b", "a//b", "C:/x.png", "c:x", "a\\..\\b",
		"con", "alphas/NUL.png", "lpt1.txt", "COM9", "dot.", "space ", "a?.png", "a|b", "a\x00b", "a\nb", "\xff.png",
	}
	for name in bad do testing.expectf(t, !name_safe(name), "%q was allowed", name)
	testing.expect_value(t, read_all(archive({{name = "../evil.png", data = text("x")}})), Error.Bad_Name)
	testing.expect_value(t, read_all(archive({{name = "a.png", data = text("x")}, {name = "A.PNG", data = text("y")}})), Error.Duplicate)
	testing.expect_value(t, read_all(archive({{name = "a.png", data = text("x")}, {name = "a.png", data = text("y")}})), Error.Duplicate)
	testing.expect_value(t, read_all(archive({{name = "alphas/"}, {name = "Alphas/"}})), Error.Duplicate)
	free_all(context.temp_allocator)
}

// What write makes reads back entry for entry, the same files make the same bytes, and
// an unsafe name or two names that differ only in case are refused.
@(test)
writes_what_it_reads :: proc(t: ^testing.T) {
	files := []File{{"pack.txt", transmute([]u8)string("name Mine\n")}, {"alphas/", nil}, {"alphas/Rock é.png", transmute([]u8)string("\x89PNG not really")}}
	out, ok := write(files, context.temp_allocator)
	testing.expect(t, ok)
	again, _ := write(files, context.temp_allocator)
	testing.expect_value(t, string(again), string(out))
	list, err := entries(out, {entries = 10, total = 1 << 20}, context.temp_allocator)
	if !testing.expect_value(t, err, Error.None) do return
	testing.expect_value(t, len(list), 3)
	for e, i in list {
		testing.expect_value(t, e.name, files[i].name)
		data, read_err := read(out, e, context.temp_allocator)
		testing.expect_value(t, read_err, Error.None)
		testing.expect_value(t, string(data), string(files[i].data))
	}
	_, bad := write({{"../escape.png", nil}}, context.temp_allocator)
	testing.expect(t, !bad)
	_, twice := write({{"a.png", nil}, {"A.PNG", nil}}, context.temp_allocator)
	testing.expect(t, !twice)
	free_all(context.temp_allocator)
}
