// The interface kit: an immediate-mode UI drawn by our own renderer, the same with a
// mouse, a finger or a pen. Each frame the app fills an Input from its events, calls
// frame_begin, lays out containers and widgets (which return what the user did), and
// takes the triangles from frame_end. The kit keeps only UI state between frames (which
// widget is held, where each container was); everything it shows is handed in each
// frame. It imports neither SDL nor the renderer, so it runs headless in tests.
package ui

import "core:hash"
import "core:math"
import "core:math/linalg"

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
	// How far the pen turned about its own length this frame, in degrees, clockwise seen
	// from its top; zero without a pen. A slider the pen hovers on follows it, once it
	// turned there on purpose (hover_roll).
	roll:          f32,
	// The system took the pointer back (a palm was recognised, the app lost the touch):
	// what is held lets go this frame without a click.
	cancel:        bool,
	// A pointer resting on a control shows no tooltip, as a hovering pen does when the
	// app's settings say so; a long press still shows one.
	no_hover_tips: bool,
}

Id :: u64

// A long press on the held widget (long_due): what it did, if anything yet.
Long_Press :: struct {
	id:      Id, // the widget pressed
	fired:   Long_Fired,
	travel:  f32, // the furthest the pointer went from the press, points
	claimed: Id, // a widget that has a secondary action this frame (secondary)
	// Held still for the theme's long_press, so a move from here on lifts it (lift); and
	// lifted already, so it lifts once.
	steady:  bool,
	lifted:  bool,
	// The text and keys of the last tooltip a long press showed, for the app's exit stats.
	shown:   [64]u8,
	shown_len: int,
	shown_keys: [80]u8,
	shown_keys_len: int,
}

Long_Fired :: enum u8 {
	None,
	Action, // the widget's secondary action ran
	Tip, // it has none: its tooltip showed
	Off, // the press moved a value: no long press this time (long_cancel)
}

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
	Band, // the window's frame: flat, a hairline along its bottom (the top bar)
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
	// Its children may overlap, or its content outgrow its fixed size, by design (a stack
	// of cards drawn over each other), so neither is counted as a layout fault.
	overlap:     bool,
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
	vertex_mark: int, // the draw list's vertex count at the start, for mirror_slide
	// A highlight that slides to wherever a child asks (the chosen tab, the held brush),
	// drawn under the children.
	indicator:   Maybe(Indicator),
	// How far along the main axis its children reach so far, and where the first that
	// started inside an earlier one went (a layout fault, layout_fault), if any.
	reach:       f32,
	overlapped:  Rect,
}

