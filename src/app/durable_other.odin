#+build !windows
package main

import "core:os"
import "core:path/filepath"

// Replaces `to` with `from` in one step and returns once the new name is on the disk: a
// rename is only durable once its folder is synced, or a power cut can bring back the old
// name, or neither.
replace_durably :: proc(from, to: string) -> os.Error {
	if err := os.rename(from, to); err != nil do return err
	sync_folder(filepath.dir(to))
	return nil
}

// Makes `dir`'s entries (a rename or a new link in it) durable. A folder that cannot be
// opened or synced (some file systems refuse) leaves the entry to the system's own flush.
sync_folder :: proc(dir: string) {
	f, err := os.open(dir if dir != "" else ".")
	if err != nil do return
	_ = os.sync(f)
	os.close(f)
}
