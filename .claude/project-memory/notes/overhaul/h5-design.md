# H5 quick scrub (built)

- Hold Undo or Redo (finger or pen long press), then slide sideways: one History step per 16 pt, right = forward
  (playhead model, same as the strip's bar). Within 28 pt of the window side it keeps stepping every 0.12 s, because
  Undo/Redo sit in the corner and have little room to the left.
- Mouse: left button on Undo/Redo dragged sideways past the slop scrubs at once; a still click still undoes (no long
  press for the mouse, so slow clicks keep working). Right-click / pen side button still open the panel.
- Long press let go without sliding opens the History panel (old behaviour kept).
- Two or three fingers: only after the hold has fired once (so pausing then panning still pans), sliding without a
  pinch or twist scrubs anywhere. Setting "Two fingers held, then slid, scrub" in History > Settings > GOING BACK
  (`history_no_finger_scrub`, off = scrub on).
- Strip under the top bar while sliding: step label (× N for repeated strokes) · object, "step N of M · slide to scrub,
  lift to stay", blocks with flags and the History brush pin, the two-finger hint.
- Chains are one place (`history_places`). Moves only through `timeline_seek_to`.
- Considered and dropped: content-drag (drag right = undo), vertical slide, velocity acceleration.