@(private)
Indicator :: struct {
	rect:   Rect,
	radius: f32,
	color:  Color,
	line:   Color, // a hairline round it, when not clear
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
	// Layout faults (Overlap) found this frame so far, and last frame's whole count and
	// the first one's place, for the app's exit stats and the touch scenarios.
	overlaps:       int,
	overlaps_prev:  int,
	overlap_first:  Rect,
	overlap_prev:   Rect,
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
	// The paged row a sideways drag is turning now (swipe_update), and where the press
	// that started it was across.
	swiping:        Id,
	swipe_from:     f32,
	id_seed:        Id,

	time:           f64, // seconds of input dt so far: the clock every tween runs on
	tweens:         map[Id]Tween,
	scratch_ids:    [dynamic]Id,
	// How much the interface moves (Settings > Interface > Motion): Full, Reduced (fades
	// stay, moves and scales go) or Off (every duration 0: things still change, without
	// moving), and the kinds of motion turned off one by one (Motion_Class numbers).
	motion:         Motion_Level,
	motion_off:     bit_set[0 ..< 32; u32],
	// The left-handed layout: everything anchored to one side of the window goes to the
	// other, and popovers open the other way, so the tools a hand reaches for are under it.
	// A window the user moved stays where it was put.
	mirror:         bool,
	// While the hand changes: how much of the way back to its mirror image each outermost
	// container is drawn (1 there, 0 where the layout puts it), so the bars and panels slide
	// across rather than jump; with motion Reduced they fade in where they go instead. Only
	// the drawing moves: presses land where the layout puts them.
	mirror_slide:   f32,
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
	tip_keys:       [80]u8, // its shortcut and gesture, shown dimmer beside it
	tip_keys_len:   int,
	// The tooltip the last frame drew, for scripted checks (tip_showing).
	tip_drawn:      [160]u8,
	tip_drawn_len:  int,
	// What the pen's roll just did, beside the pen (roll_hint), and when it last said so.
	roll_hint:      [64]u8,
	roll_hint_len:  int,
	roll_hint_at:   f64,
	tip_rect:       Rect,
	tip_shown:      Id,
	tip_last:       f64, // when a tooltip last showed: the next one comes without delay
	tip_pressed:    Id, // pressed since the pointer came onto it: no tooltip
	labels:         Labels, // every control named at once (labels.odin)
	names:          Names, // every control and where it shows, for scripted input by name (names.odin)
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
	// A list taller than the room it has scrolls: how far, and which select's opening put
	// its chosen option in view.
	select_scroll:    f32,
	select_scrolled:  Id,
	// While set, a paragraph in the default colour shows as a hint: its first sentence on
	// one line and a ? that opens the whole text in a popover (hint_draw). The app sets it
	// round its cards and Settings unless the person asked for every setting explained.
	hints:            bool,
	// The hint whose popover is open (or closing), its line, and its whole text, copied.
	hint_open:        Id,
	hint_id:          Id,
	hint_anchor:      Rect,
	hint_text:        [dynamic]u8,
	hint_fresh:       bool,
	// Whether a widget was clicked this frame, and where: what the app shows beside the
	// control a click acted on (the key binding popover).
	clicked_now:      bool,
	clicked_rect:     Rect,
	// Open sections, for section_end to fade their bodies.
	sections:         [8]struct {
		mark:  int,
		shown: f32,
	},
	section_depth:    int,
	last_rect:        Rect, // where the last widget went: what a popover opens beside
	// How many controls (buttons, sliders, switches, tabs, fields...) were laid out since
	// init, disabled ones included: what tests count to keep a section's basic part short.
	controls:         int,
	// A control to find this frame (mark_next): the count `controls` reaches as it is laid
	// out, and where place put it once it has been.
	marked:           struct {
		control: int,
		rect:    Rect,
		found:   bool,
	},
	// The last widget laid out, if it took the pointer (interact): what secondary acts on.
	// A widget that returns early, a disabled one, leaves it 0.
	last_id:          Id,
	press_at:         f64, // ctx.time when the held widget was pressed
	long:             Long_Press,
	right_on:         Id, // the widget the right button (or the pen's side button) went down on
	// The text field that has the keys, and whether it was drawn this frame (one that is
	// no longer drawn lets them go).
	text_focus:       Id,
	text_seen:        bool,
	// Where the field that has the keys was drawn, and its caret's offset from the field's
	// left, so a tablet's keyboard and a desktop's input method keep clear of it.
	text_rect:        Rect,
	text_caret:       f32,
	text_tapped:      bool, // a text field was tapped this frame
	// The text fields drawn this frame, as far as they show, for the iPad's Scribble to
	// find the one the pencil writes in.
	text_fields:      [MAX_TEXT_FIELDS]Text_Field_Drawn,
	text_field_count: int,
	roll:             Hover_Roll, // the pen's roll on the control it hovers (hover_roll)
}

// The most text fields a frame keeps for Scribble: a panel shows a few at once.
MAX_TEXT_FIELDS :: 16

// A text field as it showed: its id and the part of it the panel's clip let show.
Text_Field_Drawn :: struct {
	id:   Id,
	rect: Rect,
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
	delete(ctx.hint_text)
	names_destroy(&ctx.names)
	ctx^ = {}
}

