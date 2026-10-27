package zip

import "base:runtime"
import "core:bytes"
import "core:compress"
import "core:compress/zlib"
import "core:encoding/endian"
import "core:hash"
import "core:strings"
import "core:unicode/utf8"

// ZIP archives in and out: what a content pack is, so that any zip tool can make one. A pure
// package (no app, no SDL), as png_write is. Only what such a tool writes is read:
// entries stored or deflated, one disk, no encryption, no ZIP64. Everything an archive says is checked before it is believed:
// sizes against the limits and the bytes there, names against climbing out of the folder
// they unpack into, and each entry's bytes against its CRC once inflated. Archives out
// (write) hold stored entries only: what goes in a pack is mostly images compressed
// already.

Error :: enum u8 {
	None,
	Not_Zip,      // no end of central directory record
	Damaged,      // a record runs past the end, or a signature is wrong
	Unsupported,  // encrypted, split over disks, ZIP64, or a method other than stored and deflate
	Too_Many,     // more entries than the limit
	Too_Big,      // the entries unpack to more than the limit, or one inflates past its size
	Bad_Name,     // an absolute path, "..", a backslash, a drive, or a name that is not UTF-8
	Duplicate,    // two entries whose names differ at most in case
	Bad_Crc,      // an entry's bytes are not the ones the archive recorded
}

ERROR_TEXT := [Error]string {
	.None        = "",
	.Not_Zip     = "it is not a ZIP archive",
	.Damaged     = "the archive is damaged",
	.Unsupported = "it uses encryption, ZIP64 or a compression other than deflate",
	.Too_Many    = "it has too many files",
	.Too_Big     = "it unpacks to too much",
	.Bad_Name    = "a file in it has a name that could write outside its folder",
	.Duplicate   = "two files in it have the same name",
	.Bad_Crc     = "a file in it is damaged (its checksum does not match)",
}

Entry :: struct {
	name:          string, // into the archive's bytes; a folder's ends in '/'
	method:        u16,    // 0 stored, 8 deflate
	crc:           u32,
	packed, size:  int,
	local:         int, // the local header's offset
}

Limits :: struct {
	entries: int,
	total:   int, // bytes all entries unpack to
}

@(private = "file")
SIG_END :: 0x06054b50
@(private = "file")
SIG_CENTRAL :: 0x02014b50
@(private = "file")
SIG_LOCAL :: 0x04034b50

// The archive's entries, in the order its central directory lists them, folders
// included. Their names point into `data`.
entries :: proc(data: []u8, limits: Limits, allocator := context.allocator) -> (list: []Entry, err: Error) {
	u16le :: proc(b: []u8, at: int) -> int {return int(endian.unchecked_get_u16le(b[at:]))}
	u32le :: proc(b: []u8, at: int) -> int {return int(endian.unchecked_get_u32le(b[at:]))}
	// The end record is the last 22 bytes, or further back by its comment's length.
	end := -1
	for at := len(data) - 22; at >= max(0, len(data) - 22 - 65535); at -= 1 {
		if u32le(data, at) == SIG_END && at + 22 + u16le(data, at + 20) == len(data) {
			end = at
			break
		}
	}
	if end < 0 do return nil, .Not_Zip
	count, dir_size, dir_at := u16le(data, end + 10), u32le(data, end + 12), u32le(data, end + 16)
	if u16le(data, end + 4) != 0 || u16le(data, end + 6) != 0 || u16le(data, end + 8) != count do return nil, .Unsupported
	if count == 0xffff || dir_at == 0xffffffff || dir_size == 0xffffffff do return nil, .Unsupported
	if count > limits.entries do return nil, .Too_Many
	if dir_at + dir_size > end do return nil, .Damaged
	found := make([dynamic]Entry, 0, count, allocator)
	defer if err != .None do delete(found)
	// Names already seen, folded to lower case: two that differ only in case would be
	// one file on Windows and macOS, the second silently replacing the first.
	seen := make(map[string]struct{}, count, context.temp_allocator)
	at, total := dir_at, 0
	for _ in 0 ..< count {
		if at + 46 > end || u32le(data, at) != SIG_CENTRAL do return nil, .Damaged
		flags, method := u16le(data, at + 8), u16le(data, at + 10)
		name_len, extra_len, comment_len := u16le(data, at + 28), u16le(data, at + 30), u16le(data, at + 32)
		e := Entry {
			method = u16(method),
			crc    = u32(u32le(data, at + 16)),
			packed = u32le(data, at + 20),
			size   = u32le(data, at + 24),
			local  = u32le(data, at + 42),
		}
		if at + 46 + name_len > end do return nil, .Damaged
		e.name = string(data[at + 46:][:name_len])
		if flags & 1 != 0 || (method != 0 && method != 8) do return nil, .Unsupported
		if e.packed == 0xffffffff || e.size == 0xffffffff || e.local == 0xffffffff do return nil, .Unsupported
		if method == 0 && e.packed != e.size do return nil, .Damaged
		if !name_safe(e.name) do return nil, .Bad_Name
		folded := strings.to_lower(strings.trim_suffix(e.name, "/"), context.temp_allocator)
		if folded in seen do return nil, .Duplicate
		seen[folded] = {}
		total += e.size
		if total > limits.total do return nil, .Too_Big
		// The local header repeats the name; the data follows it and its own extra field.
		if e.local + 30 > dir_at || u32le(data, e.local) != SIG_LOCAL do return nil, .Damaged
		start := e.local + 30 + u16le(data, e.local + 26) + u16le(data, e.local + 28)
		if start + e.packed > dir_at do return nil, .Damaged
		append(&found, e)
		at += 46 + name_len + extra_len + comment_len
	}
	return found[:], .None
}

