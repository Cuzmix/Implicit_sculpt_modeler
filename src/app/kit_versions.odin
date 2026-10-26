package main

import "core:fmt"
import "core:path/filepath"
import "core:strings"
import "core:time"

import "../ui"

// Menu > Earlier saves: the files the scene's saves replaced (versions.odin), newest
// first, under the menu button where the menu was. A tap opens one; with changes the
// file does not hold, the first tap turns the row red and asks, as New scene does.
kit_versions :: proc(app: ^App, anchor: ui.Rect) {
	k := &app.kit
	ctx := &k.ctx
	if !ui.popover_begin(ctx, "versions", &k.versions, anchor, .Below, {direction = .Column, padding = 6, width = 300}) do return
	ui.caption(ctx, fmt.tprintf("  EARLIER SAVES OF %s", strings.to_upper(filepath.base(app.scene_path), context.temp_allocator)))
	if len(app.versions) == 0 {
		ui.paragraph(ctx, "None yet: each save over this file keeps the one it replaces.")
	}
	now := time.now()
	today, yesterday := version_stamp(now), version_stamp(time.time_add(now, -24 * time.Hour))
	for v, i in app.versions {
		// Two saves in one minute show their seconds, or they would read the same.
		minute := v.stamp[:16]
		seconds := (i > 0 && app.versions[i - 1].stamp[:16] == minute) || (i + 1 < len(app.versions) && app.versions[i + 1].stamp[:16] == minute)
		armed := version_armed(app, i)
		label := "Discard changes and open?" if armed else version_when(v.stamp, today, yesterday, seconds)
		if !ui.menu_item(ctx, label, bytes_label(v.bytes), tone = .Danger if armed else .Neutral) do continue
		if scene_unsaved(app) && !armed {
			k.version_armed, k.version_armed_at = i + 1, max(ctx.time, 1e-6)
			continue
		}
		file_post(.Open_Version, v.path)
		k.versions, k.version_armed = false, 0
	}
	ui.divider(ctx, across = true)
	ui.paragraph(ctx, "Opening one replaces the scene. Save then makes it the current file again and keeps the one it replaces, so nothing is lost.")
	ui.popover_end(ctx)
}

// Whether the row `i` was tapped once and a second tap now opens it.
@(private = "file")
version_armed :: proc(app: ^App, i: int) -> bool {
	k := &app.kit
	return k.version_armed == i + 1 && k.ctx.time - k.version_armed_at < NEW_SCENE_ARM_TIME
}