// Starts a frame with this frame's input. Decides who owns the pointer: a container
// under it from last frame, a widget still held, or else the viewport.
frame_begin :: proc(ctx: ^Context, input: Input) {
	ctx.input = input
	if ctx.input.pixel_density <= 0 do ctx.input.pixel_density = 1
	ctx.clicked_now = false
	ctx.marked = {}
	names_frame(ctx)
	ctx.fonts.cache.frame += 1
	// A frame that took long (a remesh) moves animations on by at most a tenth of a
	// second, so a panel does not skip from start to end mid-animation.
	before := ctx.time
	ctx.time += f64(clamp(input.dt, 0, 0.1))
	if int(ctx.time) != int(before) do tween_prune(ctx)
	draw_list_clear(&ctx.draw)
	ctx.draw.keep = 0
	clear(&ctx.stack)
	ctx.overlaps_prev, ctx.overlap_prev = ctx.overlaps, ctx.overlap_first
	ctx.overlaps, ctx.overlap_first = 0, {}
	ctx.placed, ctx.placed_prev = ctx.placed_prev, ctx.placed
	clear(&ctx.placed)
	ctx.hot = 0
	ctx.active_seen = false
	ctx.text_seen = false
	ctx.text_rect, ctx.text_caret, ctx.text_tapped = {}, 0, false
	ctx.text_field_count = 0
	ctx.roll.seen = false
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
	ctx.long.claimed = 0
	if ctx.active != 0 && ctx.active == ctx.long.id {
		// Still until now, by its travel up to the last frame: a hold that only moves after
		// the long press is a lift, not a drag.
		if !ctx.long.steady && ctx.long.fired != .Off && ctx.long.travel <= ctx.theme.slop && ctx.time - ctx.press_at >= f64(ctx.theme.long_press) do ctx.long.steady = true
		ctx.long.travel = max(ctx.long.travel, linalg.length(input.mouse - ctx.press_mouse))
	}
}

// The anchored container on top at `p` (points) in the frame last ended, or 0 over the
// viewport: what a press there would land on. For use between frames, as when an event
// arrives, since a frame under way has only placed part of its containers.
root_at :: proc(ctx: ^Context, p: [2]f32) -> Id {
	#reverse for c in ctx.placed {
		if c.root && c.id != INERT_ROOT && rect_contains(c.hit, p) do return c.id
	}
	return 0
}

// Ends the frame and returns its triangles, ready to upload. The list stays valid until
// the next frame_begin.
frame_end :: proc(ctx: ^Context) -> ^Draw_List {
	assert(len(ctx.stack) == 0, "a container was begun and not ended")
	select_list_draw(ctx)
	hint_draw(ctx)
	toasts_draw(ctx)
	ring := long_press_decide(ctx)
	labels_draw(ctx)
	tooltip_draw(ctx)
	roll_hint_draw(ctx)
	if ring do long_press_draw(ctx)
	if .Right not_in ctx.input.down do ctx.right_on = 0
	if ctx.active != 0 && (!ctx.active_seen || ctx.input.down == {} || ctx.input.cancel) do ctx.active = 0
	if ctx.scrolling != 0 && ctx.active != ctx.scrolling do ctx.scrolling = 0
	if ctx.swiping != 0 && ctx.active != ctx.swiping do ctx.swiping = 0
	if !ctx.text_seen do ctx.text_focus = 0
	if !ctx.roll.seen do ctx.roll = {}
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
	id := hash_under(seed, label)
	if ctx.names.on do names_seen(ctx, id, seed, label)
	return id
}

// The id `label` has in the container whose id is `parent` (0 at the root, outside every
// container), as id_of gives it there.
hash_under :: proc(parent: Id, label: string) -> Id {
	return hash.fnv64a(transmute([]byte)label, parent if parent != 0 else 0xcbf29ce484222325)
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
	ax, off := mirrored(ctx, x, offset)
	pos := anchored_pos(safe_area(ctx), ax, y, off, size)
	open(ctx, id, {pos.x, pos.y, size.x, size.y}, box, root = true)
}

