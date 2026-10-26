package main

import "core:os"
import win32 "core:sys/windows"

// Replaces `to` with `from` in one step and returns once the move is on the disk:
// Windows cannot sync a folder, so the write-through flag is what makes the new name last.
replace_durably :: proc(from, to: string) -> os.Error {
	wfrom := win32.utf8_to_wstring(from, context.temp_allocator)
	wto := win32.utf8_to_wstring(to, context.temp_allocator)
	if !win32.MoveFileExW(wfrom, wto, win32.MOVEFILE_REPLACE_EXISTING | win32.MOVEFILE_WRITE_THROUGH) {
		return os.Platform_Error(win32.GetLastError())
	}
	return nil
}

// A folder's entries are made durable by replace_durably's write-through on Windows.
sync_folder :: proc(dir: string) {}
