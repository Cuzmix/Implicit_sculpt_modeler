#+build js wasm32, js wasm64p32
#+private
package os

// The web version's files (README "Web"), in place of Odin's own js stand-ins, which do
// nothing. The page keeps every file in memory, by path, and keeps them in the browser's
// storage between visits (web/sdl_web.js answers the "sculpt_fs" imports below). A file
// here is its path and a position, and each read and write goes to the page. Standard
// output and error go to the browser's console.

import "base:runtime"
import "core:io"
import "core:time"

foreign import sculpt_fs "sculpt_fs"

@(default_calling_convention = "contextless")
foreign sculpt_fs {
	// 0 when nothing is at `path`, 1 for a file, 2 for a folder.
	sculpt_fs_kind :: proc(path: string) -> i32 ---
	sculpt_fs_size :: proc(path: string) -> i64 ---
	// When the file last changed, in milliseconds since 1970.
	sculpt_fs_mtime :: proc(path: string) -> f64 ---
	// Bytes read from `offset` into `buf`, or -1 where there is no file.
	sculpt_fs_read :: proc(path: string, offset: i64, buf: []byte) -> i64 ---
	// Bytes written at `offset`, the file growing as needed, or -1 where there is no file.
	sculpt_fs_write :: proc(path: string, offset: i64, buf: []byte) -> i64 ---
	// Makes an empty file, or empties the one there when `truncate`: 0, or -1 when the
	// folder it would go in is missing.
	sculpt_fs_create :: proc(path: string, truncate: bool) -> i32 ---
	sculpt_fs_truncate :: proc(path: string, size: i64) -> i32 ---
	// 0, 1 when something is there already, -1 when the folder it would go in is missing.
	sculpt_fs_mkdir :: proc(path: string) -> i32 ---
	// 0, -1 when nothing is there, -2 for a folder that is not empty.
	sculpt_fs_remove :: proc(path: string) -> i32 ---
	// 0, or -1 when nothing is at `from` or the folder `to` would go in is missing.
	sculpt_fs_rename :: proc(from, to: string) -> i32 ---
	// The names in folder `path`, each ending in a zero byte, written into `buf` while
	// they fit; the bytes they take, or -1 where there is no folder.
	sculpt_fs_list :: proc(path: string, buf: []byte) -> i64 ---
}

foreign import odin_env "odin_env"

@(default_calling_convention = "contextless")
foreign odin_env {
	// odin.js's own: 1 to the console's log, 2 to its errors.
	@(link_name = "write")
	console_write :: proc(fd: u32, p: []byte) ---
}

File_Impl :: struct {
	file:      File,
	name:      string,
	pos:       i64,
	flags:     File_Flags,
	console:   u32, // 1 or 2 for standard output or error, 0 for a file
	allocator: runtime.Allocator,
}

@(init)
_standard_stream_init :: proc "contextless" () {
	new_std :: proc "contextless" (impl: ^File_Impl, console: u32, name: string) -> ^File {
		impl.file.impl = impl
		impl.console = console
		impl.allocator = runtime.nil_allocator()
		impl.name = name
		impl.flags = {.Write}
		impl.file.stream = {data = impl, procedure = _file_stream_proc}
		return &impl.file
	}
	@(static) files: [3]File_Impl
	stdin = new_std(&files[0], 0, "/dev/stdin")
	stdout = new_std(&files[1], 1, "/dev/stdout")
	stderr = new_std(&files[2], 2, "/dev/stderr")
}

_open :: proc(name: string, flags: File_Flags, perm: Permissions) -> (f: ^File, err: Error) {
	if name == "" do return nil, .Invalid_Path
	switch sculpt_fs_kind(name) {
	case 0:
		if .Create not_in flags do return nil, .Not_Exist
		if sculpt_fs_create(name, true) != 0 do return nil, .Not_Exist
	case 1:
		if .Create in flags && .Excl in flags do return nil, .Exist
		if .Trunc in flags && sculpt_fs_create(name, true) != 0 do return nil, .Not_Exist
	case 2:
		if flags & {.Write, .Append, .Trunc} != {} do return nil, .Invalid_File
	}
	f, err = _new_file(0, name, file_allocator())
	if f != nil do (^File_Impl)(f.impl).flags = flags
	return
}

_new_file :: proc(handle: uintptr, name: string, allocator: runtime.Allocator) -> (f: ^File, err: Error) {
	impl := new(File_Impl, allocator) or_return
	impl.file.impl = impl
	impl.allocator = allocator
	impl.name = clone_string(name, allocator) or_return
	impl.file.stream = {data = impl, procedure = _file_stream_proc}
	return &impl.file, nil
}

_clone :: proc(f: ^File) -> (clone: ^File, err: Error) {
	if f == nil || f.impl == nil do return
	impl := (^File_Impl)(f.impl)
	clone = _new_file(0, impl.name, file_allocator()) or_return
	c := (^File_Impl)(clone.impl)
	c.pos, c.flags, c.console = impl.pos, impl.flags, impl.console
	return
}

