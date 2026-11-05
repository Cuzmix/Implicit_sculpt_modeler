# PR 10: Motion I (as built)

Design §2.8, Motion I part. Built while the PR 9 design was being written (order only).

- Kit (`src/ui/motion.odin`): `Motion_Level {Full, Reduced, Off}`, `Motion_Class` (distinct u8) with the kit's classes
  MOTION_PRESS, POPOVERS, PANELS, TABS, TOASTS, TOOLTIPS (0..5) and MOTION_ALWAYS (255, level only);
  `ctx.motion`, `ctx.motion_off: bit_set[0..<32; u32]` replace `ctx.reduced_motion`. `tween`/`tween_from`/`presence`
  take `class`; `motion_duration`, `motion_moves`. The kit's 36 tweens got classes by their duration token
  (hover/press -> Press, indicator -> Tabs, popover -> Popovers, panel -> Panels, toast -> Toasts, tooltip -> Tooltips).
- Reduced: `transform_since` drops scale and offset unless `follows = true` (the shelf's swipe and its peek follow the
  finger). Durations stay, so fades fade.
- App (`src/app/motion_prefs.odin`): `Motion_Kind` = the kit's six, then Pages (the shelf's page slide). Settings >
  Interface > Motion: level tabs and a switch per kind (hidden under Off). Lines `motion` (SETTINGS row) and
  `motion_off <names>`; an old `reduce_motion 1` reads as Off. No settings version bump: new lines only, the old one
  still read. `Reduce_Motion` toggles Off/Full.
- New motion: the offer line and the colour island rise in (class Popovers).
- Not done (needs per-platform code, sm-store): the OS reduced-motion preference starting the level at Reduced.
  Motion II kinds (camera ease, pie unfold, ...) add their Motion_Kind rows as they land.
- Tests: ui motion_classes_and_reduced_motion; app motion_settings_are_remembered; touch motion_levels_still_open_menus.
