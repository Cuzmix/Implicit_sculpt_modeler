package main

import "core:image"
import _ "core:image/png"

import "../render"
import "../sculpt"
import "../ui"

// The brushes' own icons: each brush drawn as a grey ball with its effect in its own
// colour (assets/brush_icons, rendered from the sources in the project's notes/icons),
// shown wherever a brush stands as a button, a tile on a dock or the shelf, or a slice of
// the brush pie, in place of the icon font's glyph. They are packed into one atlas once at
// start-up; a brush whose picture cannot be read keeps its glyph.

// The image id the interface draws the brush icons with.
KIT_BRUSH_ICONS_IMAGE :: KIT_REF_IMAGE_END

// Each icon's side in the atlas, in pixels: a 30 point icon on a 3x screen.
BRUSH_ICON_PX :: 96
BRUSH_ICON_COLUMNS :: 6
BRUSH_ICON_ROWS :: (len(sculpt.Brush_Kind) + BRUSH_ICON_COLUMNS - 1) / BRUSH_ICON_COLUMNS

// Loaded as strings and turned into bytes where decoded: Odin's wasm64p32 code generation
// stops on #load as bytes in a global (README "Web").
BRUSH_ICON_FILES := [sculpt.Brush_Kind]string {
	.Draw         = #load("../../assets/brush_icons/draw.png", string),
	.Smooth       = #load("../../assets/brush_icons/smooth.png", string),
	.Clay         = #load("../../assets/brush_icons/clay.png", string),
	.Flatten      = #load("../../assets/brush_icons/flatten.png", string),
	.Inflate      = #load("../../assets/brush_icons/inflate.png", string),
	.Pinch        = #load("../../assets/brush_icons/pinch.png", string),
	.Crease       = #load("../../assets/brush_icons/crease.png", string),
	.Grab         = #load("../../assets/brush_icons/grab.png", string),
	.Mask         = #load("../../assets/brush_icons/mask.png", string),
	.Layer        = #load("../../assets/brush_icons/layer.png", string),
	.Snake_Hook   = #load("../../assets/brush_icons/snake_hook.png", string),
	.Morph        = #load("../../assets/brush_icons/morph.png", string),
	.Paint        = #load("../../assets/brush_icons/paint.png", string),
	.Cloth        = #load("../../assets/brush_icons/cloth.png", string),
	.History      = #load("../../assets/brush_icons/history.png", string),
	.Elastic      = #load("../../assets/brush_icons/elastic.png", string),
	.Clay_Strips  = #load("../../assets/brush_icons/clay_strips.png", string),
	.Trim_Dynamic = #load("../../assets/brush_icons/trim_dynamic.png", string),
}

Brush_Icons :: struct {
	atlas: render.Texture,
	have:  bit_set[sculpt.Brush_Kind], // the icons the atlas holds
}

// Decodes every icon into one atlas and uploads it. A picture that does not decode, or is
// not BRUSH_ICON_PX square, leaves its cell empty and its brush on the glyph.
brush_icons_create :: proc(app: ^App) {
	w, h := BRUSH_ICON_COLUMNS * BRUSH_ICON_PX, BRUSH_ICON_ROWS * BRUSH_ICON_PX
	pixels := make([]u8, w * h * 4)
	defer delete(pixels)
	cell := make([]u8, BRUSH_ICON_PX * BRUSH_ICON_PX * 4)
	defer delete(cell)
	have: bit_set[sculpt.Brush_Kind]
	for kind in sculpt.Brush_Kind {
		img, err := image.load_from_bytes(transmute([]u8)BRUSH_ICON_FILES[kind])
		if err != nil do continue
		defer image.destroy(img)
		if img.width != BRUSH_ICON_PX || img.height != BRUSH_ICON_PX || !image_rgba8(img, cell) do continue
		x0, y0 := (int(kind) % BRUSH_ICON_COLUMNS) * BRUSH_ICON_PX, (int(kind) / BRUSH_ICON_COLUMNS) * BRUSH_ICON_PX
		for y in 0 ..< BRUSH_ICON_PX {
			row := ((y0 + y) * w + x0) * 4
			copy(pixels[row:row + BRUSH_ICON_PX * 4], cell[y * BRUSH_ICON_PX * 4:][:BRUSH_ICON_PX * 4])
		}
		have += {kind}
	}
	if have == {} do return
	tex := render.picture_create(&app.renderer, pixels, w, h)
	if tex == 0 do return
	app.brush_icons = {atlas = tex, have = have}
}

brush_icons_destroy :: proc(app: ^App) {
	render.matcap_destroy(&app.renderer, &app.brush_icons.atlas)
	app.brush_icons.have = {}
}

// Brush `kind`'s icon as a picture; empty (the glyph stands) when there is none.
brush_icon_picture :: proc(app: ^App, kind: sculpt.Brush_Kind) -> ui.Picture {
	bi := &app.brush_icons
	if bi.atlas == 0 || kind not_in bi.have do return {}
	cw, ch := 1 / f32(BRUSH_ICON_COLUMNS), 1 / f32(BRUSH_ICON_ROWS)
	lo := [2]f32{f32(int(kind) % BRUSH_ICON_COLUMNS) * cw, f32(int(kind) / BRUSH_ICON_COLUMNS) * ch}
	return {image = KIT_BRUSH_ICONS_IMAGE, lo = lo, hi = lo + {cw, ch}, aspect = 1}
}

// The icon picture a bar's slot shows: a brush's, or a preset's brush's; empty for every
// other command, which keeps its glyph.
bar_picture :: proc(app: ^App, s: Bar_Slot) -> ui.Picture {
	#partial switch s.id {
	case .Brush:
		if s.arg >= 0 && s.arg < len(sculpt.Brush_Kind) do return brush_icon_picture(app, sculpt.Brush_Kind(s.arg))
	case .Brush_Preset:
		if p, ok := preset_at(app, preset_slot_number(s.arg)); ok do return brush_icon_picture(app, p.values.kind)
	}
	return {}
}

// The icon picture a Library item shows on a tile: a brush's or a preset's.
brush_item_picture :: proc(app: ^App, it: Brush_Item) -> ui.Picture {
	if it.what != .Slot || it.slot.command.id != .None do return {}
	return brush_icon_picture(app, it.slot.kind)
}
