// The interface kit: an immediate-mode UI drawn by our own renderer, the same with a
// mouse, a finger or a pen. Each frame the app fills an Input from its events, calls
// frame_begin, lays out containers and widgets (which return what the user did), and
// takes the triangles from frame_end. The kit keeps only UI state between frames (which
// widget is held, where each container was); everything it shows is handed in each
// frame. It imports neither SDL nor the renderer, so it runs headless in tests.
package ui

import "core:hash"

// A rectangle by its top-left corner and size. Layout works in points; the draw list
// in physical pixels (points times Input.pixel_density).
Rect :: struct {
	x, y, w, h: f32,
}

rect_contains :: proc(r: Rect, p: [2]f32) -> bool {
	return p.x >= r.x && p.y >= r.y && p.x < r.x + r.w && p.y < r.y + r.h
}

Button :: enum u8 {
	Left,
	Right,
	Middle,
}
Buttons :: bit_set[Button]

// What is pointing. A mouse is precise and has a wheel, so a press on a control is the
// control's at once; a finger or a pen pressing a control in a drag-scrolled area may
// mean to scroll it instead, which the first few points of movement decide
// (scroll_update, claim_drag).
Pointer_Kind :: enum u8 {
	Mouse,
	Finger,
	Pen,
}

// One frame of input, in window points, which the app fills from its events. A touch
// or a pen in contact counts as the left button.
Input :: struct {
	mouse:         [2]f32,
	mouse_valid:   bool, // the pointer is over the window
	down:          Buttons, // held at the end of the frame
	pressed:       Buttons, // went down during the frame, even if it came up again
	released:      Buttons, // came up during the frame
	wheel:         f32,
	shift:         bool,
	ctrl:          bool,
	alt:           bool,
	window:        [2]f32, // the window's size
	// The part of the window clear of system bars, camera cutouts and rounded corners,
	// which anchored containers keep inside; empty for the whole window.
	safe:          Rect,
	pixel_density: f32, // GPU pixels per point: 1 on most monitors, 2 or more on dense screens
	dt:            f32, // seconds since the last frame, which moves every animation on
	// Typing, for the text field that has the keys: the text typed this frame (UTF-8,
	// valid for the frame), Backspace presses, and Enter or Escape, which end it.
	text:          string,
	backspace:     int,
	text_end:      bool,
	pointer:       Pointer_Kind, // what pressed or moved the pointer last
	// The system took the pointer back (a palm was recognised, the app lost the touch):
	// what is held lets go this frame without a click.
	cancel:        bool,
}

Id :: u64

Direction :: enum u8 {
	Column,
	Row,
}

// Where a container sits along one axis of the window's safe area (Input.safe): from
// its start edge, centred, or from its end edge, `offset` points in.
Anchor :: enum u8 {
	Start,
	Center,
	End,
}

Background :: enum u8 {
	None,
	Panel, // a surface floating over the viewport: hairline border, rounded
	Raised, // a popover over the panels: lighter, a stronger hairline and a soft shadow
	Track, // the well behind segmented controls and tabs
}

// How a container lays out and looks.
Box :: struct {
	direction:  Direction,
	gap:        f32,
	padding:    f32,
	width:      f32, // fixed width, or 0 to fit the content
	height:     f32, // fixed height, or 0 to fit the content
	radius:     f32,
	background: Background,
	center:     bool, // centre children across the main axis (rows: vertically)
	clip:       bool, // hide what is laid out past its edges (a section opening)
	inert:      bool, // drawn but not answering the pointer (a popover closing)
	scroll:     f32, // how far its content is moved up (with clip, a scrolling panel)
	// A panel a finger or a pen scrolls by dragging anywhere in it, its controls included
	// (scroll_update): a control pressed in it waits to see which way the drag goes.
	drag_scroll: bool,
}

@(private)
Container :: struct {
	id:          Id,
	rect:        Rect, // where it is; the size is the content's once it ends
	box:         Box,
	cursor:      [2]f32,
	content:     [2]f32, // the far corner of the content so far
	cross:       f32, // the size across the main axis last frame, for centring
	index_mark:  int, // the draw list's index count at the start, where the background goes
	cmd_mark:    int,
	root:        Id, // the anchored container it is in, for hit tests
	first_child: bool,
	placed_size: [2]f32, // the size its parent made room for
	// For an anchored container: how far its widgets' hit areas reach past its edges,
	// so a press there is the widget's rather than the viewport's. Empty for none.
	hit:         Rect,
	clip_prev:   Rect, // the clip rectangle to put back when it ends
	// A highlight that slides to wherever a child asks (the chosen tab, the held brush),
	// drawn under the children.
	indicator:   Maybe(Indicator),
}

@(private)
Indicator :: struct {
	rect:   Rect,
	radius: f32,
	color:  Color,
}

