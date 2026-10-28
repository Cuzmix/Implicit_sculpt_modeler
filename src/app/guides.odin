package main

import "core:fmt"
import "core:math"

import "../camera"
import "../ui"

// Proportion guides (Camera > Proportion guides, Lens): three level lines at heights on the
// model, Brow, Nose base and Chin, drawn across every level side view at once, so a
// likeness's proportions read the same from the front and the side. The idea is the
// portrait painter's face thirds and the dashed height lines of ZBrush's and Blender's
// reference setups, made live: drag a guide's tag in any view that shows it and it moves
// in all of them. The guides belong to the model, so the scene keeps them; they never
// change it, so they are never an undo step, as the camera is not.

Guide :: enum u8 {
	Brow,
	Nose_Base,
	Chin,
}

@(rodata)
GUIDE_NAMES := [Guide]string {
	.Brow      = "Brow",
	.Nose_Base = "Nose base",
	.Chin      = "Chin",
}

// The guides as the scene keeps them: shown or not, whether their heights were seeded
// yet, and each guide's world height.
Guides :: struct {
	shown:   bool,
	seeded:  bool,
	heights: [Guide]f32,
}

// Lucide's align-vertical-space-between for the guides, and rotate-ccw for putting them back.
ICON_GUIDES :: rune(0xe27b)
ICON_GUIDES_RESET :: rune(0xe14c)

// The bytes guides_put writes: the flags and three heights.
GUIDES_BYTES :: 1 + 3 * size_of(f32)

// The height of a guide's tag, which a drag moves it by, and its hit area's, in points.
GUIDE_TAG_H :: 22

// Seeds the heights by the classic face thirds over the selected objects' bounds (else
// the shown objects', else a unit box about the origin): Chin at the bottom, Nose base a
// third up and Brow two thirds up.
guides_seed :: proc(app: ^App) {
	lo, hi, ok := objects_bounds(app, true)
	if !ok do lo, hi, ok = objects_bounds(app, false)
	if !ok do lo, hi = {-1, -1, -1}, {1, 1, 1}
	g := &app.scene.guides
	h := hi.y - lo.y
	g.heights = {.Brow = lo.y + h * 2 / 3, .Nose_Base = lo.y + h / 3, .Chin = lo.y}
	g.seeded = true
}

// Shows or hides the guides, seeding them the first time they are shown in a scene.
guides_toggle :: proc(app: ^App) {
	g := &app.scene.guides
	g.shown = !g.shown
	if g.shown && !g.seeded do guides_seed(app)
	app.view_edits += 1
}

// Puts the guides back at the seeded heights for what is selected now, and shows them.
guides_reset :: proc(app: ^App) {
	guides_seed(app)
	app.scene.guides.shown = true
	app.view_edits += 1
}

// The world heights as one stat, for the exit line.
guides_heights_text :: proc(g: Guides) -> string {
	return fmt.tprintf("%.3f,%.3f,%.3f", g.heights[.Brow], g.heights[.Nose_Base], g.heights[.Chin])
}

// Counts a guide drag that ended as one change to what the scene saves: once when it is
// let go, not every frame it moves. Runs once a frame before the guides are laid out.
guides_frame :: proc(app: ^App) {
	k := &app.kit
	if k.guide_held != 0 && k.ctx.active != k.guide_held {
		k.guide_held = 0
		app.view_edits += 1
	}
	k.guide_lines = 0
}

// The guides over a view at `r` that sees through `o`, when they are shown and `o` is a
// level side view: a dashed amber line across it at each guide's height and the guide's
// tag at the right end, clear of a docked column, which a drag moves up and down (the
// pointer's height in this view becomes the guide's height in every view). `name` keeps
// each view's tags apart.
kit_guides :: proc(app: ^App, r: ui.Rect, o: camera.Orbit, name: string) {
	k := &app.kit
	g := &app.scene.guides
	if !g.shown || !g.seeded || r.w <= 0 || r.h <= 0 || !camera.orbit_is_level(o) do return
	ctx := &k.ctx
	t := ctx.theme
	// The tags end at the view's right edge, or left of a docked column over it, or of the
	// view bar when the view runs to the window's edge.
	area := ui.safe_area(ctx)
	right := min(r.x + r.w, area.x + area.w - kit_right(app)) - 6
	for side in Column_Side {
		c := k.panels.rect[side]
		if c.w > 0 && c.x > r.x && c.x < right do right = min(right, c.x - GRID_COLUMN_GAP)
	}
	top := max(r.y, kit_top() - 8)
	for guide in Guide {
		y := r.y + r.h * camera.orbit_level_frac(o, g.heights[guide])
		if y < top || y > r.y + r.h do continue
		y = math.round(y)
		label := GUIDE_NAMES[guide]
		w := ui.text_width(ctx, label, t.small_size, .Semibold) + 16
		tag_x := right - w
		if tag_x <= r.x do continue
		k.guide_lines += 1
		// Dashes of 6 points with gaps of 4, on a faint dark edge so they read on a light pass.
		for x := r.x; x < tag_x - 4; x += 10 {
			seg := min(6, tag_x - 4 - x)
			ui.fill_rect(ctx, {x, y - 0.5, seg, 2}, 0, {0, 0, 0, 0x55})
			ui.fill_rect(ctx, {x, y - 1, seg, 1.5}, 0, t.warning)
		}
		ui.begin_at(ctx, fmt.tprintf("guide %s %d", name, int(guide)), {tag_x, y - t.target * 0.5}, {width = w, height = t.target})
		a := ui.area(ctx, "tag", {w, t.target})
		plate := ui.Rect{tag_x, y - GUIDE_TAG_H * 0.5, w, GUIDE_TAG_H}
		ui.fill_rect(ctx, plate, t.radius_small, t.surface)
		ui.stroke_rect(ctx, plate, t.radius_small, t.warning, 1.5 if a.held || a.hovered else 1)
		ui.text(ctx, label, plate.x + 8, plate.y + GUIDE_TAG_H * 0.5, t.small_size, t.warning, .Semibold)
		if a.held {
			k.guide_held = a.id
			height := camera.orbit_level_height(o, clamp((a.mouse.y - r.y) / r.h, 0, 1))
			if height != g.heights[guide] {
				g.heights[guide] = height
				k.guide_drags += 1
			}
		}
		ui.end(ctx)
	}
}