_close :: proc(f: ^File_Impl) -> (err: Error) {
	if f == nil || f.console != 0 || f.allocator.procedure == nil do return nil
	if f.allocator == runtime.nil_allocator() do return nil
	delete(f.name, f.allocator)
	free(f, f.allocator)
	return nil
}

_fd :: proc(f: ^File) -> uintptr {
	return 0
}

_is_tty :: proc "contextless" (f: ^File) -> bool {
	return f != nil && f.impl != nil && (^File_Impl)(f.impl).console != 0
}

_name :: proc(f: ^File) -> string {
	return (^File_Impl)(f.impl).name if f != nil && f.impl != nil else ""
}

_sync :: proc(f: ^File) -> Error {
	return nil
}

_truncate :: proc(f: ^File, size: i64) -> Error {
	if f == nil || f.impl == nil do return .Invalid_File
	return nil if sculpt_fs_truncate((^File_Impl)(f.impl).name, size) == 0 else .Invalid_File
}

_remove :: proc(name: string) -> Error {
	switch sculpt_fs_remove(name) {
	case 0:  return nil
	case -2: return .Invalid_Dir
	}
	return .Not_Exist
}

_rename :: proc(old_path, new_path: string) -> Error {
	return nil if sculpt_fs_rename(old_path, new_path) == 0 else .Not_Exist
}

_link :: proc(old_name, new_name: string) -> Error {
	return .Unsupported
}

_symlink :: proc(old_name, new_name: string) -> Error {
	return .Unsupported
}

_read_link :: proc(name: string, allocator: runtime.Allocator) -> (s: string, err: Error) {
	return "", .Unsupported
}

_chdir :: proc(name: string) -> Error {
	return .Unsupported
}

_fchdir :: proc(f: ^File) -> Error {
	return .Unsupported
}

_fchmod :: proc(f: ^File, mode: Permissions) -> Error {
	return nil
}

_chmod :: proc(name: string, mode: Permissions) -> Error {
	return nil
}

_fchown :: proc(f: ^File, uid, gid: int) -> Error {
	return nil
}

_chown :: proc(name: string, uid, gid: int) -> Error {
	return nil
}

_lchown :: proc(name: string, uid, gid: int) -> Error {
	return nil
}

_chtimes :: proc(name: string, atime, mtime: time.Time) -> Error {
	return nil
}

_fchtimes :: proc(f: ^File, atime, mtime: time.Time) -> Error {
	return nil
}

_exists :: proc(path: string) -> bool {
	return sculpt_fs_kind(path) != 0
}

@(private = "file")
file_read_at :: proc(f: ^File_Impl, p: []byte, offset: i64) -> (i64, Error) {
	if len(p) == 0 do return 0, nil
	if offset < 0 do return 0, .Invalid_Offset
	if f.console != 0 do return 0, .EOF
	n := sculpt_fs_read(f.name, offset, p)
	if n < 0 do return 0, .Not_Exist
	return n, io.Error.EOF if n == 0 else nil
}

@(private = "file")
file_write_at :: proc(f: ^File_Impl, p: []byte, offset: i64) -> (i64, Error) {
	if f.console != 0 {
		console_write(f.console, p)
		return i64(len(p)), nil
	}
	if offset < 0 do return 0, .Invalid_Offset
	n := sculpt_fs_write(f.name, offset, p)
	if n < 0 do return 0, .Not_Exist
	return n, nil
}

_file_stream_proc :: proc(stream_data: rawptr, mode: File_Stream_Mode, p: []byte, offset: i64, whence: io.Seek_From, allocator: runtime.Allocator) -> (n: i64, err: Error) {
	f := (^File_Impl)(stream_data)
	switch mode {
	case .Read:
		n, err = file_read_at(f, p, f.pos)
		f.pos += n
	case .Read_At:
		n, err = file_read_at(f, p, offset)
	case .Write:
		if .Append in f.flags && f.console == 0 do f.pos = sculpt_fs_size(f.name)
		n, err = file_write_at(f, p, f.pos)
		f.pos += n
	case .Write_At:
		n, err = file_write_at(f, p, offset)
	case .Seek:
		base: i64
		switch whence {
		case .Start:   base = 0
		case .Current: base = f.pos
		case .End:     base = sculpt_fs_size(f.name)
		case:          return 0, .Invalid_Whence
		}
		if base + offset < 0 do return 0, .Invalid_Offset
		f.pos = base + offset
		n = f.pos
	case .Size:
		if f.console != 0 || sculpt_fs_kind(f.name) != 1 do return 0, .No_Size
		n = sculpt_fs_size(f.name)
	case .Flush:
	case .Close, .Destroy:
		err = _close(f)
	case .Query:
		return io.query_utility({.Read, .Read_At, .Write, .Write_At, .Seek, .Size, .Flush, .Close, .Destroy, .Query})
	case .Fstat:
		err = file_stream_fstat_utility(f, p, allocator)
	case:
		err = .Unsupported
	}
	return
}