// Where a container ended up, kept to the next frame: anchored ones are placed by their
// size, and the topmost one under the pointer takes the pointer.
@(private)
Placed :: struct {
	id:      Id,
	rect:    Rect,
	natural: [2]f32, // the size of its content, which a fixed size may cut short
	root:    bool, // an anchored container, which hit tests run against
	// Where it answers the pointer: its rectangle and, for an anchored container, every
	// hit area its widgets reach outside it (a 48 point target round a 36 point button).
	hit:     Rect,
}

// A short message at the bottom of the window that goes by itself.
Toast_Kind :: enum u8 {
	Info,
	Success,
	Warning,
	Error,
}

@(private)
Toast :: struct {
	text:       [120]u8,
	len:        int,
	action:     [24]u8, // the button at its right end ("Undo"), if any
	action_len: int,
	serial:     Id,
	kind:       Toast_Kind,
	born:       f64,
	life:       f32,
	id:         Id,
}

@(private)
TOASTS :: 4

// The root id of inert containers: no pointer ever lands on it.
@(private)
INERT_ROOT :: ~Id(0)

Context :: struct {
	input:          Input,
	theme:          Theme,
	fonts:          Fonts,
	draw:           Draw_List,
	active:         Id, // the widget the pointer pressed and still holds
	active_seen:    bool, // ...drawn this frame: a held widget that disappears lets go
	hot:            Id, // the widget under the pointer this frame
	// The anchored container under the pointer at the end of last frame; only its
	// widgets answer the pointer. 0 when the pointer is over the viewport.
	pointer_root:   Id,
	// A press that landed outside every container: it belongs to the viewport until all
	// buttons are up, so dragging over a panel never presses its buttons.
	viewport_drag:  bool,
	placed:         [dynamic]Placed, // this frame's containers
	placed_prev:    [dynamic]Placed, // last frame's
	stack:          [dynamic]Container,
	clip:           Rect, // physical pixels
	path:           [dynamic][2]f32, // scratch for shapes
	press_mouse:    [2]f32, // where the held widget was pressed
	press_value:    f32, // a held slider's value when it was pressed
	// The gesture arena of a press on a control in a drag-scrolled area: the area the
	// press is in (0 for none), whether the control won the drag (always, for a mouse or
	// outside such an area) and where the pointer was when it did.
	press_host:     Id,
	press_won:      bool,
	won_mouse:      [2]f32,
	// The drag-scrolled area a drag is scrolling now, which puts its scroll at
	// scroll_from less the pointer's height.
	scrolling:      Id,
	scroll_from:    f32,
	id_seed:        Id,

	time:           f64, // seconds of input dt so far: the clock every tween runs on
	tweens:         map[Id]Tween,
	scratch_ids:    [dynamic]Id,
	reduced_motion: bool, // every duration 0: things still change, without moving
	// A press that closed a popover over the viewport: nothing gets the pointer until
	// every button is up, so the click that dismisses never sculpts.
	swallow:        bool,
	// Tooltips: the widget under the pointer that has one, since when, and what to show.
	tip_id:         Id,
	tip_since:      f64,
	// Copied, as everything the kit keeps until frame_end is: a label may be temp memory,
	// which the app may free before the frame ends.
	tip_text:       [160]u8,
	tip_len:        int,
	tip_keys:       [40]u8, // its shortcut, shown dimmer beside it
	tip_keys_len:   int,
	tip_rect:       Rect,
	tip_shown:      Id,
	tip_last:       f64, // when a tooltip last showed: the next one comes without delay
	tip_pressed:    Id, // pressed since the pointer came onto it: no tooltip
	toasts:         [TOASTS]Toast,
	toast_count:    int,
	toast_serial:   Id,
	toast_bottom:   f32, // how far above the window's bottom edge toasts stack
	toast_acted:    Id, // the toast whose action was pressed, until toast_take_action
	// The popover open this frame, closed by a press outside it and its trigger, and
	// how the one being drawn now is shown (popovers do not nest).
	popup_open:       Id,
	popup_open_prev:  Id,
	popup_stack_mark: int,
	popup_anim:       f32,
	popup_origin:     [2]f32,
	popup_measuring:  bool,
	// The select whose list is open (or closing), what the list shows, and what it picked.
	select_open:      Id,
	select_id:        Id,
	select_anchor:    Rect,
	// Its options, copied (as the tooltip's text is): the bytes, and where each one ends.
	select_text:      [dynamic]u8,
	select_ends:      [dynamic]int,
	select_chosen:    int,
	select_fresh:     bool,
	select_pick_id:   Id,
	select_pick:      int,
	// Open sections, for section_end to fade their bodies.
	sections:         [8]struct {
		mark:  int,
		shown: f32,
	},
	section_depth:    int,
	last_rect:        Rect, // where the last widget went: what a popover opens beside
	// The text field that has the keys, and whether it was drawn this frame (one that is
	// no longer drawn lets them go).
	text_focus:       Id,
	text_seen:        bool,
}

