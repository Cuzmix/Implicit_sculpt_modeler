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
	pixel_density: f32, // GPU pixels per point: 1 on most monitors, 2 or more on dense screens
}

Color :: [4]u8

// The look, as tokens: the Figma file's "Sculpt colours" and the sizes its components
// use, in points.
Theme :: struct {
	canvas:          Color,
	panel:           Color,
	panel_border:    Color,
	control:         Color, // the track behind a segmented control
	segment:         Color, // the chosen segment
	track:           Color, // the empty part of a slider or an off switch
	text:            Color,
	text_secondary:  Color,
	text_tertiary:   Color,
	accent:          Color,
	on_accent:       Color,
	positive:        Color,
	knob:            Color,
	shadow:          Color,
	panel_radius:    f32,
	control_radius:  f32,
	text_size:       f32,
	caption_size:    f32,
	title_size:      f32,
	target:          f32, // the smallest touch target: 48, the stores' 44 pt and 48 dp both met
}

THEME_DARK :: Theme {
	canvas         = {0x11, 0x12, 0x14, 0xff},
	panel          = {0x24, 0x25, 0x29, 0xdb},
	panel_border   = {0xff, 0xff, 0xff, 0x14},
	control        = {0xff, 0xff, 0xff, 0x14},
	segment        = {0x5a, 0x5b, 0x61, 0xff},
	track          = {0xff, 0xff, 0xff, 0x24},
	text           = {0xf2, 0xf2, 0xf4, 0xff},
	text_secondary = {0xc7, 0xc7, 0xcc, 0xff},
	text_tertiary  = {0xa1, 0xa1, 0xa8, 0xff},
	accent         = {0x4c, 0x8d, 0xff, 0xff},
	on_accent      = {0xff, 0xff, 0xff, 0xff},
	positive       = {0x34, 0xc7, 0x59, 0xff},
	knob           = {0xff, 0xff, 0xff, 0xff},
	shadow         = {0x00, 0x00, 0x00, 0x66},
	panel_radius   = 16,
	control_radius = 12,
	text_size      = 15,
	caption_size   = 12,
	title_size     = 17,
	target         = 48,
}

Id :: u64

Direction :: enum u8 {
	Column,
	Row,
}

// Where a container sits along one axis of the window: from its start edge, centred,
// or from its end edge, `offset` points in.
Anchor :: enum u8 {
	Start,
	Center,
	End,
}

Background :: enum u8 {
	None,
	Panel, // the frosted card: panel colour, a hairline border, rounded
	Track, // the darker well behind segmented controls
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
}

// Where a container ended up, kept to the next frame: anchored ones are placed by their
// size, and the topmost one under the pointer takes the pointer.
@(private)
Placed :: struct {
	id:   Id,
	rect: Rect,
	root: bool, // an anchored container, which hit tests run against
}

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
	id_seed:        Id,
}

init :: proc(ctx: ^Context, theme := THEME_DARK) {
	ctx.theme = theme
	fonts_init(&ctx.fonts)
}

destroy :: proc(ctx: ^Context) {
	fonts_destroy(&ctx.fonts)
	draw_list_destroy(&ctx.draw)
	delete(ctx.placed)
	delete(ctx.placed_prev)
	delete(ctx.stack)
	delete(ctx.path)
	ctx^ = {}
}

