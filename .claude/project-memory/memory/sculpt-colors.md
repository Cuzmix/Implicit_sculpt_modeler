---
name: sculpt-colors
description: Procreate-style Colors card + ZBrush-iPad-style Brushes palette work (thread "colour picker / brushes tab", 2026-10-27)
metadata:
  type: project
  modified: 2026-10-27T10:37:47.374Z
---

Bolt asked 2026-10-27 for a colour picker whose popup looks like Procreate's Colors panel (Disc, Classic, Harmony, Value, Palettes; names from Procreate as friendlier) with ZBrush for iPad's Color card strengths (main/secondary swatches, swap, eyedropper, FillObject, FillObject Grad), and for the brush browser to look like ZBrush iPad's Brushes palette.

- #172 merged (Colors card): src/app/kit_colors.odin; new ui widgets gradient_slider + swatch; sculptor_paint_command Gradient + sculptor_color_at in sculpt; Shift+C eyedropper (excluded from pies); settings lines colors_tab, colors_harmony, colors_value_rgb, color_default, color_history, color_palette. Label is "Fill gradient" (not "Fill with gradient": it fuzzy-matched "wire" in the palette test).
- #179 merged (Brushes palette): src/app/kit_brushes.odin; Brush_Item (slot, tool, mask shape, gesture) keyed by brush_item_key ("brush/Clay", "library/Trim"); ui preview_tile + fill_ball; settings brush_category, brush_sidebar_hidden, brush_recent, brush_favorite. Dock slot menu still uses kit_brush_grid. Touch coords for the dock-opened browser are in touch_check.py (BROWSER_CATEGORY, browser_tile).
- usd_export_keeps_layers failed once under full-gate load (9.2e-05 off) and passed alone: a tolerance flake, not ours.
- #206 merged (2026-10-27, Bolt's feedback "tap the colour bar opens the picker"): every kit_color well opens kit_color_popover; it edits a copy handed back next frame via Colors_Card.pop_set/pop_dirty (no pointer kept). ui.popover_begin now ignores presses inside popovers drawn later (stacked popovers). Bolt's other feedback in the same message (hold time, remesh menu, bottom bar swipe/customise, right bar shading/camera icons) went to other threads.
- Screenshots: /mnt/project-files/screenshots/colors/.