init :: proc(ctx: ^Context, theme := THEME_DARK) {
	ctx.theme = theme
	fonts_init(&ctx.fonts)
	// Room for every animated property of a full interface, so frames do not allocate.
	reserve(&ctx.tweens, 512)
	reserve(&ctx.scratch_ids, 64)
	ctx.toast_bottom = 24
}

destroy :: proc(ctx: ^Context) {
	fonts_destroy(&ctx.fonts)
	draw_list_destroy(&ctx.draw)
	delete(ctx.placed)
	delete(ctx.placed_prev)
	delete(ctx.stack)
	delete(ctx.path)
	delete(ctx.tweens)
	delete(ctx.scratch_ids)
	delete(ctx.select_text)
	delete(ctx.select_ends)
	ctx^ = {}
}

// Starts a frame with this frame's input. Decides who owns the pointer: a container
// under it from last frame, a widget still held, or else the viewport.
frame_begin :: proc(ctx: ^Context, input: Input) {
	ctx.input = input
	if ctx.input.pixel_density <= 0 do ctx.input.pixel_density = 1
	// A frame that took long (a remesh) moves animations on by at most a tenth of a
	// second, so a panel does not skip from start to end mid-animation.
	before := ctx.time
	ctx.time += f64(clamp(input.dt, 0, 0.1))
	if int(ctx.time) != int(before) do tween_prune(ctx)
	draw_list_clear(&ctx.draw)
	ctx.draw.keep = 0
	clear(&ctx.stack)
	ctx.placed, ctx.placed_prev = ctx.placed_prev, ctx.placed
	clear(&ctx.placed)
	ctx.hot = 0
	ctx.active_seen = false
	ctx.text_seen = false
	d := ctx.input.pixel_density
	ctx.clip = {0, 0, input.window.x * d, input.window.y * d}

	ctx.pointer_root = 0
	if input.mouse_valid {
		// The last one drawn is on top.
		#reverse for p in ctx.placed_prev {
			if p.root && p.id != INERT_ROOT && rect_contains(p.hit, input.mouse) {
				ctx.pointer_root = p.id
				break
			}
		}
	}
	if input.pressed != {} && ctx.active == 0 && ctx.pointer_root == 0 do ctx.viewport_drag = true
	if ctx.viewport_drag || ctx.swallow do ctx.pointer_root = 0
	ctx.popup_open_prev = ctx.popup_open
	ctx.popup_open = 0
}

// Ends the frame and returns its triangles, ready to upload. The list stays valid until
// the next frame_begin.
frame_end :: proc(ctx: ^Context) -> ^Draw_List {
	assert(len(ctx.stack) == 0, "a container was begun and not ended")
	select_list_draw(ctx)
	toasts_draw(ctx)
	tooltip_draw(ctx)
	if ctx.active != 0 && (!ctx.active_seen || ctx.input.down == {} || ctx.input.cancel) do ctx.active = 0
	if ctx.scrolling != 0 && ctx.active != ctx.scrolling do ctx.scrolling = 0
	if !ctx.text_seen do ctx.text_focus = 0
	if ctx.input.down == {} {
		ctx.viewport_drag = false
		ctx.swallow = false
		ctx.press_host = 0
	}
	return &ctx.draw
}

// True while the UI has the pointer: it is over a container or holds a widget. The
// viewport ignores the pointer then.
wants_pointer :: proc(ctx: ^Context) -> bool {
	return ctx.swallow || (!ctx.viewport_drag && (ctx.pointer_root != 0 || ctx.active != 0))
}

// True while a text field has the keys: the app turns its text input (and a tablet's
// on-screen keyboard) on, and its shortcuts off.
typing :: proc(ctx: ^Context) -> bool {
	return ctx.text_focus != 0
}

// True while a drag that began on the viewport goes on, wherever the pointer is now.
viewport_dragging :: proc(ctx: ^Context) -> bool {
	return ctx.viewport_drag
}

// A widget's id: the label hashed into its container's, so the same label in two
// containers is two widgets. Text after "##" is part of the id but not shown.
id_of :: proc(ctx: ^Context, label: string) -> Id {
	seed := ctx.id_seed
	if n := len(ctx.stack); n > 0 do seed = ctx.stack[n - 1].id
	return hash.fnv64a(transmute([]byte)label, seed if seed != 0 else 0xcbf29ce484222325)
}

// Copies as much of `s` into `dst` as fits without cutting a UTF-8 sequence, and
// returns how many bytes that is.
@(private)
copy_text :: proc(dst: []u8, s: string) -> int {
	n := min(len(s), len(dst))
	if n < len(s) {
		for n > 0 && s[n] & 0xc0 == 0x80 do n -= 1
	}
	return copy(dst, s[:n])
}