// Whether a name stays inside the folder it unpacks into and names the same file on
// every OS: relative, '/' between parts only, no "." or ".." or empty part (a folder's
// trailing '/' aside), none of the characters Windows refuses or a drive or stream ':',
// no part ending in a dot or space or named as a Windows device (CON, NUL, COM1...),
// and UTF-8.
name_safe :: proc(name: string) -> bool {
	if name == "" || !utf8.valid_string(name) do return false
	for c in transmute([]u8)name {
		switch c {
		case 0 ..< 0x20, 0x7f, '\\', ':', '*', '?', '"', '<', '>', '|':
			return false
		}
	}
	parts := strings.split(strings.trim_suffix(name, "/"), "/", context.temp_allocator)
	for p in parts {
		if p == "" || p == "." || p == ".." || strings.has_suffix(p, ".") || strings.has_suffix(p, " ") do return false
		stem := strings.to_upper(p[:strings.index_byte(p, '.')] if strings.contains_rune(p, '.') else p, context.temp_allocator)
		switch stem {
		case "CON", "PRN", "AUX", "NUL":
			return false
		}
		if len(stem) == 4 && (strings.has_prefix(stem, "COM") || strings.has_prefix(stem, "LPT")) && stem[3] >= '0' && stem[3] <= '9' do return false
	}
	return true
}

// The entry's bytes, inflated if deflated, checked against its size and CRC. Inflating
// never takes more than about twice what the entry says it holds, so an archive that
// lies about a size (a zip bomb) is refused rather than filling memory.
read :: proc(data: []u8, e: Entry, allocator := context.allocator) -> (out: []u8, err: Error) {
	start := e.local + 30 + int(endian.unchecked_get_u16le(data[e.local + 26:])) + int(endian.unchecked_get_u16le(data[e.local + 28:]))
	packed := data[start:][:e.packed]
	if e.method == 0 {
		out = make([]u8, e.size, allocator)
		copy(out, packed)
	} else {
		// zlib starts with at least COMPRESS_OUTPUT_ALLOCATE_MIN and grows its buffer by
		// doubling, also on the last byte of an exact fit, so twice that is the most an
		// honest entry asks for.
		cap := Capped{limit = 2 * max(e.size, compress.COMPRESS_OUTPUT_ALLOCATE_MIN), parent = allocator}
		buf: bytes.Buffer
		buf.buf = make([dynamic]u8, 0, 0, capped_allocator(&cap))
		failed := zlib.inflate_from_byte_array_raw(packed, &buf, expected_output_size = e.size)
		if failed != nil || len(buf.buf) != e.size {
			delete(buf.buf)
			return nil, .Too_Big if cap.refused || len(buf.buf) > e.size else .Damaged
		}
		out = buf.buf[:]
	}
	if hash.crc32(out) != e.crc {
		delete(out, allocator)
		return nil, .Bad_Crc
	}
	return out, .None
}