// The across anchor and offset as the layout places them: in the left-handed layout the
// start and end edges trade places and a centred container moves the other way.
mirrored :: proc(ctx: ^Context, x: Anchor, offset: [2]f32) -> (Anchor, [2]f32) {
	if !ctx.mirror do return x, offset
	switch x {
	case .Start:  return .End, offset
	case .End:    return .Start, offset
	case .Center: return .Center, {-offset.x, offset.y}
	}
	return x, offset
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

// Where the root container `name` (begun outside every container) was last frame, asked
// from anywhere, inside another container too, where prev_rect would look for a child of
// that container; empty the first frame.
prev_root_rect :: proc(ctx: ^Context, name: string) -> Rect {
	id := hash_under(0, name)
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
	layout_fault(ctx, &c, natural)
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
		x := tween(ctx, salt(c.id, 1), r.x - c.rect.x, dur, .Out_Cubic, class = MOTION_TABS)
		y := tween(ctx, salt(c.id, 2), r.y - c.rect.y, dur, .Out_Cubic, class = MOTION_TABS)
		iw := tween(ctx, salt(c.id, 3), r.w, dur, .Out_Cubic, class = MOTION_TABS)
		ih := tween(ctx, salt(c.id, 4), r.h, dur, .Out_Cubic, class = MOTION_TABS)
		fill_rect(ctx, {c.rect.x + x, c.rect.y + y, iw, ih}, ind.radius, ind.color)
		if ind.line.a > 0 do stroke_rect(ctx, {c.rect.x + x, c.rect.y + y, iw, ih}, ind.radius, ind.line, 1)
		draw_move_under(&ctx.draw, c.index_mark, c.cmd_mark, from)
	}
	if c.box.background != .None {
		draw_set_state(&ctx.draw, .Atlas, 0, ctx.clip)
		from := len(ctx.draw.indices)
		t := ctx.theme
		switch c.box.background {
		case .None:
		case .Panel:
			if t.panel_shadow.a > 0 do shadow_rect(ctx, c.rect, c.box.radius, t.panel_shadow)
			fill_rect(ctx, c.rect, c.box.radius, t.surface)
			stroke_rect(ctx, c.rect, c.box.radius, t.border, 1)
		case .Raised:
			shadow_rect(ctx, c.rect, c.box.radius, t.shadow)
			fill_rect(ctx, c.rect, c.box.radius, t.surface_raised)
			stroke_rect(ctx, c.rect, c.box.radius, t.border_strong, 1)
		case .Track:
			fill_rect(ctx, c.rect, c.box.radius, t.fill)
		case .Band:
			fill_rect(ctx, c.rect, 0, t.frame)
			fill_rect(ctx, {c.rect.x, c.rect.y + c.rect.h - 1, c.rect.w, 1}, 0, t.frame_line)
		}
		draw_move_under(&ctx.draw, c.index_mark, c.cmd_mark, from)
	}
	if ctx.mirror_slide > 0 && c.root == c.id && len(ctx.stack) == 0 {
		// Its mirror image's left edge in the safe area, where the other hand had it.
		area := safe_area(ctx)
		from := 2 * area.x + area.w - c.rect.x - c.rect.w
		opacity: f32 = 1 if ctx.motion == .Full else 1 - ctx.mirror_slide
		shift := (from - c.rect.x) * ctx.mirror_slide
		transform_since(ctx, c.vertex_mark, opacity, 1, {}, {shift, 0})
		// A scrolling body inside it clips to where the layout put it: the clip moves with
		// it, or the slide would cut it off. The window's own clip stays.
		if ctx.motion == .Full {
			d := px(ctx)
			for &cmd in ctx.draw.cmds[max(c.cmd_mark, 0):] do if cmd.clip != c.clip_prev do cmd.clip.x += shift * d
		}
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
		// Its children reach where it truly ends, not where last frame's size put it.
		start := c.rect.x if axis == 0 else c.rect.y
		if size[axis] > 0 do p.reach = start + size[axis]
		p.content = {max(p.content.x, c.rect.x + size.x), max(p.content.y, c.rect.y + size.y)}
	}
}

// Counts container `c`'s layout fault, if it has one: children that lie over each other,
// or content longer than its fixed size along its main axis spilling out (one that clips
// or scrolls hides it on purpose). A container marked `overlap` has none by design.
@(private)
layout_fault :: proc(ctx: ^Context, c: ^Container, natural: [2]f32) {
	if c.box.overlap do return
	fault := c.overlapped
	if fault.w == 0 && !c.box.clip && c.box.scroll == 0 {
		// Along its main axis only, where the children run out of room: across it a child
		// taller than a row (a 48 point target in a 44 point bar) only reaches past its
		// edge, as hit areas do. Half a point of slack, for sizes summed in floats.
		if c.box.direction == .Row && c.box.width > 0 && natural.x > c.box.width + 0.5 do fault = c.rect
		if c.box.direction == .Column && c.box.height > 0 && natural.y > c.box.height + 0.5 do fault = c.rect
	}
	if fault.w == 0 do return
	if ctx.overlaps == 0 do ctx.overlap_first = fault
	ctx.overlaps += 1
}

// Where the container that ended last went this frame: what the app records of a
// panel it laid out, to find it again (a drop zone, a menu beside it).
last_ended :: proc(ctx: ^Context) -> Rect {
	if len(ctx.placed) == 0 do return {}
	return ctx.placed[len(ctx.placed) - 1].rect
}

