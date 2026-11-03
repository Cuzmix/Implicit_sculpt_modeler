#+build js wasm32, js wasm64p32
#+private
package os

// Paths of the page's files (file_js.odin): one tree from "/", and "/" the working folder.

import "base:runtime"

_Path_Separator        :: '/'
_Path_Separator_String :: "/"
_Path_List_Separator   :: ':'

_is_path_separator :: proc(c: byte) -> (ok: bool) {
	return c == _Path_Separator
}

_mkdir :: proc(name: string, perm: Permissions) -> (err: Error) {
	switch sculpt_fs_mkdir(name) {
	case 0: return nil
	case 1: return .Exist
	}
	return .Not_Exist
}

_mkdir_all :: proc(path: string, perm: Permissions) -> (err: Error) {
	if path == "" do return .Invalid_Path
	if _exists(path) do return .Exist
	temp_allocator := TEMP_ALLOCATOR_GUARD({})
	clean := clean_path(path, temp_allocator) or_return
	for i in 1 ..= len(clean) {
		if i < len(clean) && clean[i] != '/' do continue
		if r := sculpt_fs_mkdir(clean[:i]); r < 0 do return .Not_Exist
	}
	return nil
}

_remove_all :: proc(path: string) -> (err: Error) {
	if sculpt_fs_kind(path) == 2 {
		need := sculpt_fs_list(path, nil)
		temp_allocator := TEMP_ALLOCATOR_GUARD({})
		names := make([]byte, max(need, 0), temp_allocator) or_return
		_ = sculpt_fs_list(path, names)
		start := 0
		for i in 0 ..< len(names) do if names[i] == 0 {
			child := concatenate({path, "/", string(names[start:i])}, temp_allocator) or_return
			_remove_all(child) or_return
			start = i + 1
		}
	}
	r := sculpt_fs_remove(path)
	return nil if r == 0 || r == -1 else .Invalid_Dir
}

_get_working_directory :: proc(allocator: runtime.Allocator) -> (dir: string, err: Error) {
	return clone_string("/", allocator)
}

_set_working_directory :: proc(dir: string) -> (err: Error) {
	return .Unsupported
}

_get_executable_path :: proc(allocator: runtime.Allocator) -> (path: string, err: Error) {
	return clone_string("/sculpt.wasm", allocator)
}

_are_paths_identical :: proc(a, b: string) -> bool {
	return a == b
}

_clean_path_handle_start :: proc(path: string, buffer: []u8) -> (rooted: bool, start: int) {
	if _is_path_separator(path[0]) {
		rooted = true
		buffer[0] = _Path_Separator
		start = 1
	}
	return
}

_is_absolute_path :: proc(path: string) -> bool {
	return len(path) > 0 && _is_path_separator(path[0])
}

_get_absolute_path :: proc(path: string, allocator: runtime.Allocator) -> (absolute_path: string, err: Error) {
	if _is_absolute_path(path) do return clean_path(path, allocator)
	temp_allocator := TEMP_ALLOCATOR_GUARD({allocator})
	joined := concatenate({"/", path}, temp_allocator) or_return
	return clean_path(joined, allocator)
}

_get_relative_path_handle_start :: proc(base, target: string) -> bool {
	base_rooted   := len(base)   > 0 && _is_path_separator(base[0])
	target_rooted := len(target) > 0 && _is_path_separator(target[0])
	return base_rooted == target_rooted
}

_get_common_path_len :: proc(base, target: string) -> int {
	i := 0
	end := min(len(base), len(target))
	for j in 0..=end {
		if j == end || _is_path_separator(base[j]) {
			if base[i:j] == target[i:j] {
				i = j
			} else {
				break
			}
		}
	}
	return i
}

_split_path :: proc(path: string) -> (dir, file: string) {
	i := len(path) - 1
	for i >= 0 && !_is_path_separator(path[i]) {
		i -= 1
	}
	if i == 0 {
		return path[:i+1], path[i+1:]
	} else if i > 0 {
		return path[:i], path[i+1:]
	}
	return "", path
}
