package main

import "base:runtime"
import "core:image/png"
import "core:slice"
import "core:strings"
import "core:sync"
import "core:thread"

import "../render"

// The Home screen's side that is not drawing (kit_home.odin draws it): the scenes saved or
// opened lately, which the settings file keeps; each tile's picture, read from the start
// of its scene file (scene_preview_read) on a thread of its own, so a slow disk or a
// content:// file never holds a frame, and put into a cell of a picture atlas at most
// render.PICTURES_PER_FRAME a frame; and the autosaves of earlier sessions.

// The most scenes Recent keeps.
HOME_RECENT_MAX :: 24

Home_Tab :: enum u8 {
	Recent,
	Autosaves,
}

// Where a tile's picture is.
Home_Picture :: enum u8 {
	Waiting, // not asked for yet
	Asked, // the loader has it
	Shown, // in its cell
	None, // the file has no picture (saved before version 22)
	Missing, // the file is gone, or no scene this app reads
}

Home_Tile :: struct {
	path:  string,
	state: Home_Picture,
	info:  Scene_File_Info,
	cell:  int, // its atlas cell while Shown, else -1
	w, h:  int, // its picture's size in the cell
	shown: u64, // the Home frame it was last drawn in, so the cell shown longest ago is the one reused
}

Home :: struct {
	tiles:     [dynamic]Home_Tile,
	pictures:  render.Pictures,
	owner:     [render.PICTURE_SLOTS]int, // the tile each cell holds, -1 for none
	loader:    ^Home_Loader,
	autosaves: [dynamic]Autosave_Entry, // listed as Home opened, strings owned here
	frame:     u64, // counts the frames Home was drawn in
	// For the exit stats: how often Home opened, pictures read and put in cells.
	opened, read, uploaded: int,
}

// The thread that reads tiles' pictures: paths go in, decoded pictures come out, both in
// the heap allocator, as anything a thread makes or frees is.
@(private = "file")
Home_Loader :: struct {
	thread: ^thread.Thread,
	lock:   sync.Mutex,
	wake:   sync.Sema,
	quit:   bool, // under lock
	todo:   [dynamic]string, // under lock: paths to read, in order
	done:   [dynamic]Home_Loaded, // under lock: what was read
}

@(private = "file")
Home_Loaded :: struct {
	path:   string,
	info:   Scene_File_Info,
	ok:     bool,
	pixels: []u8, // RGBA8, nil for no picture
	w, h:   int,
}

home_destroy :: proc(app: ^App) {
	h := &app.home
	if l := h.loader; l != nil {
		sync.lock(&l.lock)
		l.quit = true
		sync.unlock(&l.lock)
		sync.sema_post(&l.wake)
		thread.join(l.thread)
		thread.destroy(l.thread)
		heap := runtime.heap_allocator()
		for p in l.todo do delete(p, heap)
		for d in l.done do loaded_free(d)
		delete(l.todo)
		delete(l.done)
		free(l, heap)
	}
	tiles_clear(h)
	delete(h.tiles)
	autosaves_clear(h)
	delete(h.autosaves)
	if render.renderer_ready(&app.renderer) do render.pictures_destroy(&app.renderer, &h.pictures)
	h^ = {}
}

// Opens the Home screen over everything, its pictures read afresh: a scene saved since
// it last showed has a new one. It opens on Autosaves when an earlier session crashed,
// or when Recent has nothing to show.
home_open :: proc(app: ^App) {
	h := &app.home
	k := &app.kit
	kit_floats_close(k)
	if k.palette do palette_close(app)
	tiles_clear(h)
	autosaves_clear(h)
	for e in autosave_entries(app) {
		append(&h.autosaves, Autosave_Entry{strings.clone(e.session), strings.clone(e.path), strings.clone(e.scene), e.at, e.crashed})
	}
	k.home, k.home_scroll, k.home_armed, k.home_menu = true, 0, 0, false
	k.home_tab = .Autosaves if len(app.autosave.offers) > 0 || (len(app.recent_scenes) == 0 && len(h.autosaves) > 0) else .Recent
	h.opened += 1
}

