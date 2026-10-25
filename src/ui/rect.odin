package ui

// A rectangle by its top-left corner and size; layout works in points and the draw
// list in physical pixels, and each use says which.
Rect :: struct {
	x, y, w, h: f32,
}