// Reserves room for a widget of `size` points in the current container and returns
// where it goes.
place :: proc(ctx: ^Context, size: [2]f32) -> Rect {
	n := len(ctx.stack)
	if n == 0 do return {0, 0, size.x, size.y}
	c := &ctx.stack[n - 1]
	pos := advance(c, size)
	defer ctx.last_rect = {pos.x, pos.y, size.x, size.y}
	ctx.last_id = 0
	if c.box.center {
		inner := c.cross - 2 * c.box.padding
		if c.box.direction == .Row {
			pos.y += max((inner - size.y) * 0.5, 0)
		} else {
			pos.x += max((inner - size.x) * 0.5, 0)
		}
	}
	r := Rect{pos.x, pos.y, size.x, size.y}
	if m := &ctx.marked; m.control > 0 && !m.found && ctx.controls >= m.control do m.rect, m.found = r, true
	return r
}

// Marks the next control laid out, so that ctx.marked holds where it went: what shows a
// control that something points at (search's Show where). Called just before the control.
mark_next :: proc(ctx: ^Context) {
	ctx.marked = {control = ctx.controls + 1}
}

// The width a widget can take across a column: the container's fixed width less its
// padding, or 0 when it fits its content.
fill_width :: proc(ctx: ^Context) -> f32 {
	n := len(ctx.stack)
	if n == 0 do return 0
	c := ctx.stack[n - 1]
	return max(c.box.width - 2 * c.box.padding, 0) if c.box.width > 0 else 0
}

