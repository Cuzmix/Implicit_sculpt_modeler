#+build js wasm32, js wasm64p32
#+private
package os

// What the page's files are (file_js.odin).

import "base:runtime"
import "core:time"

_fstat :: proc(f: ^File, allocator: runtime.Allocator) -> (fi: File_Info, err: Error) {
	if f == nil || f.impl == nil do return {}, .Invalid_File
	return _stat((^File_Impl)(f.impl).name, allocator)
}

_stat :: proc(name: string, allocator: runtime.Allocator) -> (fi: File_Info, err: Error) {
	kind := sculpt_fs_kind(name)
	if kind == 0 do return {}, .Not_Exist
	fi.fullpath = _get_absolute_path(name, allocator) or_return
	_, fi.name = split_path(fi.fullpath)
	fi.type = .Directory if kind == 2 else .Regular
	fi.mode = Permissions_Default_Directory if kind == 2 else Permissions_Default_File
	fi.size = sculpt_fs_size(name) if kind == 1 else 0
	fi.modification_time = time.Time{i64(sculpt_fs_mtime(name) * 1e6)}
	fi.creation_time = fi.modification_time
	fi.access_time = fi.modification_time
	return
}

_lstat :: proc(name: string, allocator: runtime.Allocator) -> (fi: File_Info, err: Error) {
	return _stat(name, allocator)
}

_same_file :: proc(fi1, fi2: File_Info) -> bool {
	return fi1.fullpath == fi2.fullpath
}

_is_reserved_name :: proc(path: string) -> bool {
	return false
}
