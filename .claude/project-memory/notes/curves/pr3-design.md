# PR 3 design: edit a stamp before it is kept

Plan state 7. Builds on PR 2's Stroke_Edit (stroke_edit.odin): a stamp is a second kind of held stroke, so Validate,
Cancel, Enter, Escape, Undo, the context bar's Stroke group, brush_stroke_finish closing it and replays skipping it
all hold unchanged.

- When a Rectangle or Drag dot stroke is let go after laying its dab, with Edit stamps on (Stroke > More,
  `stamp_edit`, on by default), the stroke stays open as `Stroke_Edit{stamp = true}` holding the dab: where (object
  space), the surface normal, radius, the alpha's up (object space, square to the normal) and strength.
- Over the model: a ring round the stamp (its radius), a notch every 15° measured on screen from straight up, the 0°
  notch long and orange; a blue dot on the ring at the alpha's top (drag to turn; it snaps to the notch within 4°,
  fixed in this PR; a Snap row can come later if wanted); a white square at the lower right (drag to size);
  a green dot to the left (drag out for more intensity, up to 3× the strength it was laid at); a press inside the ring
  slides the stamp over the surface (raycast; the up carried onto the new plane). A press outside the ring keeps the
  stamp and starts the next one, so a row of stamps stays quick. The angle shows beside the ring.
- Re-lay: restore, then one dab through `brush_at` with the radius, strength and alpha up fixed, exactly what
  `rect_follow` does each frame today, at most once a frame and only after a change.
- Without an alpha the ring and turn dot still show; turning changes nothing then, so the turn dot is dimmed.
- Refused as PR 2's (dynamic topology, voxel clay, takes recording or playing). Exit stats `stamp_edits=`.
- Tests: a released stamp stays open; turning by the ring snaps to 15° and changes the mesh; sliding moves it;
  Cancel restores bit for bit with no History entry; a press outside keeps it and starts the next stroke.
  Touch scenario: a Rectangle stamp by pen, a turn, Enter.
