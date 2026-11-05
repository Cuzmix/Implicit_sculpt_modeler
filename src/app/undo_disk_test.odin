package main

import "core:hash"
import "core:os"
import "core:strings"
import "core:testing"

// A rebuild's copy goes to disk once written, leaving memory, and comes back byte for byte
// before it is read; the file goes with it, and a step dropped while on disk deletes its file.
@(test)
undo_copies_go_to_disk_and_come_back :: proc(t: ^testing.T) {
	app: App
	defer tree_free(&app)
	objs := tree_scene(&app)
	folder := "build/undo_disk_test/"
	_ = os.remove_all(folder)
	defer os.remove_all(folder)
	testing.expect(t, os.make_directory_all(folder) == nil)
	app.undo_disk.folder = folder
	app.undo_disk.min = 1
	defer app.undo_disk.folder = ""
	history_record_swap(&app, objs[0].id, history_snapshot(&app, objs[0], "remesh"))
	history_record_swap(&app, objs[1].id, history_snapshot(&app, objs[1], "remesh"))
	snap := app.history.done[0].swap
	size := snap.size
	sum := hash.crc32(snap.bytes[:])
	undo_disk_frame(&app)
	testing.expect(t, snap.disk != nil, "the oldest copy did not start writing")
	undo_disk_settle(snap, &app.undo_disk)
	testing.expect(t, snap.bytes == nil && snap.file != "" && os.exists(snap.file))
	testing.expect_value(t, history_disk_bytes(&app.history), size)
	testing.expect_value(t, app.history.swap_bytes, size + app.history.done[1].swap.size)
	file := snap.file
	testing.expect(t, undo_disk_load(&app, snap))
	testing.expect(t, snap.file == "" && !os.exists(file))
	testing.expect_value(t, len(snap.bytes), size)
	testing.expect_value(t, hash.crc32(snap.bytes[:]), sum)
	testing.expect_value(t, app.undo_disk.reads, 1)
	// Back in memory it goes again, the oldest first, then the second; dropping their
	// steps deletes the files.
	undo_disk_frame(&app)
	undo_disk_settle(snap, &app.undo_disk)
	undo_disk_frame(&app)
	second := app.history.done[1].swap
	undo_disk_settle(second, &app.undo_disk)
	testing.expect(t, snap.file != "" && second.file != "")
	// Copied: the files' names go with their steps.
	gone := [2]string{strings.clone(snap.file, context.temp_allocator), strings.clone(second.file, context.temp_allocator)}
	history_free_all(&app)
	for g in gone do testing.expect(t, !os.exists(g), "a dropped step left its file")
}