// The part of a label that is shown: what comes before "##".
label_text :: proc(label: string) -> string {
	for i in 0 ..< len(label) - 1 {
		if label[i] == '#' && label[i + 1] == '#' do return label[:i]
	}
	return label
}

// Opens a container placed against the window: `x` and `y` say which edge or the
// middle, `offset` how far in. Close it with end.
begin_anchored :: proc(ctx: ^Context, name: string, x, y: Anchor, offset: [2]f32, box: Box) {
	id := id_of(ctx, name)
	size := prev_size(ctx, id, box)
	pos := anchored_pos(safe_area(ctx), x, y, offset, size)
	open(ctx, id, {pos.x, pos.y, size.x, size.y}, box, root = true)
}

// The top-left corner of something `size` points big placed against `area` as `x`, `y`
// and `offset` say (begin_anchored).
@(private)
anchored_pos :: proc(area: Rect, x, y: Anchor, offset: [2]f32, size: [2]f32) -> (pos: [2]f32) {
	origin := [2]f32{area.x, area.y}
	extent := [2]f32{area.w, area.h}
	for axis in 0 ..< 2 {
		a := x if axis == 0 else y
		switch a {
		case .Start:  pos[axis] = origin[axis] + offset[axis]
		case .Center: pos[axis] = origin[axis] + (extent[axis] - size[axis]) * 0.5 + offset[axis]
		case .End:    pos[axis] = origin[axis] + extent[axis] - size[axis] - offset[axis]
		}
	}
	return
}

// The part of the window anchored containers keep inside (Input.safe), in points.
safe_area :: proc(ctx: ^Context) -> Rect {
	area := ctx.input.safe
	if area.w <= 0 || area.h <= 0 do area = {0, 0, ctx.input.window.x, ctx.input.window.y}
	return area
}

// Opens a container at `pos` in the window (points), on top of what came before. Close
// it with end.
begin_at :: proc(ctx: ^Context, name: string, pos: [2]f32, box: Box) {
	id := id_of(ctx, name)
	size := prev_size(ctx, id, box)
	open(ctx, id, {pos.x, pos.y, size.x, size.y}, box, root = true)
}

// The size `name` (a container in the current one, or anchored) had last frame, and
// the size of its content; zero the first frame.
prev_layout :: proc(ctx: ^Context, name: string) -> (size, natural: [2]f32) {
	id := id_of(ctx, name)
	for p in ctx.placed_prev {
		if p.id == id do return {p.rect.w, p.rect.h}, p.natural
	}
	return
}

// Where `name` (a container in the current one, or anchored) was last frame; empty the
// first frame.
prev_rect :: proc(ctx: ^Context, name: string) -> Rect {
	id := id_of(ctx, name)
	for p in ctx.placed_prev {
		if p.id == id do return p.rect
	}
	return {}
}

// Opens a container inside the current one, laid out like a widget. Close it with end.
begin :: proc(ctx: ^Context, name: string, box: Box) {
	id := id_of(ctx, name)
	size := prev_size(ctx, id, box)
	r := place(ctx, size)
	open(ctx, id, r, box, root = false)
}