// Starts a frame with this frame's input. Decides who owns the pointer: a container
// under it from last frame, a widget still held, or else the viewport.
frame_begin :: proc(ctx: ^Context, input: Input) {
	ctx.input = input
	if ctx.input.pixel_density <= 0 do ctx.input.pixel_density = 1
	draw_list_clear(&ctx.draw)
	ctx.draw.keep = 0
	clear(&ctx.stack)
	ctx.placed, ctx.placed_prev = ctx.placed_prev, ctx.placed
	clear(&ctx.placed)
	ctx.hot = 0
	ctx.active_seen = false
	d := ctx.input.pixel_density
	ctx.clip = {0, 0, input.window.x * d, input.window.y * d}

	ctx.pointer_root = 0
	if input.mouse_valid {
		// The last one drawn is on top.
		#reverse for p in ctx.placed_prev {
			if p.root && rect_contains(p.rect, input.mouse) {
				ctx.pointer_root = p.id
				break
			}
		}
	}
	if input.pressed != {} && ctx.active == 0 && ctx.pointer_root == 0 do ctx.viewport_drag = true
	if ctx.viewport_drag do ctx.pointer_root = 0
}

// Ends the frame and returns its triangles, ready to upload. The list stays valid until
// the next frame_begin.
frame_end :: proc(ctx: ^Context) -> ^Draw_List {
	assert(len(ctx.stack) == 0, "a container was begun and not ended")
	if ctx.active != 0 && (!ctx.active_seen || ctx.input.down == {}) do ctx.active = 0
	if ctx.input.down == {} do ctx.viewport_drag = false
	return &ctx.draw
}

// True while the UI has the pointer: it is over a container or holds a widget. The
// viewport ignores the pointer then.
wants_pointer :: proc(ctx: ^Context) -> bool {
	return !ctx.viewport_drag && (ctx.pointer_root != 0 || ctx.active != 0)
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
	pos: [2]f32
	window := ctx.input.window
	for axis in 0 ..< 2 {
		a := x if axis == 0 else y
		switch a {
		case .Start:  pos[axis] = offset[axis]
		case .Center: pos[axis] = (window[axis] - size[axis]) * 0.5 + offset[axis]
		case .End:    pos[axis] = window[axis] - size[axis] - offset[axis]
		}
	}
	open(ctx, id, {pos.x, pos.y, size.x, size.y}, box, root = true)
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
	w := c.box.width if c.box.width > 0 else c.content.x - c.rect.x + pad
	h := c.box.height if c.box.height > 0 else c.content.y - c.rect.y + pad
	c.rect.w, c.rect.h = max(w, 2 * pad), max(h, 2 * pad)
	if c.box.background != .None {
		draw_set_state(&ctx.draw, .Atlas, 0, ctx.clip)
		from := len(ctx.draw.indices)
		t := ctx.theme
		switch c.box.background {
		case .None:
		case .Panel:
			fill_rect(ctx, c.rect, c.box.radius, t.panel)
			stroke_rect(ctx, c.rect, c.box.radius, t.panel_border, 1)
		case .Track:
			fill_rect(ctx, c.rect, c.box.radius, t.control)
		}
		draw_move_under(&ctx.draw, c.index_mark, c.cmd_mark, from)
	}
	append(&ctx.placed, Placed{c.id, c.rect, c.root == c.id})
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
	c := Container {
		id          = id,
		rect        = r,
		box         = box,
		cursor      = {r.x + box.padding, r.y + box.padding},
		content     = {r.x + box.padding, r.y + box.padding},
		cross       = r.h if box.direction == .Row else r.w,
		index_mark  = len(ctx.draw.indices),
		cmd_mark    = len(ctx.draw.cmds) - 1,
		root        = parent_root,
		first_child = true,
		placed_size = {r.w, r.h},
	}
	append(&ctx.stack, c)
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
	over := in_input.mouse_valid && !ctx.viewport_drag && root == ctx.pointer_root && rect_contains(r, in_input.mouse)
	if over && (ctx.active == 0 || ctx.active == id) do ctx.hot = id
	if over && .Left in in_input.pressed && ctx.active == 0 {
		ctx.active = id
		ctx.press_mouse = in_input.mouse
		pressed = true
	}
	if ctx.active == id {
		ctx.active_seen = true
		held = .Left in in_input.down
		if .Left in in_input.released {
			clicked = over
			held = false
		}
	}
	hovered = ctx.hot == id
	return
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