// Closes the Home screen, letting go of its pictures: the atlas is several megabytes a
// tablet can use for sculpting, and the next opening reads them afresh anyway.
home_close :: proc(app: ^App) {
	k := &app.kit
	h := &app.home
	k.home, k.home_menu, k.home_armed = false, false, 0
	if l := h.loader; l != nil {
		sync.lock(&l.lock)
		for p in l.todo do delete(p, runtime.heap_allocator())
		clear(&l.todo)
		sync.unlock(&l.lock)
	}
	tiles_clear(h)
	if render.renderer_ready(&app.renderer) do render.pictures_destroy(&app.renderer, &h.pictures)
}

// The tile of the scene file at `path` as it is drawn this frame, made on first ask, and
// its picture asked for.
home_tile :: proc(app: ^App, path: string) -> Home_Tile {
	h := &app.home
	i := tile_find(h, path)
	if i < 0 {
		append(&h.tiles, Home_Tile{path = strings.clone(path), cell = -1})
		i = len(h.tiles) - 1
	}
	t := &h.tiles[i]
	t.shown = h.frame
	if t.state == .Waiting {
		loader_ask(app, path)
		t.state = .Asked
	}
	return t^
}

// Whether pictures are still on their way, so the frame loop keeps drawing.
home_busy :: proc(app: ^App) -> bool {
	l := app.home.loader
	if !app.kit.home || l == nil do return false
	sync.lock(&l.lock)
	defer sync.unlock(&l.lock)
	return len(l.todo) > 0 || len(l.done) > 0
}

// At the end of a frame Home was drawn in: what the loader read goes into the tiles,
// and up to render.PICTURES_PER_FRAME pictures into atlas cells on `cmd`.
home_frame :: proc(app: ^App, cmd: render.Cmd) {
	h := &app.home
	l := h.loader
	if !app.kit.home || l == nil do return
	// The tiles drawn this frame carry this number; the next frame's the next.
	defer h.frame += 1
	uploads: [render.PICTURES_PER_FRAME]render.Picture_Upload
	n := 0
	taken := make([dynamic]Home_Loaded, context.temp_allocator)
	sync.lock(&l.lock)
	for len(l.done) > 0 {
		if l.done[0].pixels != nil && n == len(uploads) do break
		d := l.done[0]
		ordered_remove(&l.done, 0)
		append(&taken, d)
		if d.pixels != nil do n += 1
	}
	sync.unlock(&l.lock)
	n = 0
	for d in taken {
		h.read += 1
		i := tile_find(h, d.path)
		if i < 0 do continue
		t := &h.tiles[i]
		switch {
		case !d.ok:
			t.state = .Missing
		case d.pixels == nil:
			t.state, t.info = .None, d.info
		case:
			t.info = d.info
			cell := cell_take(h, i)
			if cell < 0 {
				// Every cell shows a tile drawn this frame: this one is read again later.
				t.state = .Waiting
				continue
			}
			uploads[n] = {cell, d.pixels, d.w, d.h}
			n += 1
			t.state, t.cell, t.w, t.h = .Shown, cell, d.w, d.h
		}
	}
	if n > 0 && render.pictures_upload(&app.renderer, &h.pictures, cmd, uploads[:n]) do h.uploaded += n
	for d in taken do loaded_free(d)
}

// Whether the run starts on Home: an interactive run given no scene, script or file.
home_at_start :: proc(app: ^App, opts: Options, interactive: bool) -> bool {
	return app.start_home && interactive && opts.open == "" && opts.import_mesh == "" && opts.script == "" && opts.run == "" && opts.ui_events == "" && opts.load_strokes == "" && opts.import_workspace == ""
}

// Puts `path` first in Recent, once, keeping HOME_RECENT_MAX, and remembers it at once,
// so a crash keeps the list too.
recent_scene_add :: proc(app: ^App, path: string) {
	if path == "" do return
	recent_scene_drop(app, path, save = false)
	inject_at(&app.recent_scenes, 0, strings.clone(path))
	for len(app.recent_scenes) > HOME_RECENT_MAX do delete(pop(&app.recent_scenes))
	if app.settings_file != "" do _ = settings_save(app, app.settings_file)
}