// Closes the innermost container: its size becomes its content's (or the fixed one),
// its background goes under its content, and its parent moves past it.
end :: proc(ctx: ^Context) {
	c := pop(&ctx.stack)
	pad := c.box.padding
	natural := [2]f32{max(c.content.x - c.rect.x + pad, 2 * pad), max(c.content.y - c.rect.y + pad + c.box.scroll, 2 * pad)}
	w := c.box.width if c.box.width > 0 else natural.x
	h := c.box.height if c.box.height > 0 else natural.y
	c.rect.w, c.rect.h = max(w, 2 * pad), max(h, 2 * pad)
	if c.box.clip {
		ctx.clip = c.clip_prev
		draw_set_state(&ctx.draw, .Atlas, 0, ctx.clip)
	}
	// The indicator, then the background, each moved under what is already there, so the
	// background ends lowest, the indicator over it and the children on top.
	if ind, ok := c.indicator.?; ok {
		draw_set_state(&ctx.draw, .Atlas, 0, ctx.clip)
		from := len(ctx.draw.indices)
		r := ind.rect
		dur := ctx.theme.indicator_time
		x := tween(ctx, salt(c.id, 1), r.x - c.rect.x, dur, .Out_Cubic)
		y := tween(ctx, salt(c.id, 2), r.y - c.rect.y, dur, .Out_Cubic)
		iw := tween(ctx, salt(c.id, 3), r.w, dur, .Out_Cubic)
		ih := tween(ctx, salt(c.id, 4), r.h, dur, .Out_Cubic)
		fill_rect(ctx, {c.rect.x + x, c.rect.y + y, iw, ih}, ind.radius, ind.color)
		draw_move_under(&ctx.draw, c.index_mark, c.cmd_mark, from)
	}
	if c.box.background != .None {
		draw_set_state(&ctx.draw, .Atlas, 0, ctx.clip)
		from := len(ctx.draw.indices)
		t := ctx.theme
		switch c.box.background {
		case .None:
		case .Panel:
			fill_rect(ctx, c.rect, c.box.radius, t.surface)
			stroke_rect(ctx, c.rect, c.box.radius, t.border, 1)
		case .Raised:
			shadow_rect(ctx, c.rect, c.box.radius, t.shadow)
			fill_rect(ctx, c.rect, c.box.radius, t.surface_raised)
			stroke_rect(ctx, c.rect, c.box.radius, t.border_strong, 1)
		case .Track:
			fill_rect(ctx, c.rect, c.box.radius, t.fill)
		}
		draw_move_under(&ctx.draw, c.index_mark, c.cmd_mark, from)
	}
	hit := c.rect
	if c.root == c.id && c.hit.w > 0 && c.hit.h > 0 do hit = rect_union(hit, c.hit)
	append(&ctx.placed, Placed{c.id, c.rect, natural, c.root == c.id, hit})
	// The parent placed it at last frame's size; move the parent on by the difference.
	if n := len(ctx.stack); n > 0 && c.root != c.id {
		p := &ctx.stack[n - 1]
		axis := 0 if p.box.direction == .Row else 1
		size := [2]f32{c.rect.w, c.rect.h}
		p.cursor[axis] += size[axis] - c.placed_size[axis]
		p.content = {max(p.content.x, c.rect.x + size.x), max(p.content.y, c.rect.y + size.y)}
	}
}

// Reserves room for a widget of `size` points in the current container and returns
// where it goes.
place :: proc(ctx: ^Context, size: [2]f32) -> Rect {
	n := len(ctx.stack)
	if n == 0 do return {0, 0, size.x, size.y}
	c := &ctx.stack[n - 1]
	pos := advance(c, size)
	defer ctx.last_rect = {pos.x, pos.y, size.x, size.y}
	if c.box.center {
		inner := c.cross - 2 * c.box.padding
		if c.box.direction == .Row {
			pos.y += max((inner - size.y) * 0.5, 0)
		} else {
			pos.x += max((inner - size.x) * 0.5, 0)
		}
	}
	return {pos.x, pos.y, size.x, size.y}
}

// The width a widget can take across a column: the container's fixed width less its
// padding, or 0 when it fits its content.
fill_width :: proc(ctx: ^Context) -> f32 {
	n := len(ctx.stack)
	if n == 0 do return 0
	c := ctx.stack[n - 1]
	return max(c.box.width - 2 * c.box.padding, 0) if c.box.width > 0 else 0
}

// Adds empty space along the current container's main axis.
spacer :: proc(ctx: ^Context, amount: f32) {
	n := len(ctx.stack)
	if n == 0 do return
	c := &ctx.stack[n - 1]
	if c.box.direction == .Row {
		c.cursor.x += amount
	} else {
		c.cursor.y += amount
	}
}

@(private)
open :: proc(ctx: ^Context, id: Id, r: Rect, box: Box, root: bool) {
	// The background goes in under the content when the container ends; the draw
	// command here must keep its state until then.
	draw_set_state(&ctx.draw, .Atlas, 0, ctx.clip)
	ctx.draw.keep = len(ctx.draw.cmds)
	parent_root: Id = id
	if !root && len(ctx.stack) > 0 do parent_root = ctx.stack[len(ctx.stack) - 1].root
	if box.inert do parent_root = INERT_ROOT
	c := Container {
		id          = id,
		rect        = r,
		box         = box,
		cursor      = {r.x + box.padding, r.y + box.padding - box.scroll},
		content     = {r.x + box.padding, r.y + box.padding - box.scroll},
		cross       = r.h if box.direction == .Row else r.w,
		index_mark  = len(ctx.draw.indices),
		cmd_mark    = len(ctx.draw.cmds) - 1,
		root        = parent_root,
		first_child = true,
		placed_size = {r.w, r.h},
		clip_prev   = ctx.clip,
	}
	if box.clip {
		d := px(ctx)
		ctx.clip = rect_intersect(ctx.clip, {r.x * d, r.y * d, r.w * d, r.h * d})
		draw_set_state(&ctx.draw, .Atlas, 0, ctx.clip)
		ctx.draw.keep = len(ctx.draw.cmds)
		c.cmd_mark = len(ctx.draw.cmds) - 1
		c.index_mark = len(ctx.draw.indices)
	}
	append(&ctx.stack, c)
}