// The room left along a fixed-width row after what is laid out in it so far, so that a
// spacer of it, less the width of what follows, pushes that to the row's end; 0 when the
// row fits its content.
row_room :: proc(ctx: ^Context) -> f32 {
	n := len(ctx.stack)
	if n == 0 do return 0
	c := ctx.stack[n - 1]
	if c.box.direction != .Row || c.box.width <= 0 do return 0
	return max(c.rect.x + c.box.width - c.box.padding - c.cursor.x, 0)
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
		vertex_mark = len(ctx.draw.vertices),
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
indicator :: proc(ctx: ^Context, r: Rect, radius: f32, color: Color, line := Color{}) {
	if n := len(ctx.stack); n > 0 do ctx.stack[n - 1].indicator = Indicator{r, radius, color, line}
}

// The smallest rectangle holding both.
rect_union :: proc(a, b: Rect) -> Rect {
	x0, y0 := min(a.x, b.x), min(a.y, b.y)
	x1, y1 := max(a.x + a.w, b.x + b.w), max(a.y + a.h, b.y + b.h)
	return {x0, y0, x1 - x0, y1 - y0}
}

// The part of `r` the current clip shows (a scrolled panel's visible part), in points.
clipped :: proc(ctx: ^Context, r: Rect) -> Rect {
	d := px(ctx)
	return rect_intersect(r, {ctx.clip.x / d, ctx.clip.y / d, ctx.clip.w / d, ctx.clip.h / d})
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
	pos := c.cursor
	// A child that starts inside the one before (a spacer pulled the cursor back, as a row
	// whose room ran out does) lies over it: the first such is kept for layout_fault. A
	// child with no size takes no room, so it overlaps nothing.
	if !c.first_child && pos[axis] < c.reach - 0.5 && size[axis] > 0 && c.overlapped.w == 0 do c.overlapped = {pos.x, pos.y, max(size.x, 1), max(size.y, 1)}
	c.first_child = false
	if size[axis] > 0 do c.reach = max(c.reach, pos[axis] + size[axis])
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
	if ctx.names.on do names_place(ctx, id, r)
	// Hit areas may overlap a little (each is at least a touch target, larger than what
	// is drawn); the first widget laid out under the pointer takes it.
	if over && (ctx.active == 0 || ctx.active == id) && (ctx.hot == 0 || ctx.hot == id) do ctx.hot = id
	ctx.last_id = id
	if ctx.hot == id && .Right in in_input.pressed && ctx.active == 0 do ctx.right_on = id
	if ctx.hot == id && .Left in in_input.pressed && ctx.active == 0 {
		ctx.active = id
		ctx.press_mouse = in_input.mouse
		ctx.press_at = ctx.time
		ctx.long = {id = id, shown = ctx.long.shown, shown_len = ctx.long.shown_len, shown_keys = ctx.long.shown_keys, shown_keys_len = ctx.long.shown_keys_len}
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
			// A cancelled press lets go without doing what it would have done, and so does
			// a long press, which did its own thing.
			clicked = over && !in_input.cancel && !long_happened(ctx, id)
			held = false
			if clicked do ctx.clicked_now, ctx.clicked_rect = true, r
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

// How far across its width a paged row must be swiped to turn the page.
SWIPE_TURN :: 0.18

// Turns the pages of a row by a sideways drag, as a launcher's home screen turns: call it
// before laying out the row's container (with Box.drag_scroll set, so a finger or pen
// pressed on a control in it waits to see which way the drag goes), with `id` that
// container's id and `rect` where it was last frame. A drag that goes further across than
// the slop and than up or down takes the press from the control, which lets go without a
// click. Returns how far the drag has carried the row, points, to slide what it shows by;
// and on the frame it lets go, +1 for a swipe to the left far enough to turn to the next
// page, -1 to the right for the one before. A mouse's press on a control is the control's
// at once, so the mouse turns the pages by other means (the wheel, dots).
swipe_update :: proc(ctx: ^Context, id: Id, rect: Rect) -> (offset: f32, turn: int) {
	in_ := ctx.input
	if ctx.swiping == id {
		offset = in_.mouse.x - ctx.swipe_from
		if .Left in in_.down && !in_.cancel {
			ctx.active, ctx.active_seen = id, true
			return
		}
		// Let go: a cancelled swipe turns nothing.
		ctx.swiping = 0
		if !in_.cancel && abs(offset) > max(rect.w * SWIPE_TURN, ctx.theme.slop * 3) do turn = -1 if offset > 0 else 1
		return 0, turn
	}
	if ctx.press_host == id && ctx.active != 0 && ctx.active != id && !ctx.press_won && .Left in in_.down && !in_.cancel {
		d := in_.mouse - ctx.press_mouse
		if abs(d.x) > ctx.theme.slop && abs(d.x) > abs(d.y) {
			ctx.swiping, ctx.swipe_from = id, ctx.press_mouse.x
			ctx.active, ctx.active_seen = id, true
			offset = d.x
		}
	}
	return
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

// Triangles through `points` with a colour at each (`colors`, one a point), blended
// across each triangle, for shaded previews such as a lit sphere. `indices` take three a
// triangle; its edges are not feathered, so a caller outlines the shape.
fill_mesh :: proc(ctx: ^Context, points: [][2]f32, colors: []Color, indices: []u32) {
	if len(points) == 0 || len(colors) < len(points) || len(indices) < 3 do return
	d := px(ctx)
	draw_set_state(&ctx.draw, .Atlas, 0, ctx.clip)
	base := u32(len(ctx.draw.vertices))
	for p, i in points do append(&ctx.draw.vertices, Vertex{p * d, WHITE_UV, colors[i]})
	n := u32(len(points))
	for t := 0; t + 3 <= len(indices); t += 3 {
		a, b, c := indices[t], indices[t + 1], indices[t + 2]
		if a >= n || b >= n || c >= n do continue
		draw_add_indices(&ctx.draw, base + a, base + b, base + c)
	}
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

// An image the app registered (such as the 3D viewport), stretched over `r`, multiplied by
// `tint` (its alpha fades it).
image :: proc(ctx: ^Context, r: Rect, image_id: u64, tint := Color{255, 255, 255, 255}) {
	image_part(ctx, r, image_id, {0, 0}, {1, 1}, tint)
}

// The part of a registered image between texture coordinates `lo` and `hi` (0 to 1),
// stretched over `r`: a cell of an atlas, such as the objects' thumbnails.
image_part :: proc(ctx: ^Context, r: Rect, image_id: u64, lo, hi: [2]f32, tint := Color{255, 255, 255, 255}) {
	draw_set_state(&ctx.draw, .Image, image_id, ctx.clip)
	draw_quad(&ctx.draw, to_px(ctx, r), lo, hi, tint)
}

// A registered image drawn in a circle of `radius` round `center`, the image's square
// fitted to the circle and its corners left out, with a feathered rim: a picture of a
// sphere (a MatCap) shown as the ball it is.
image_disc :: proc(ctx: ^Context, center: [2]f32, radius: f32, image_id: u64, tint := Color{255, 255, 255, 255}) {
	SEGMENTS :: 48
	if radius <= 1 do return
	draw_set_state(&ctx.draw, .Image, image_id, ctx.clip)
	dl := &ctx.draw
	d := px(ctx)
	c := center * d
	r := radius * d
	base := u32(len(dl.vertices))
	append(&dl.vertices, Vertex{c, {0.5, 0.5}, tint})
	clear_tint := color_alpha(tint, 0)
	for k in 0 ..< SEGMENTS {
		a := f32(k) * (2 * math.PI / SEGMENTS)
		dir := [2]f32{math.cos(a), math.sin(a)}
		uv := [2]f32{0.5 + 0.5 * dir.x, 0.5 + 0.5 * dir.y}
		append(&dl.vertices, Vertex{c + dir * (r - FRINGE * 0.5), uv, tint}, Vertex{c + dir * (r + FRINGE * 0.5), uv, clear_tint})
	}
	for k in 0 ..< u32(SEGMENTS) {
		j := (k + 1) % SEGMENTS
		a_in, a_out := base + 1 + k * 2, base + 2 + k * 2
		b_in, b_out := base + 1 + j * 2, base + 2 + j * 2
		draw_add_indices(dl, base, a_in, b_in, a_in, b_in, b_out, a_in, b_out, a_out)
	}
}

// Whether the press on `id` became a long press: its secondary action ran or its
// tooltip showed, so letting go is no click.
@(private)
long_happened :: proc(ctx: ^Context, id: Id) -> bool {
	return ctx.long.id == id && (ctx.long.fired == .Action || ctx.long.fired == .Tip)
}

// Whether the press on `id` is a long press now, not yet acted on: a finger or a pen
// (a mouse uses its right button) held on it for the theme's long_press, never
// further than the slop from where it went down, and moving no value meanwhile.
long_due :: proc(ctx: ^Context, id: Id) -> bool {
	in_ := ctx.input
	if id == 0 || ctx.active != id || ctx.long.id != id || ctx.long.fired != .None do return false
	if in_.pointer == .Mouse || .Left not_in in_.down || in_.cancel do return false
	if max(ctx.long.travel, linalg.length(in_.mouse - ctx.press_mouse)) > ctx.theme.slop do return false
	return ctx.time - ctx.press_at >= f64(ctx.theme.long_press)
}

// Called right after a widget: true once when that widget's secondary action should
// run, as a long press of a finger or the pen, or the right button (the pen's side
// button too) pressed and let go on it. Calling it says the widget has one, so a long
// press on it runs that rather than showing its tooltip. The press it ends wins the
// gesture arena, so a scroll never takes it from under what the action opened.
secondary :: proc(ctx: ^Context) -> bool {
	id := ctx.last_id
	if id == 0 do return false
	if ctx.right_on == id && ctx.hot == id && .Right in ctx.input.released {
		ctx.right_on = 0
		return true
	}
	ctx.long.claimed = id
	if !long_due(ctx, id) do return false
	ctx.long.fired = .Action
	ctx.press_won = true
	return true
}

// Called right after a widget: true for as long as a press on it has been held past the
// theme's long_press without straying further than the slop, by any pointer (the
// mouse's left button too), as a hold to peek wants. Once it is true, letting go is no
// click, and the press wins the gesture arena.
held_long :: proc(ctx: ^Context) -> bool {
	id := ctx.last_id
	in_ := ctx.input
	if id == 0 || ctx.active != id || ctx.long.id != id || .Left not_in in_.down || in_.cancel do return false
	ctx.long.claimed = id
	if ctx.long.fired == .Action do return true
	if ctx.long.fired != .None do return false
	if max(ctx.long.travel, linalg.length(in_.mouse - ctx.press_mouse)) > ctx.theme.slop do return false
	if ctx.time - ctx.press_at < f64(ctx.theme.long_press) do return false
	ctx.long.fired = .Action
	ctx.press_won = true
	return true
}

// Called right after a widget: true once when the press on it lifts it, to be carried
// somewhere else: held still for the theme's long_press by any pointer (the mouse's left
// button too) and then moved past the slop, as a home screen's icon is; with `at_once`
// (an edit mode, where every drag carries) a move past the slop is enough. Letting go is
// then no click, and the press wins the gesture arena, so no scroll or swipe takes it.
lift :: proc(ctx: ^Context, at_once := false) -> bool {
	id := ctx.last_id
	in_ := ctx.input
	if id == 0 || ctx.active != id || ctx.long.id != id || ctx.long.lifted || .Left not_in in_.down || in_.cancel do return false
	if !ctx.long.steady && !at_once do return false
	// Held still long enough (or in the edit mode), the press is this widget's from now
	// on, so the scroll or the swipe round it no longer takes the move that lifts it.
	ctx.press_won = true
	if linalg.length(in_.mouse - ctx.press_mouse) <= ctx.theme.slop do return false
	ctx.long.lifted = true
	ctx.long.fired = .Action
	ctx.press_won = true
	return true
}

// Whether the press on `id` was held still for the theme's long_press: a drag from here on
// lifts it (lift) rather than moving what it holds.
held_still :: proc(ctx: ^Context, id: Id) -> bool {
	return id != 0 && ctx.active == id && ctx.long.id == id && ctx.long.steady
}

// The held widget moved a value (a slider's drag): this press is no long press.
long_cancel :: proc(ctx: ^Context) {
	if ctx.active != 0 && ctx.long.id == ctx.active && ctx.long.fired == .None do ctx.long.fired = .Off
}

// The held widget took the press for a drag of its own (a bar value dragged at once): no
// long press follows, letting go is no click, and no scroll takes the drag from it.
press_used :: proc(ctx: ^Context) {
	if ctx.active == 0 || ctx.long.id != ctx.active || ctx.long.fired != .None do return
	ctx.long.fired = .Action
	ctx.press_won = true
}

// At the frame's end, once every widget had its chance to claim the press: a long press
// on a widget with no secondary action but a tooltip shows the tooltip. Returns whether
// the ring counting toward a long press should show: only on a press that would do
// something, after long_ring, so a tap shows nothing.
@(private)
long_press_decide :: proc(ctx: ^Context) -> (ring: bool) {
	id := ctx.active
	if id == 0 || ctx.long.id != id do return false
	has_tip := ctx.tip_id == id && ctx.tip_len > 0
	if ctx.long.claimed != id && has_tip && long_due(ctx, id) {
		ctx.long.fired = .Tip
		ctx.long.shown_len = copy_text(ctx.long.shown[:], string(ctx.tip_text[:ctx.tip_len]))
		ctx.long.shown_keys_len = copy_text(ctx.long.shown_keys[:], string(ctx.tip_keys[:ctx.tip_keys_len]))
	}
	if ctx.long.fired != .None || ctx.input.pointer == .Mouse || .Left not_in ctx.input.down do return false
	if ctx.long.travel > ctx.theme.slop || (ctx.long.claimed != id && !has_tip) do return false
	return ctx.time - ctx.press_at >= f64(ctx.theme.long_ring)
}

// The ring that fills around the press as it nears a long press, large enough to show
// round a fingertip.
@(private)
long_press_draw :: proc(ctx: ^Context) {
	t := ctx.theme
	f := clamp(f32(ctx.time - ctx.press_at - f64(t.long_ring)) / (t.long_press - t.long_ring), 0, 1)
	hold_ring(ctx, ctx.press_mouse, 34, f)
}

// A ring round `center`, filled clockwise from the top to the fraction `f`: what the long
// press draws as it counts, and what a hold on a drop target can draw as it fills.
hold_ring :: proc(ctx: ^Context, center: [2]f32, radius, fraction: f32) {
	t := ctx.theme
	SEGMENTS :: 48
	f := clamp(fraction, 0, 1)
	draw_set_state(&ctx.draw, .Atlas, 0, full_clip(ctx))
	stroke_circle(ctx, center, radius, color_fade(t.border_strong, 0.8), 3)
	n := max(int(f * SEGMENTS), 1)
	points := make([][2]f32, n + 1, context.temp_allocator)
	for &p, i in points {
		a := -math.PI / 2 + 2 * math.PI * f * f32(i) / f32(n)
		p = center + radius * [2]f32{math.cos(a), math.sin(a)}
	}
	polyline(ctx, points, t.accent, 3)
}

// The text of the last tooltip a long press showed, or "" for none, and its keys.
long_tip_shown :: proc(ctx: ^Context) -> (text, keys: string) {
	return string(ctx.long.shown[:ctx.long.shown_len]), string(ctx.long.shown_keys[:ctx.long.shown_keys_len])
}

// The tooltip the last frame drew, by a long press or a pointer resting, or "" for none.
tip_showing :: proc(ctx: ^Context) -> string {
	return string(ctx.tip_drawn[:ctx.tip_drawn_len])
}
