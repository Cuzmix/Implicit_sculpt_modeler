#+build js wasm32, js wasm64p32
#+private
package os

// Temporary files go in the page's own folder for them (file_js.odin).

import "base:runtime"

_temp_dir :: proc(allocator: runtime.Allocator) -> (string, runtime.Allocator_Error) {
	_ = sculpt_fs_mkdir("/tmp")
	return clone_string("/tmp", allocator)
}