// Asks the innermost container to slide its indicator to `r`, under its children.
indicator :: proc(ctx: ^Context, r: Rect, radius: f32, color: Color) {
	if n := len(ctx.stack); n > 0 do ctx.stack[n - 1].indicator = Indicator{r, radius, color}
}

// The smallest rectangle holding both.
rect_union :: proc(a, b: Rect) -> Rect {
	x0, y0 := min(a.x, b.x), min(a.y, b.y)
	x1, y1 := max(a.x + a.w, b.x + b.w), max(a.y + a.h, b.y + b.h)
	return {x0, y0, x1 - x0, y1 - y0}
}

rect_intersect :: proc(a, b: Rect) -> Rect {
	x0, y0 := max(a.x, b.x), max(a.y, b.y)
	x1, y1 := min(a.x + a.w, b.x + b.w), min(a.y + a.h, b.y + b.h)
	return {x0, y0, max(x1 - x0, 0), max(y1 - y0, 0)}
}

// Moves the container's cursor past a child of `size` and returns where the child goes.
@(private)
advance :: proc(c: ^Container, size: [2]f32) -> [2]f32 {
	axis := 0 if c.box.direction == .Row else 1
	if !c.first_child do c.cursor[axis] += c.box.gap
	c.first_child = false
	pos := c.cursor
	c.content = {max(c.content.x, pos.x + size.x), max(c.content.y, pos.y + size.y)}
	c.cursor[axis] += size[axis]
	return pos
}

// The size a container had last frame (or its fixed size), which places it this frame.
@(private)
prev_size :: proc(ctx: ^Context, id: Id, box: Box) -> [2]f32 {
	size: [2]f32
	for p in ctx.placed_prev {
		if p.id == id {
			size = {p.rect.w, p.rect.h}
			break
		}
	}
	if box.width > 0 do size.x = box.width
	if box.height > 0 do size.y = box.height
	return size
}

// How a widget answers the pointer this frame. A press on it holds it; letting go over
// it is a click. Only widgets in the container that has the pointer answer.
@(private)
interact :: proc(ctx: ^Context, id: Id, r: Rect) -> (hovered, held, clicked, pressed: bool) {
	n := len(ctx.stack)
	root: Id = ctx.stack[n - 1].root if n > 0 else 0
	in_input := ctx.input
	d := px(ctx)
	inside_clip := rect_contains(ctx.clip, in_input.mouse * d)
	over := in_input.mouse_valid && !ctx.viewport_drag && !ctx.swallow && root == ctx.pointer_root && rect_contains(r, in_input.mouse) && inside_clip
	hit_extend(ctx, r)
	// Hit areas may overlap a little (each is at least a touch target, larger than what
	// is drawn); the first widget laid out under the pointer takes it.
	if over && (ctx.active == 0 || ctx.active == id) && (ctx.hot == 0 || ctx.hot == id) do ctx.hot = id
	if ctx.hot == id && .Left in in_input.pressed && ctx.active == 0 {
		ctx.active = id
		ctx.press_mouse = in_input.mouse
		pressed = true
		// The innermost drag-scrolled area the press is in decides with the control which
		// of them the drag is for; a mouse's press is the control's at once.
		ctx.press_host = 0
		#reverse for c in ctx.stack {
			if c.box.drag_scroll {
				ctx.press_host = c.id
				break
			}
		}
		ctx.press_won = in_input.pointer == .Mouse || ctx.press_host == 0
		ctx.won_mouse = in_input.mouse
	}
	if ctx.active == id {
		ctx.active_seen = true
		held = .Left in in_input.down && !in_input.cancel
		if .Left in in_input.released || in_input.cancel {
			// A cancelled press lets go without doing what it would have done.
			clicked = over && !in_input.cancel
			held = false
		}
	}
	hovered = ctx.hot == id
	return
}

// Grows the anchored container being laid out to hold the hit area `r`, as far as the
// current clip shows it: a widget clipped out of a scrolling panel takes no press.
@(private)
hit_extend :: proc(ctx: ^Context, r: Rect) {
	d := px(ctx)
	clip := Rect{ctx.clip.x / d, ctx.clip.y / d, ctx.clip.w / d, ctx.clip.h / d}
	shown := rect_intersect(r, clip)
	if shown.w <= 0 || shown.h <= 0 do return
	#reverse for &c in ctx.stack {
		if c.root == INERT_ROOT do return
		if c.root != c.id do continue
		c.hit = shown if c.hit.w <= 0 || c.hit.h <= 0 else rect_union(c.hit, shown)
		return
	}
}

