# Phase 9: Topo pen (design)

This is the design for the Topo pen, one Model action for retopologising a sculpt by hand. It draws on Maya's Quad Draw, Modo's Topology Pen, ZBrush's Retopo brush and Blender's Poly Build. Every gesture is one pen press, drag and lift.

## Where things live

- **The surface.** The Topo pen raycasts the shown objects that are not cages, so any sculpt, voxel object or imported mesh can be the surface. No link to the surface is stored. The pen snaps to whatever non-cage object is under it, so a scene opened later carries on as before. A cage under the pen is picked for its points and edges only.
- **The retopo cage.** This is an ordinary cage object, so every Model action, Smooth, Apply to sculpt and the scene file work on it unchanged.
  - The first face made creates it as a new object named "Retopo of <surface>". It takes the surface's transform, so the cage's space is the surface's space. It is recorded as an added object.
  - Later faces go into the selected cage when one is selected. Otherwise they go into the cage that was made last.
- **Lift.** Points sit a small lift above the surface along its normal: 0.2% of the surface's size, `TOPO_LIFT`. This keeps the cage drawn over the sculpt instead of fighting it in depth.
- **Colour.** The cage is drawn in its own colour, a teal cage material (`TOPO_COLOR`), so it reads apart from the clay.
- **Dots.** Loose points that are not in a face yet are dots, as Quad Draw's are. They are Model tool state, kept in the surface's space. They are not undo steps and are not saved. A Ctrl tap on a dot removes it. A poly cage cannot hold a vertex without a face, so dots wait outside it until a face takes them.

## Gestures

| Gesture | What it does |
|---|---|
| Tap on the surface | Drops a dot there. |
| Ctrl tap on a dot | Removes the dot. |
| Ctrl tap on a cage face | Deletes the face. |
| Drag from a point (a dot or a cage point) over two or more other points | On lift, makes a face of the points in the order the drag met them. The face is turned to face out of the surface. Dots become cage points. A face of 3 to 8 corners is accepted. |
| Drag from a point that meets no other point | Moves the point along the surface. If the pen lifts within the weld radius of another point, the two weld: the moved point goes onto the other. The weld target lights in the weld colour while dragging. |
| Drag from a cage border edge | Extends it: a quad from the edge to where the pen is, the two new points snapped to the surface. A new point that lands on an existing point welds to it, and the weld shows in colour while dragging. |
| Ctrl and a drag from a border edge | Extends the whole border loop by the drag's distance, each new point snapped to the surface. |
| Shift drag (the Smooth sector) | Relaxes the cage points within a brush radius of the pen. Each point goes toward the mean of its neighbours and back onto the surface. Starting on a border point relaxes border points only, along the border. Starting inside relaxes inner points only, with the border pinned. The whole drag is one undo step. |

## Pure parts (`src/poly/topo.odin`)

- `add_polygon(m, corners: []Topo_Corner, group) -> (Edit_Result, Build_Error)`. Each corner is an existing point or a new position. The edit is refused when the face would break the cage, for example an edge with three faces or a repeated corner.
- `border_extend(m, edge or loop) -> new points` reuses `extrude_edges`.
- `relax(m, points, border_only, inner_only) -> []Vec3`. The app projects each new position back onto the surface.

## App

- `Model_Action.Topo` (element Point, target Single). The tool frame branches to `model_topo_frame`, which keeps its own hover: the nearest point within a touch radius, then the nearest border edge, then the surface.
- Overlay:
  - dots as discs, and the point under the pen ringed;
  - during a connect drag, the path through the met points and on to the pen;
  - the weld target in the weld colour;
  - the relax brush as a ring.
- Undo: each committed face, move, weld, extend or relax is a cage swap step, or an added object for the first face.
- Exit stats `topo_dots`, plus the existing cage stats.
- Touch scenarios:
  - four taps then a drag over the four dots makes a one-face cage;
  - a border extend;
  - a weld;
  - a relax that keeps the border.

## Left for later

- A live quad preview under the pen before lifting.
- Edge loop insert by hover, as Quad Draw's Ctrl+hover.
- Retopologising onto a cage instead of a sculpt.