// Takes `path` off Recent.
recent_scene_drop :: proc(app: ^App, path: string, save := true) {
	for s, i in app.recent_scenes do if s == path {
		delete(s)
		ordered_remove(&app.recent_scenes, i)
		// The tiles after it moved up: an armed one would now be another.
		app.kit.home_armed = 0
		if save && app.settings_file != "" do _ = settings_save(app, app.settings_file)
		return
	}
}

@(private = "file")
tile_find :: proc(h: ^Home, path: string) -> int {
	for t, i in h.tiles do if t.path == path do return i
	return -1
}

// A cell for tile `me`: its own, a free one, or else the one whose tile was drawn
// longest ago, which reads its picture again when it shows; -1 when every cell shows a
// tile drawn this frame.
@(private = "file")
cell_take :: proc(h: ^Home, me: int) -> int {
	if c := h.tiles[me].cell; c >= 0 do return c
	best, oldest := -1, h.frame
	for owner, cell in h.owner {
		if owner < 0 {
			best = cell
			break
		}
		if s := h.tiles[owner].shown; s < oldest {
			best, oldest = cell, s
		}
	}
	if best < 0 do return -1
	if old := h.owner[best]; old >= 0 {
		h.tiles[old].state, h.tiles[old].cell = .Waiting, -1
	}
	h.owner[best] = me
	return best
}

@(private = "file")
tiles_clear :: proc(h: ^Home) {
	for t in h.tiles do delete(t.path)
	clear(&h.tiles)
	for &o in h.owner do o = -1
}

@(private = "file")
autosaves_clear :: proc(h: ^Home) {
	for e in h.autosaves {
		delete(e.session)
		delete(e.path)
		delete(e.scene)
	}
	clear(&h.autosaves)
}

@(private = "file")
loader_ask :: proc(app: ^App, path: string) {
	h := &app.home
	heap := runtime.heap_allocator()
	if h.loader == nil {
		l := new(Home_Loader, heap)
		l.todo.allocator, l.done.allocator = heap, heap
		h.loader = l
		l.thread = thread.create_and_start_with_data(l, loader_thread, context, .Low, name = "home pictures")
	}
	l := h.loader
	sync.lock(&l.lock)
	append(&l.todo, strings.clone(path, heap))
	sync.unlock(&l.lock)
	sync.sema_post(&l.wake)
}

@(private = "file")
loaded_free :: proc(d: Home_Loaded) {
	heap := runtime.heap_allocator()
	delete(d.path, heap)
	delete(d.pixels, heap)
}

@(private = "file")
loader_thread :: proc(data: rawptr) {
	l := cast(^Home_Loader)data
	// Temp memory of its own, and the heap for what it hands back: the context came
	// from the frame loop, whose temp allocator is that thread's.
	arena: runtime.Arena
	context.temp_allocator = runtime.arena_allocator(&arena)
	defer runtime.arena_destroy(&arena)
	context.allocator = runtime.heap_allocator()
	for {
		sync.sema_wait(&l.wake)
		for {
			sync.lock(&l.lock)
			if l.quit {
				sync.unlock(&l.lock)
				return
			}
			if len(l.todo) == 0 {
				sync.unlock(&l.lock)
				break
			}
			path := l.todo[0]
			ordered_remove(&l.todo, 0)
			sync.unlock(&l.lock)
			got := picture_load(path)
			sync.lock(&l.lock)
			append(&l.done, got)
			sync.unlock(&l.lock)
			runtime.arena_free_all(&arena)
		}
	}
}

// Reads the scene file at `path`'s start and decodes its picture, in context.allocator.
// A picture that is not one this app wrote (too big, not 8 bits a channel) is left out.
@(private = "file")
picture_load :: proc(path: string) -> (out: Home_Loaded) {
	out.path = path
	info, data, ok := scene_preview_read(path)
	defer delete(data)
	if !ok do return
	out.info, out.ok = info, true
	if data == nil do return
	img, err := png.load_from_bytes(data, {.alpha_add_if_missing})
	defer png.destroy(img)
	if err != nil || img == nil || img.channels != 4 || img.depth != 8 do return
	if img.width > render.PICTURE_PX || img.height > render.PICTURE_PX || img.width <= 0 || img.height <= 0 do return
	out.pixels = slice.clone(img.pixels.buf[:img.width * img.height * 4])
	out.w, out.h = img.width, img.height
	return
}
