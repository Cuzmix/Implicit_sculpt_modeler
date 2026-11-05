# H3 What a step changed (as built)

- History_Entry.area (object space) recorded in history_record: sculpt.sculptor_last_step_bounds (vertices whose position/mask/colour differ from the saved copy; leaf bounds for full/delta/hidden/groups saves; falls back to listed nodes' leaves) or voxel.clay_last_step_bounds (saved bricks).
- history_tint.odin: rows (mouse/pen hover, or any press) and strip blocks call history_tint_rest each frame; history_tint_frame resets at panel start and ends the menu's kept tint at the next press. Menu row "Show what it changed" (ICON_SCAN_EYE) keeps it.
- draw_history_tint after draw_flashes: flash_screen_box with the step's box (whole object when area empty/zero; nothing for Lights/Arrange), 14 concentric ellipses in KIND_COLORS (gold for strokes), breathing at Motion Full, fainter for undone, label "entry · object · size" above.
- Menu rows now: Go here, Paint back, Bookmark, Show what it changed, View from this step, Only <obj> (list), Delete everything older. touch_check coords: list menu show 451 delete 584; strip menu paint 385 bookmark 429 delete 562.
- Stats history_tints= history_tint=. Scenario history_tint_shows_what_a_step_changed.
