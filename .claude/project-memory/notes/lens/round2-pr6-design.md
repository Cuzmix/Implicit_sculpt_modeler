# Lens round 2, PR 6: split views chrome

What exists after this PR (screen split2 of the round 2 mockups):

- View pane heads in Lens are chips: camera (dot, name, "ortho"), pass, link, maximise, view window. The camera and
  pass chips open lists (`Pane_Menu` on `Kit_State`, closed with the other floats).
- Dividers get a grip pill and a 24 pt hold. A double tap evens the split (`Handle_Tap`, shared with the stack's
  handles). A drag to the far edge dims the panes beyond and closes them on release, mapped by `grid_close_target`:
  Side by side / Stacked to Single; One plus two div 0 far to Single, div 1 far or near to Side by side keeping the
  pane left; Four and Three across step down to Side by side. The main pane never closes ("The main view stays").
- Camera > View layout in Lens draws the six presets, then "New panes start as" (Front + Side, Same camera, Copy
  view; `new_panes` setting), proportion guides, render preview pane and view window. The View grid command runs
  `grid_choose`, which applies the setting to panes the preset adds.
- With panes showing, the stack becomes a 52 pt strip of tabs; a tap opens that card over the view as a popover
  (Float, Close). The body is `stack_card_body`, shared with the stack and floating cards.
- The shelf centres under the main pane and keeps 170 pt clear each side for the dial and the off-hand island.

Left out on purpose: the mock's "Other panes redraw after each stroke" toggle, since Bolt chose to keep panes
redrawing at rest. The split tree, corner drags, swap and dock are PR 7.

Checks: `grid_close_keeps_the_panes_left`, `handle_taps_make_a_double_tap`, and the six `lens_*` split scenarios in
`touch_check.py`. Screens: `screens/round2/pr6-*.png`.
