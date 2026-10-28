package main

import "core:fmt"
import "core:path/filepath"
import "core:strings"
import "core:unicode/utf8"

// Workspace files (Lens P1 round 10): a workspace written to a small text file, to carry
// a layout to another device or hand it to someone, and read back as a workspace of one's
// own, as Blender's and Photoshop's workspaces and ZBrush's UI configuration files travel.
// The file holds the workspace's name and its layout as kit_layout_text writes it (the
// bars, panels, columns, pins, grid and pass), never the scene, the brush or the dock.
// It is text, so it reads and diffs in any editor:
//
//	SCULPT_WORKSPACE 1
//	name Detail%20pass
//	layout open%20Inspector%0Abars%0A...
//
// The name and the layout are escaped as the settings file escapes them (preset_escape).

WORKSPACE_FILE_MAGIC :: "SCULPT_WORKSPACE"
WORKSPACE_FILE_VERSION :: 1
// The largest file read: a layout with every panel pinned and every bar full is under 8 KB.
WORKSPACE_FILE_MAX :: 64 * 1024
WORKSPACE_FILE_SUFFIX :: ".workspace"

// The file's text for the workspace named `name` with layout `layout`.
workspace_file_text :: proc(name, layout: string) -> string {
	return fmt.tprintf("%s %d\nname %s\nlayout %s\n", WORKSPACE_FILE_MAGIC, WORKSPACE_FILE_VERSION, preset_escape(name), preset_escape(layout))
}

// The name and layout in a workspace file's bytes (temp strings); false when it is not one,
// is from a newer version, is too big, or holds anything but text.
workspace_file_read :: proc(data: []u8) -> (name, layout: string, ok: bool) {
	if len(data) > WORKSPACE_FILE_MAX || !utf8.valid_string(string(data)) do return
	lines := strings.split_lines(string(data), context.temp_allocator)
	if len(lines) < 3 do return
	head := strings.fields(lines[0], context.temp_allocator)
	if len(head) != 2 || head[0] != WORKSPACE_FILE_MAGIC do return
	version := 0
	for c in transmute([]u8)head[1] {
		if c < '0' || c > '9' || version > 1000 do return
		version = version * 10 + int(c - '0')
	}
	if version < 1 || version > WORKSPACE_FILE_VERSION do return
	got_name, got_layout := false, false
	for line in lines[1:] {
		f := strings.fields(line, context.temp_allocator)
		if len(f) != 2 do continue
		switch f[0] {
		case "name":
			name, got_name = strings.trim_space(preset_unescape(f[1])), true
		case "layout":
			layout, got_layout = preset_unescape(f[1]), true
		}
	}
	// A name that cannot be shown (control characters, a name too long for the switcher)
	// is cut to what fits, never refused: the layout is what matters.
	if got_name {
		b := strings.builder_make(context.temp_allocator)
		for r in name do if r >= ' ' && strings.builder_len(b) + utf8.rune_size(r) < WORKSPACE_NAME do strings.write_rune(&b, r)
		name = strings.to_string(b)
	}
	if name == "" do name = "Workspace"
	ok = got_layout
	return
}

// The layout `text` as the app writes it: read into a fresh interface and written again,
// so what a file names that no version knows is dropped and the rest is in order.
workspace_layout_clean :: proc(text: string) -> string {
	s := new(Kit_State, context.temp_allocator)
	bars_reset(s)
	kit_layout_put(s, text)
	return kit_layout_text(s)
}

// Writes the current workspace, as it is now, to `path`.
workspace_export :: proc(app: ^App, path: string) -> bool {
	k := &app.kit
	if len(k.workspaces.list) == 0 do return false
	name := workspace_name(k, k.workspaces.current)
	text := workspace_file_text(name, kit_layout_text(k))
	if why := write_durably(path, transmute([]u8)text); why != "" {
		file_note(app, true, "Cannot export the workspace to %s: %s", filepath.base(path), why)
		return false
	}
	k.workspaces.exports += 1
	file_note(app, false, "Exported workspace %s to %s", name, filepath.base(path))
	return true
}

// Reads the workspace file at `path` as a new workspace of the user's own and switches to
// it, the one left kept as it was left.
workspace_import :: proc(app: ^App, path: string) -> bool {
	k := &app.kit
	data, err := file_read_any(path, context.temp_allocator)
	if err != nil {
		file_note(app, true, "Cannot open %s: %v", filepath.base(path), err)
		return false
	}
	name, layout, ok := workspace_file_read(data)
	if !ok {
		file_note(app, true, "Cannot import %s: it is not a workspace file, or it is from a newer version", filepath.base(path))
		return false
	}
	slot, added := workspace_add(k, name, workspace_layout_clean(layout))
	if !added {
		file_note(app, true, "Cannot import %s: all %d workspaces of your own are in use; delete one first", filepath.base(path), WORKSPACE_OWN)
		return false
	}
	k.workspaces.imports += 1
	file_note(app, false, "Imported workspace %s", workspace_name(k, slot))
	return true
}
