package main

import imgui "deps:odin-imgui"

import "../ui"

// Styles Dear ImGui (the classic panels, the brush pie, the Stats panel) with the same
// tokens and typeface as the ui kit, so the two read as one app. The font data is the
// kit's embedded Inter, which outlives the atlas; ImGui must not free it.
imgui_apply_theme :: proc(t: ui.Theme) {
	io := imgui.GetIO()
	// ImFontConfig's constructor defaults, which the zero value does not give.
	cfg := imgui.FontConfig {
		FontDataOwnedByAtlas = false,
		GlyphMaxAdvanceX     = max(f32),
		RasterizerMultiply   = 1,
		RasterizerDensity    = 1,
		ExtraSizeScale       = 1,
	}
	data := ui.INTER_REGULAR
	_ = imgui.FontAtlas_AddFontFromMemoryTTF(io.Fonts, raw_data(data), i32(len(data)), 15, &cfg)

	s := imgui.GetStyle()
	s.WindowPadding = {12, 12}
	s.FramePadding = {8, 4}
	s.ItemSpacing = {8, 6}
	s.ItemInnerSpacing = {6, 6}
	s.WindowRounding = t.radius_large
	s.ChildRounding = t.radius_medium
	s.PopupRounding = t.radius_medium
	s.FrameRounding = t.radius_small
	s.GrabRounding = t.radius_small
	s.TabRounding = t.radius_small
	s.ScrollbarRounding = t.radius_small
	s.ScrollbarSize = 12
	s.GrabMinSize = 12
	s.WindowBorderSize = 1
	s.PopupBorderSize = 1
	s.FrameBorderSize = 0
	s.SeparatorTextBorderSize = 1
	s.DockingSeparatorSize = 1

	c :: proc(color: ui.Color, alpha: f32 = -1) -> imgui.Vec4 {
		a := f32(color.a) / 255 if alpha < 0 else alpha
		return {f32(color.r) / 255, f32(color.g) / 255, f32(color.b) / 255, a}
	}
	soft := c(t.accent, 0.22)
	col := &s.Colors
	col[imgui.Col.Text] = c(t.text)
	col[imgui.Col.TextDisabled] = c(t.text_tertiary)
	col[imgui.Col.WindowBg] = c(t.surface, 1)
	col[imgui.Col.ChildBg] = {0, 0, 0, 0}
	col[imgui.Col.PopupBg] = c(t.surface_raised)
	col[imgui.Col.Border] = c(t.border)
	col[imgui.Col.BorderShadow] = {0, 0, 0, 0}
	col[imgui.Col.FrameBg] = c(t.fill)
	col[imgui.Col.FrameBgHovered] = c(t.cursor)
	col[imgui.Col.FrameBgActive] = c(t.cursor)
	col[imgui.Col.TitleBg] = c(t.surface, 1)
	col[imgui.Col.TitleBgActive] = c(t.surface, 1)
	col[imgui.Col.TitleBgCollapsed] = c(t.surface, 1)
	col[imgui.Col.MenuBarBg] = c(t.surface, 1)
	col[imgui.Col.ScrollbarBg] = {0, 0, 0, 0}
	col[imgui.Col.ScrollbarGrab] = c(t.cursor)
	col[imgui.Col.ScrollbarGrabHovered] = c(t.text_tertiary)
	col[imgui.Col.ScrollbarGrabActive] = c(t.text_secondary)
	col[imgui.Col.CheckMark] = c(t.accent)
	col[imgui.Col.SliderGrab] = c(t.accent)
	col[imgui.Col.SliderGrabActive] = c(t.accent)
	col[imgui.Col.Button] = c(t.fill)
	col[imgui.Col.ButtonHovered] = c(t.cursor)
	col[imgui.Col.ButtonActive] = soft
	col[imgui.Col.Header] = soft
	col[imgui.Col.HeaderHovered] = c(t.cursor)
	col[imgui.Col.HeaderActive] = c(t.accent, 0.32)
	col[imgui.Col.Separator] = c(t.border_strong)
	col[imgui.Col.SeparatorHovered] = c(t.accent, 0.6)
	col[imgui.Col.SeparatorActive] = c(t.accent)
	col[imgui.Col.ResizeGrip] = {0, 0, 0, 0}
	col[imgui.Col.ResizeGripHovered] = c(t.accent, 0.6)
	col[imgui.Col.ResizeGripActive] = c(t.accent)
	col[imgui.Col.TabHovered] = c(t.cursor)
	col[imgui.Col.Tab] = c(t.surface, 1)
	col[imgui.Col.TabSelected] = c(t.fill)
	col[imgui.Col.TabSelectedOverline] = c(t.accent)
	col[imgui.Col.TabDimmed] = c(t.surface, 1)
	col[imgui.Col.TabDimmedSelected] = c(t.fill)
	col[imgui.Col.TabDimmedSelectedOverline] = {0, 0, 0, 0}
	col[imgui.Col.DockingPreview] = c(t.accent, 0.4)
	col[imgui.Col.DockingEmptyBg] = {0.07, 0.07, 0.08, 1}
	col[imgui.Col.PlotLines] = c(t.accent)
	col[imgui.Col.PlotLinesHovered] = c(t.text)
	col[imgui.Col.PlotHistogram] = c(t.accent)
	col[imgui.Col.PlotHistogramHovered] = c(t.text)
	col[imgui.Col.TextSelectedBg] = c(t.accent, 0.35)
	col[imgui.Col.NavCursor] = c(t.accent)
}