// An allocator that refuses to hold more than `limit` bytes in one block, so zlib's
// buffer cannot grow past what the entry declared.
@(private = "file")
Capped :: struct {
	limit:   int,
	parent:  runtime.Allocator,
	refused: bool,
}

@(private = "file")
capped_allocator :: proc(c: ^Capped) -> runtime.Allocator {
	return {procedure = proc(data: rawptr, mode: runtime.Allocator_Mode, size, alignment: int, old_memory: rawptr, old_size: int, loc := #caller_location) -> ([]byte, runtime.Allocator_Error) {
		c := cast(^Capped)data
		if (mode == .Alloc || mode == .Alloc_Non_Zeroed || mode == .Resize || mode == .Resize_Non_Zeroed) && size > c.limit {
			c.refused = true
			return nil, .Out_Of_Memory
		}
		return c.parent.procedure(c.parent.data, mode, size, alignment, old_memory, old_size, loc)
	}, data = c}
}


// A file to write into an archive: its name (folders joined by '/') and its bytes.
File :: struct {
	name: string,
	data: []u8,
}

// An archive of `files`, stored (not compressed), in the order given, dated 1 January
// 1980 (the format's first day) so the same files always make the same bytes. Every
// name must be safe (name_safe) and differ from the others in more than case, and the
// archive must stay within 4 GB and 65535 entries (no ZIP64): false otherwise.
write :: proc(files: []File, allocator := context.allocator) -> (out: []u8, ok: bool) {
	if len(files) > 0xffff do return nil, false
	total := 22
	for f, i in files {
		if !name_safe(f.name) || len(f.name) > 0xffff do return nil, false
		for g in files[:i] do if strings.equal_fold(f.name, g.name) do return nil, false
		total += 30 + 46 + 2 * len(f.name) + len(f.data)
	}
	if total > 0xffffffff do return nil, false
	buf := make([dynamic]u8, 0, total, allocator)
	u16le :: proc(b: ^[dynamic]u8, v: int) {append(b, u8(v), u8(v >> 8))}
	u32le :: proc(b: ^[dynamic]u8, v: u32) {append(b, u8(v), u8(v >> 8), u8(v >> 16), u8(v >> 24))}
	// 1980-01-01 00:00 in MS-DOS time and date.
	DOS_DATE :: (0 << 9) | (1 << 5) | 1
	header :: proc(b: ^[dynamic]u8, f: File, crc: u32) {
		u16le(b, 20) // the version needed: 2.0
		u16le(b, 1 << 11) // the name is UTF-8
		u16le(b, 0) // stored
		u16le(b, 0)
		u16le(b, DOS_DATE)
		u32le(b, crc)
		u32le(b, u32(len(f.data)))
		u32le(b, u32(len(f.data)))
		u16le(b, len(f.name))
		u16le(b, 0)
	}
	offsets := make([]u32, len(files), context.temp_allocator)
	crcs := make([]u32, len(files), context.temp_allocator)
	for f, i in files {
		offsets[i], crcs[i] = u32(len(buf)), hash.crc32(f.data)
		u32le(&buf, SIG_LOCAL)
		header(&buf, f, crcs[i])
		append(&buf, f.name)
		append(&buf, ..f.data)
	}
	directory := len(buf)
	for f, i in files {
		u32le(&buf, SIG_CENTRAL)
		u16le(&buf, 20) // made by 2.0, MS-DOS attributes
		header(&buf, f, crcs[i])
		u16le(&buf, 0) // comment
		u16le(&buf, 0) // disk
		u16le(&buf, 0) // internal attributes
		u32le(&buf, 0) // external attributes
		u32le(&buf, offsets[i])
		append(&buf, f.name)
	}
	directory_size := len(buf) - directory
	u32le(&buf, SIG_END)
	u16le(&buf, 0)
	u16le(&buf, 0)
	u16le(&buf, len(files))
	u16le(&buf, len(files))
	u32le(&buf, u32(directory_size))
	u32le(&buf, u32(directory))
	u16le(&buf, 0)
	return buf[:], true
}
