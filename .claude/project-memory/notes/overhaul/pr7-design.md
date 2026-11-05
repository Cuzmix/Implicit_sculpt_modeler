# PR 7: offers, not refusals (as built)

Design §2.6. One PR, no review round (no History, file or GPU change).

- `src/app/offers.odin`: `Offer {what, needs, fix, arg, label}`, `space_fit(app) -> (fits, offer)`, `offer_standing`,
  `command_reason`, `VOXEL_REFUSED_COMMANDS` (the 26 commands that issue MESH_ONLY scene kinds), `kit_offer_line`.
- Rules: Sculpt with Brush/Curve/Insert: cage -> Apply_Cage "Make sculptable"; clay under a non-voxel brush ->
  Convert_To_Mesh. Model with the Model tool: mesh -> Edit_Cage "Make editable" if it can, else Retopologize; clay ->
  Convert_To_Mesh "Make a mesh to edit". Render and Move fit. The offer stands only while its fix is enabled.
- Departure: not cached on history.serial; the checks are a few field reads a frame.
- Departure: brush tiles stay pickable (picking a brush is never wrong; the offer says what it needs).
- The offer line keeps the root name "action bar", so dock_stack and the toasts keep clear of it; it ignores the
  Settings > Interface action bar switch (an offer is not one of the bar's suggestions) but not the hidden zone or
  History.
- Kit: `ui.button` and `ui.menu_item` gain `reason`: disabled with a reason they take hovers and presses (never
  clicking) so the tooltip, by hover or long press, shows it. command_button and command_menu_item pass
  command_reason. ui test a_dimmed_control_says_why.
- Press notes: sculpt_tool's cage and voxel-brush notes are said only when no offer stands. scene_apply's guards and
  notes stay for scripts.
- Chip: amber ring and the offer as its tooltip.
- Stats `offer=` `offer_fixes=`. Touch: offer_line_makes_a_cage_sculptable, offer_line_gives_a_mesh_a_cage_in_model,
  offer_line_converts_clay_for_a_mesh_brush; model_cage_refuses_a_brush_stroke now expects no note and the offer.
