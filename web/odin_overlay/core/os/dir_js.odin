#+build js wasm32, js wasm64p32
#+private
package os

// A folder of the page's files (file_js.odin), listed once when the iterator starts.

Read_Directory_Iterator_Impl :: struct {
	names:   []byte,
	off:     int,
	prev_fi: File_Info,
}

@(require_results)
_read_directory_iterator :: proc(it: ^Read_Directory_Iterator) -> (fi: File_Info, index: int, ok: bool) {
	if it.f == nil || it.impl.off >= len(it.impl.names) do return
	rest := it.impl.names[it.impl.off:]
	end := 0
	for end < len(rest) && rest[end] != 0 do end += 1
	name := string(rest[:end])
	it.impl.off += end + 1
	index = it.index
	it.index += 1

	file_info_delete(it.impl.prev_fi, file_allocator())
	it.impl.prev_fi = {}
	temp_allocator := TEMP_ALLOCATOR_GUARD({})
	path, _ := concatenate({_name(it.f), "/", name}, temp_allocator)
	err: Error
	fi, err = _stat(path, file_allocator())
	if err != nil {
		read_directory_iterator_set_error(it, path, err)
		return fi, index, true
	}
	it.impl.prev_fi = fi
	return fi, index, true
}

_read_directory_iterator_init :: proc(it: ^Read_Directory_Iterator, f: ^File) {
	delete(it.impl.names, file_allocator())
	it.impl.names, it.impl.off = nil, 0
	if f == nil || f.impl == nil do return
	path := _name(f)
	need := sculpt_fs_list(path, nil)
	if need < 0 {
		read_directory_iterator_set_error(it, path, .Invalid_Dir)
		return
	}
	names, err := make([]byte, need, file_allocator())
	if err != nil {
		read_directory_iterator_set_error(it, path, err)
		return
	}
	_ = sculpt_fs_list(path, names)
	it.impl.names = names
}

_read_directory_iterator_destroy :: proc(it: ^Read_Directory_Iterator) {
	delete(it.impl.names, file_allocator())
	file_info_delete(it.impl.prev_fi, file_allocator())
	it.impl = {}
}
