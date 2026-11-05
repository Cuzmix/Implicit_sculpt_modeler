# PR 12 design: Loft cage between curves

Plan item 12, from the mock: "A quad cage bridged across two or more curves, matched by length, with a count of rings
between them." Round 2's answer: Pipe, Lathe and Loft each make a new cage object.

## Which curves

- The selected curves when the selection (the Scene card's multi-select) holds two or more; else the selected curve
  and every other shown, unlocked curve whose use is Line (pure guides; a tube or lathe is an object of its own).
- Order: from the selected (primary) curve, each next the nearest remaining one by the middle of its points (scene
  order breaks ties), so three section curves drawn in any order loft in the order they stand.
- Fewer than two, or a mix of open and closed, is refused with a note saying what to do.

## Geometry (poly/curve_cage.odin, `loft_cage`)

`loft_cage(sections: [][]geom.Bezier_Point (all in one space), closed: bool, o: Curve_Cage_Options) -> (Mesh, err)`:

- Each section is sampled at `around` points evenly by length (an open one `around + 1`, ends included), so curves
  with different point counts match by length, as the mock says.
- Matching: each section after the first is turned (a closed one's start rotated to the sample that makes the sum of
  squared distances to the previous section least) and reversed when that is nearer, so the loft does not twist.
- Rows: the sections, and `steps - 1` rows between each pair along a Catmull-Rom spline through the sections (ends
  repeated), so three or more sections give a smooth body; two give a straight band.
- Faces: quads between rows (a closed loft wraps round); `caps` closes a closed loft's first and last rows with one
  polygon each; an open loft is a sheet with no caps.
- Faces out: a capped or tube-like loft is flipped when the sum of (face middle − middle) · area vector is negative;
  a sheet keeps the order of its first section.
- The section rows are creased when `caps` closes a tube? No: no creases; Smooth rounds the loft as its sections say.
- Limits: `around` 3..64, `steps` 1..16, sections up to 64.

Tests: two parallel circles make a closed tube of around × steps quads (+2 caps); a reversed second circle gives the
same faces (no twist: every quad's area close to the others'); three open lines make a sheet; a mixed set is refused;
the faces face out (positive volume when capped).

## App

- `Command_Id.Curve_Loft_Cage` ("Loft cage from curves"), placed after Curve_Lathe_Cage; the Cage from curve
  section's third button; the object menu's Model verbs for a curve; enabled with a selected curve and another curve
  in the scene. It runs through the existing `.Curve_Cage` Scene_Command with a new field? No: `on` already picks lathe;
  Loft uses `arg = 2` in the existing command's int (`Curve_Cage` gains nothing new if it has an int field; otherwise
  a `cage: u8` kind field at the end of the struct, Pipe 0, Lathe 1, Loft 2).
- `curve_loft_cage(app)`: points of each curve put in world space, then into the primary curve's space for the cage,
  whose transform is the primary curve's; new cage after the primary curve, in its folder, selected, one undo step
  (`history_record_added`), as Pipe and Lathe. Exit stat `curve_lofts=`.
- Touch scenario: two curves drawn (script), Loft from the palette: a new cage, one undo step.
