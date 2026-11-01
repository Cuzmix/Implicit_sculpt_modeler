package sculpt

import "core:testing"

// Every brush the preview offers draws a picture that covers the card, and the same brush
// always draws the same picture; a brush that changes the strip differs from Draw's, and
// the plane brush's halves, Fill and Scrape, differ from each other.
@(test)
preview_draws_each_brush_the_same_every_time :: proc(t: ^testing.T) {
	a := make([]u8, PREVIEW_W * PREVIEW_H * 4)
	defer delete(a)
	b := make([]u8, PREVIEW_W * PREVIEW_H * 4)
	defer delete(b)
	draw := make([]u8, PREVIEW_W * PREVIEW_H * 4)
	defer delete(draw)
	testing.expect(t, preview_render({kind = .Draw, strength = 0.5}, draw))
	for kind in Brush_Kind {
		brush := Brush{kind = kind, strength = 0.5, color = {200, 60, 30}, volume = 0.8, tip_roundness = CLAY_TIP_ROUNDNESS, tip_scale = 1}
		if !preview_offered(kind) {
			testing.expect(t, !preview_render(brush, a))
			continue
		}
		testing.expect(t, preview_render(brush, a))
		testing.expect(t, preview_render(brush, b))
		testing.expectf(t, string(a) == string(b), "%v draws differently twice", kind)
		covered := 0
		for i in 0 ..< PREVIEW_W * PREVIEW_H do if a[i * 4 + 3] == 255 do covered += 1
		testing.expectf(t, covered > PREVIEW_W * PREVIEW_H * 9 / 10, "%v covers %d pixels", kind, covered)
		if kind != .Draw do testing.expectf(t, string(a) != string(draw), "%v draws as Draw does", kind)
	}
	testing.expect(t, preview_render({kind = .Flatten, strength = 0.5, plane_short = {1, 0}}, a))
	testing.expect(t, preview_render({kind = .Flatten, strength = 0.5, plane_short = {0, 1}}, b))
	testing.expect(t, string(a) != string(b))
}