// Whether the held widget may act on how the pointer moved: at once for a mouse or
// outside a drag-scrolled area, and for a finger or a pen in one only once the widget
// has won the drag, so a drag meant to scroll the panel never moves a slider on its way.
// It wins when the pointer has gone further than the theme's slop along `axis` (0 across,
// 1 down) and at least as far along it as along the other, as Flutter's horizontal drag
// recognizer beats the scroll view's vertical one. A widget that takes a drag any way
// it goes (a graph with handles) claims it on the press with `axis` -1.
claim_drag :: proc(ctx: ^Context, axis: int) -> bool {
	if ctx.press_won do return true
	d := ctx.input.mouse - ctx.press_mouse
	if axis < 0 {
		ctx.press_won = true
	} else if along := abs(d[axis]); along > ctx.theme.slop && along >= abs(d[1 - axis]) {
		ctx.press_won = true
	}
	if ctx.press_won do ctx.won_mouse = ctx.input.mouse
	return ctx.press_won
}

// Scrolls a drag-scrolled area. Call it before laying out the area's container (with
// Box.drag_scroll and clip set), with `id` the container's id, `rect` where it was last
// frame, the scroll the app keeps for it and the most it can scroll. The wheel over it
// scrolls it. A finger or a pen pressed on a control in it scrolls it once the drag has
// gone further up or down than the slop and than sideways, unless the control won the
// drag first (claim_drag): the control then lets go without a click, as a scroll view
// takes a touch from a button it was going to press. Returns true while a drag is
// scrolling it, when the scroll should follow the pointer without easing.
scroll_update :: proc(ctx: ^Context, id: Id, rect: Rect, scroll: ^f32, limit: f32) -> (dragging: bool) {
	in_ := ctx.input
	if in_.wheel != 0 && in_.mouse_valid && rect_contains(rect, in_.mouse) do scroll^ -= in_.wheel * 64
	if ctx.scrolling == id {
		if .Left in in_.down && !in_.cancel {
			scroll^ = ctx.scroll_from - in_.mouse.y
			ctx.active, ctx.active_seen = id, true
		} else {
			ctx.scrolling = 0
		}
	} else if ctx.press_host == id && ctx.active != 0 && ctx.active != id && !ctx.press_won && limit > 0 && .Left in in_.down {
		d := in_.mouse - ctx.press_mouse
		if abs(d.y) > ctx.theme.slop && abs(d.y) > abs(d.x) {
			// From where the pointer is now, so the content does not jump by the slop.
			ctx.scrolling, ctx.scroll_from = id, scroll^ + in_.mouse.y
			ctx.active, ctx.active_seen = id, true
		}
	}
	scroll^ = clamp(scroll^, 0, limit)
	return ctx.scrolling == id
}

// Starts scrolling the area `id` at once when a press in it landed where no control
// took it. Call it after the area's container ended, with the same scroll and limit; for
// an area inside another container, `root` is the anchored container it is in.
scroll_take :: proc(ctx: ^Context, id: Id, scroll: f32, limit: f32, root: Id = 0) {
	root := root if root != 0 else id
	if .Left not_in ctx.input.pressed || ctx.active != 0 || ctx.pointer_root != root || limit <= 0 || ctx.viewport_drag || ctx.swallow do return
	inside := false
	#reverse for p in ctx.placed {
		if p.id == id {
			inside = rect_contains(p.rect, ctx.input.mouse)
			break
		}
	}
	if inside {
		ctx.scrolling, ctx.scroll_from = id, scroll + ctx.input.mouse.y
		ctx.active, ctx.active_seen = id, true
	}
}

// Pixels per point, for drawing.
@(private)
px :: #force_inline proc(ctx: ^Context) -> f32 {return ctx.input.pixel_density}

@(private)
to_px :: #force_inline proc(ctx: ^Context, r: Rect) -> Rect {
	d := px(ctx)
	return {r.x * d, r.y * d, r.w * d, r.h * d}
}

// Shapes, in points.

fill_rect :: proc(ctx: ^Context, r: Rect, radius: f32, color: Color) {
	clear(&ctx.path)
	d := px(ctx)
	rounded_rect_path(&ctx.path, to_px(ctx, r), radius * d)
	draw_set_state(&ctx.draw, .Atlas, 0, ctx.clip)
	draw_convex(&ctx.draw, ctx.path[:], color)
}

// The outline of a rectangle, `width` points thick and drawn inside its edge.
stroke_rect :: proc(ctx: ^Context, r: Rect, radius: f32, color: Color, width: f32) {
	clear(&ctx.path)
	d := px(ctx)
	inset := width * 0.5
	rounded_rect_path(&ctx.path, to_px(ctx, {r.x + inset, r.y + inset, r.w - width, r.h - width}), max(radius - inset, 0) * d)
	draw_set_state(&ctx.draw, .Atlas, 0, ctx.clip)
	draw_polyline(&ctx.draw, ctx.path[:], color, width * d, closed = true)
}

fill_circle :: proc(ctx: ^Context, center: [2]f32, radius: f32, color: Color) {
	clear(&ctx.path)
	d := px(ctx)
	circle_path(&ctx.path, center * d, radius * d)
	draw_set_state(&ctx.draw, .Atlas, 0, ctx.clip)
	draw_convex(&ctx.draw, ctx.path[:], color)
}

