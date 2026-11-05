# Lens P1-7: camera linking and colour dots

Spec: Lens report P1 item 7 ("Camera linking and colours: independent, linked, mirrored; colour dot per camera"), and the mock's notes: "Each pane owns a camera ... Linked panes share one colour, so linking is visible without reading"; "Linked panes share the teal camera: orbit any one and all three turn together"; "Its camera is independent; tap the link icon to make it follow".

## What exists when done
- **Three ways a view pane's camera relates to the main one** (the view grid's panes and the second view alike):
  - **Linked** (was Follow; files still say `Follow`): the main camera itself. A drag in a linked pane now turns the main camera, so the main view and every linked pane turn together, instead of breaking the pane off to Free. The wheel zooms the main camera.
  - **Mirrored** (new, `Mirror`): the main camera reflected in the X symmetry plane, so it shows the other side from the matching place: the left cheek in the main view, the right cheek here, for symmetry and likeness checks. A drag turns the main camera, with the sideways part reversed so the picture follows the finger.
  - **Independent**: the six axis views and Free, as now. A drag turns the pane's own Free camera.
- **The link button** in each pane's head, after the selects: a link icon, lit while the pane is linked or mirrored. A tap on an independent pane links it (Linked); a tap on a linked or mirrored pane unlinks it to Free at the view it shows, so nothing jumps.
- **Colour dots**: every camera has a colour from the theme (`Theme.camera`): the main camera's is the first (Lens: Glaze teal), and each independent pane's is its own (pane 1 violet, pane 2 amber, pane 3 pink; the second view's is the violet). A dot in that colour leads each pane's head; a linked pane's dot is the main camera's colour, and a mirrored one's is the main colour as a ring. In the grid, the main pane gets a 2 pt outline in the main camera's colour (the mock's active pane), so which pane the tools act in is plain.
- The Camera select's names: Linked, Mirrored, Front, Back, Left, Right, Top, Bottom, Free.
- Exit stats: `pane_links=` (panes linked or mirrored) and `linked_turns=` (frames a drag in a linked pane turned the main camera).

## Code
- `thumbnail.odin`: `Second_Camera` gains `Mirror` at the end (the settings and layout text name cameras, so files read as before); `SECOND_CAMERA_NAMES` shows Follow as "Linked". `second_orbit` handles `.Mirror` with `camera_mirror_x(c)` (pure, in `src/camera`: target.x, yaw and roll negated) and tested: the mirrored eye is the main eye with x negated. `second_view_input`: for Follow and Mirror, a drag past the slop turns `app.camera` (the nav head's precedent), the wheel zooms it; the pane redraws each frame while dragged, as an own-camera drag does. `second_link_toggle(app, sv)`.
- `grid.odin` and the thumbnail head: the dot (`camera_dot(ctx, color, ring)`, a small ui place-and-circle), the link `icon_button`, the main pane's outline.
- `second_color(t, sv, index) -> (ui.Color, ring: bool)` gives the dot colour.

## Tests and checks
- Unit: the mirror is an involution and mirrors the eye; `second_color` for linked, mirrored and independent panes; the layout round trip with a `Mirror` pane.
- Touch: a drag in a linked pane turns the main camera (camera_yaw changes, the pane stays Follow); the link button unlinks to Free and a later drag leaves the main camera still; Mirrored shows (pane_camera=Mirror).
- Dumped Four screen with one linked, one mirrored and one Front pane, described.