// A circle's outline, `width` points thick.
stroke_circle :: proc(ctx: ^Context, center: [2]f32, radius: f32, color: Color, width: f32) {
	clear(&ctx.path)
	d := px(ctx)
	circle_path(&ctx.path, center * d, radius * d)
	draw_set_state(&ctx.draw, .Atlas, 0, ctx.clip)
	draw_polyline(&ctx.draw, ctx.path[:], color, width * d, closed = true)
}

// A straight line from `a` to `b`, `width` points thick.
line :: proc(ctx: ^Context, a, b: [2]f32, color: Color, width: f32) {
	d := px(ctx)
	ends := [2][2]f32{a * d, b * d}
	draw_set_state(&ctx.draw, .Atlas, 0, ctx.clip)
	draw_polyline(&ctx.draw, ends[:], color, width * d)
}

// A line through `points`, `width` points thick; `closed` joins the last point back to
// the first.
polyline :: proc(ctx: ^Context, points: [][2]f32, color: Color, width: f32, closed := false) {
	clear(&ctx.path)
	d := px(ctx)
	for p in points do append(&ctx.path, p * d)
	draw_set_state(&ctx.draw, .Atlas, 0, ctx.clip)
	draw_polyline(&ctx.draw, ctx.path[:], color, width * d, closed)
}

// A filled convex polygon through `points`, either way round.
fill_convex :: proc(ctx: ^Context, points: [][2]f32, color: Color) {
	clear(&ctx.path)
	d := px(ctx)
	for p in points do append(&ctx.path, p * d)
	draw_set_state(&ctx.draw, .Atlas, 0, ctx.clip)
	draw_convex(&ctx.draw, ctx.path[:], color)
}

// A place in the draw order kept for drawing done later: what is drawn between
// layer_begin and layer_end goes under everything drawn after layer_mark took it. The
// app draws the viewport's overlay (the brush circle, the gizmo) once its tools have run,
// after the panels are laid out, and puts it under them this way.
Layer :: struct {
	index: int, // the draw list's index count when it was taken
	cmd:   int, // the command that ends there, kept for the layer
}

// Takes a layer over everything drawn so far. It draws with the whole window as its clip.
layer_mark :: proc(ctx: ^Context) -> Layer {
	draw_set_state(&ctx.draw, .Atlas, 0, full_clip(ctx))
	ctx.draw.keep = len(ctx.draw.cmds)
	return {len(ctx.draw.indices), len(ctx.draw.cmds) - 1}
}

// Starts drawing into a layer, with the whole window as the clip; returns what
// layer_end needs.
layer_begin :: proc(ctx: ^Context) -> (from: int) {
	ctx.clip = full_clip(ctx)
	draw_set_state(&ctx.draw, .Atlas, 0, ctx.clip)
	return len(ctx.draw.indices)
}

// Moves what was drawn since layer_begin returned `from` down into `layer`. Nothing in
// between may change the clip, so it is all in the last command.
layer_end :: proc(ctx: ^Context, layer: Layer, from: int) {
	last := ctx.draw.cmds[len(ctx.draw.cmds) - 1]
	assert(last.texture == .Atlas && last.clip == full_clip(ctx) && int(last.first_index) <= from, "a layer's drawing changed the clip")
	draw_move_under(&ctx.draw, layer.index, layer.cmd, from)
}

// A soft shadow under a rounded rectangle: three widening rings, fainter each time,
// dropped a little, which reads as a popover lifted off the panel below.
shadow_rect :: proc(ctx: ^Context, r: Rect, radius: f32, color: Color) {
	for k in 0 ..< 4 {
		grow := f32(k) * 3 + 1
		c := color
		c.a = u8(f32(color.a) * (0.32 - f32(k) * 0.07))
		fill_rect(ctx, {r.x - grow, r.y - grow + 6, r.w + 2 * grow, r.h + 2 * grow}, radius + grow, c)
	}
}

// A soft shadow under a circle: rings fading out, cheap and good enough at knob sizes.
shadow_circle :: proc(ctx: ^Context, center: [2]f32, radius: f32, color: Color) {
	for k in 0 ..< 3 {
		c := color
		c.a = u8(f32(color.a) * (0.5 - f32(k) * 0.15))
		fill_circle(ctx, center + {0, 1}, radius + f32(k) * 1.2, c)
	}
}

// An image the app registered (such as the 3D viewport), stretched over `r`.
image :: proc(ctx: ^Context, r: Rect, image_id: u64) {
	draw_set_state(&ctx.draw, .Image, image_id, ctx.clip)
	draw_quad(&ctx.draw, to_px(ctx, r), {0, 0}, {1, 1}, {255, 255, 255, 255})
}
