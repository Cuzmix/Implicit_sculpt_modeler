# 02 · Workflow Inventory

The end-to-end jobs artists do, traced step by step through each product's documented path. Step counts are the documented minimum actions for a desktop user (keys or clicks) unless marked touch. "Friction" lists what the docs themselves warn about. "Us" says how our app does it today and what is missing.

Sources are IDs from `00_Sources.md`.

---

## W1. First five minutes (open the app, make a mark)

| | ZBrush | Nomad | 3DCoat | Us |
|---|---|---|---|---|
| Steps | Open LightBox or Home, pick a project (e.g. DynaMeshSphere), *or* draw a primitive on canvas then press T for Edit mode | App opens with a sphere; drag on it | Quick Start dialog: choose a task (Voxel Sculpting, Surface Sculpting, Paint, Retopo... 15 entries) | Opens with a sphere; drag on it |
| Actions to first stroke | 2-4 | 0 | 2 | 0 |
| Friction | Drawing a tool without pressing T "drops" it to 2.5D pixols and it can no longer be sculpted; recovery is Ctrl+N or undo (Z107). Three file types ZBR/ZTL/ZPR confuse beginners (Z109). | Symmetry on by default surprises asymmetric work (N002). | Task choice before any mark; rooms are not explained on the rooms page (C053). | No hint of what Ctrl/Shift do on touch; no sample scenes. |
| Evidence | Z107, Z109, Z131, Z112 | N002 | C063, C053 | 13 |

**Takeaway.** Zero steps to first mark (Nomad, us) is right. 3DCoat's task-first launcher is right for *returning* users with a goal. ZBrush's canvas model is the cautionary tale.

## W2. Blockout from primitives

| | ZBrush | Nomad | 3DCoat | Us |
|---|---|---|---|---|
| Path | Append/Insert primitives as SubTools → Gizmo 3D (W, then Y toggles gizmo) → move/scale/rotate → Live Boolean or DynaMesh merge (Ctrl-drag background) | Scene > Add primitive (parametric until Validate) → auto-switch to Gizmo → clone/instance → repeaters → Voxel Merge or Boolean | Sculpt room: Primitives tool, click to place (preview slides along normal), RMB drag = scale/depth, add/subtract each placement → merge in Sculpt Tree | Scene tab Add object → Move tool (move only) → Object tab Transform values → Booleans or Remesh |
| Strength | Click on surface moves the gizmo there, oriented to the face (Z066) | Pivot presets (bottom, mask centre), sausage-sphere tip, repeaters (N021, N006) | One gesture grammar for brush and primitive (C081) | Booleans and remesh exist |
| Friction | Folder ops not undoable; cannot sculpt several SubTools at once (Z058, Z057) | Gizmo symmetry is a separate checkbox, off by default; "Pin" confuses (N004, N020) | Voxel resolution trial and error (C018) | No rotate/scale gizmo, no pivot placement, no snapping, no parenting |
| Evidence | Z066, Z075, Z081 | N006, N004, N021 | C081, C016 | A-10 |

## W3. Organic character (form → secondary → detail)

| Stage | ZBrush | Nomad | 3DCoat | Us |
|---|---|---|---|---|
| Form | DynaMesh at low res, SnakeHook, remesh often (Z043) or ZSpheres armature (Z145) | Voxel remesh blockout or tubes for limbs or multi-object blockout (N021) | Voxels at low resolution, Vox Clay, Res+ when needed (C009) | Voxel remesh or dyntopo |
| Secondary | ZRemesher → subdivide → sculpt at mid levels (Z052) | Quad Remesher → multires (N021) | Surface mode, Remove Stretching + Auto-Subdivide (C013) | Retopo → subdivision levels |
| Detail | High SDiv, alphas, layers; HD geometry for extreme detail (Z060) | Top multires level, alphas, layers | Surface brushes, sculpt layers, VDM extrude (C015) | Levels, HD windows, alphas, layers |
| Friction | Polygroups must be made at lowest level; layers at top level only (Z049, Z089) | Topology change wipes multires; multires "pimples" after voxel (N007, N021) | Surface→voxel loses layers and freeze (C075) | No guided path between stages; each lives in a different Object section |
| Evidence | Z043, Z052, Z060 | N021, N007 | C009, C013 | A-01 |

**Takeaway.** All three agree on the stage model: *volume-free blocking → clean topology → multires detail*. None makes the transition one obvious step. A "next stage" affordance that runs the right remesh/retopo/subdivide is an opportunity (O-31 in 07).

## W4. Hard surface

| | ZBrush | Nomad | 3DCoat | Us |
|---|---|---|---|---|
| Path | ZModeler (hover element, Space for Action×Target menu) + Dynamic Subdivision; Clip/Trim brushes; Live Boolean; Gizmo deformers (bevel, slice) | Trim/Split with Boolean fill (ortho camera), Planar/Flatten with locks, booleans on watertight meshes | Modeling room (poly editing) → subdivide into Sculpt; voxels for booleans; Sculpt Bevel along curves; Soft Booleans | Clip, slice, booleans, flatten |
| Friction | ZModeler depends on hover previews that touch screens lack (Z130, Z153); modifier timing before vs after click changes meaning (Z141) | No low-poly modelling ("not planned"), top request (N020, N022) | Virtual mirror looks applied but isn't (C054) | No planar lock, no bevel, no poly editing |
| Evidence | Z082, Z068, Z143 | N004, N022 | C054, C080, C016 | – |

## W5. Remesh loop (keep topology even while blocking)

| | ZBrush | Nomad | 3DCoat | Us |
|---|---|---|---|---|
| Trigger | Ctrl + drag on empty canvas (Z075) | Bottom-bar Voxel button; long-press for resolution (N002) | Enter in Surface mode (temporary voxelize) (C013) | Ctrl+R, or Object > Remesh |
| Feedback | Polyframe | Checkerboard preview of polygon size while dragging resolution (N007) | Resolution tag in tree | Vertex count |
| Friction | Same gesture region as mask-clear; only changed areas rebuild | Detail lost at low res | Faceting | No size preview |

## W6. Masking and isolating a region

| Step | ZBrush desktop | ZBrush iPad | Nomad | 3DCoat | Us |
|---|---|---|---|---|---|
| Mask paint | Ctrl + stroke | Hold Ctrl on wheel + stroke | Mask tool, or hold Mask button | Freeze tool, hold F (sticky) | Mask brush, Ctrl |
| Mask shape | Ctrl + drag off-model | same, Space moves shape, Alt before lift subtracts | SelMask + lasso/rect/ellipse/polygon, auto-validate or green ✓ | E panel lasso modes | Ctrl + drag off-model |
| Invert / blur / sharpen / clear | Ctrl+click bg / Ctrl+click mask / Ctrl+Alt+click / Ctrl+drag bg | same via wheel | Hold Mask + tap bg / tap masked / tap unmasked / drag bg | Ctrl+Shift+I, Ctrl+NUM*, ... | Alt+M clear, Ctrl+I invert, buttons |
| Isolate a part | Ctrl+Shift click polygroup | Ctrl+Shift tap group | Hide tool + tap group | Alt+LMB layer | Hide rectangle/lasso |
| Evidence | Z061, Z063 | Z040, Z041 | N004, N003 | C026, C004 | README |

**Takeaway.** The ZBrush grammar ("where the click lands" × modifier) is the fastest once learned and the hardest to discover (Z061 admits it). Nomad keeps the same taps but puts them behind *holding the Mask button*, which is visible and touch-native. That is the model to copy for our touch modifier buttons (A-12).

## W7. Retopology, UVs and baking

| | ZBrush | Nomad | 3DCoat | Us |
|---|---|---|---|---|
| Auto | ZRemesher target count + guides + polypaint density; Retry re-runs from original (Z052, Z127) | Quad Remesher (paid on iOS/desktop, none on Android) with density dots and guides (N004) | Autopo with density shading, flow guides, through guides; Instant Meshes (C035) | Retopologize (quad target) |
| Manual | Topology brush, ZSphere retopo (Z007) | – | Retopo room: Strokes, Quads, Smart Retopo, Points to Polygons (C036) | – |
| UV | UV Master one click; UV Editor 2027 (Z102, Z098) | UVAtlas / BFF, slow above 100k (N007) | UV room, LSCM/ABF, live distortion preview (C037) | Auto UVs |
| Bake | Maps from lowest level (Z059) | Bake → Texture with cage radius, ray offset (N007) | Bake to Paint room (C034) | Bake maps |
| Friction | Remeshing breaks Selection Sets (Z097) | Several overlapping remeshers (N007) | Must pick right UV map / retopo layer first (C034) | One-shot; no guides |

## W8. Painting

| | ZBrush | Nomad | 3DCoat | Us |
|---|---|---|---|---|
| Path | Colorize on, Zadd off, Rgb on, paint (Z091); SpotLight for photo projection (Z092) | Paint tool or "Paint" checkbox on any sculpt tool; PBR channels; Paint All (N015) | Paint room: choose painting mode, layers, smart materials, conditions (C039, C041) | Paint brush, fill colour, polygroups |
| Friction | Channel toggles are invisible state | Matcap shows colour only (N015) | Mode choice up front; conditions persist until reset (C042, C023) | No layers for paint, no roughness/metal |

## W9. Posing

| | ZBrush | Nomad | 3DCoat | Us |
|---|---|---|---|---|
| Path | Transpose topological mask (Ctrl-drag) + rotate; Transpose Master for multi-SubTool (Z064, Z104) | Gizmo with mask; no rig (planned) (N020) | Pose tool: line/ring/sphere selection gradients + gizmo; lattice (C071) | Mask + Move gizmo (move only) |
| Friction | Cannot pose several SubTools at once without a plugin (Z104) | "Rig" top request (N022) | – | No rotate |

## W10. Recovering from mistakes

| | ZBrush | Nomad | 3DCoat | Us |
|---|---|---|---|---|
| Undo model | Per-SubTool timeline, markers, saved in ZPR; separate 14-step camera undo; History brush; Project History from any point (Z096, Z110, Z117) | Memory-budgeted stack, per-op camera restore, 2/3-finger tap with hold-repeat (N019) | Ctrl+Z/Ctrl+Y; some merges not undoable (C040) | Scene-wide history across objects and levels; timeline scrub; time-lapse |
| Friction | Some ops wipe all history; folder ops not undoable (Z096, Z058) | Palm taps undo by accident (N022) | Several destructive ops | No camera undo; no local (brush) undo |

## W11. Save, export, hand off

| | ZBrush | Nomad | 3DCoat | Us |
|---|---|---|---|---|
| Save | Ctrl+S project, QuickSave (9), AutoSave on idle (Z109) | Manual; reminder popup; no background save by design (N005) | Background save that finishes 10-30 s after it looks done (C059) | Ctrl+S `.sculpt` |
| Export | GoZ, OBJ, 3D print hub (Z103, Z146) | glTF/OBJ/USD/PLY/STL/FBX matrix, Link to Blender (N005, N022) | Many formats, applinks, export presets per engine (C067) | OBJ, PLY |
| Friction | Undo history only in ZPR | Save As overwrote projects (forum, N022) | Reboot during late save destroys scene | No autosave; no glTF/USD |

## W12. Customising the tool to the artist

| | ZBrush | Nomad | 3DCoat | Us |
|---|---|---|---|---|
| Path | Ctrl+Alt+click to bind; Enable Customize + Ctrl+Alt drag to build menus; Store Config (Z071, Z073) | Interface menu: bottom-bar bindings (searchable), floating toolbars, gesture assignment, key/stylus/gamepad bindings (N003) | END over anything to bind (stack/sticky); Customize UI checkboxes; menu.cpp scripts; rooms (C004, C028, C029) | Settings panel (4 tabs); no bindings |
| Friction | Preferences do not save automatically; restart to remove a menu (Z072, Z073) | Gesture conflicts silently disable one (N003) | Editing text files; conflicting hotkey docs (C029, C004) | Nothing to customise beyond settings |

---

## Workflow map: where each product is strongest

| Workflow | Best documented model | Why |
|---|---|---|
| First mark | Nomad (= us) | Zero steps, visible toggles |
| Blockout | Nomad + 3DCoat | Parametric primitives with pivots and repeaters; one gesture grammar for placement |
| Organic detail | ZBrush | Levels + HD + layers + history projection |
| Hard surface | ZBrush (desktop) | ZModeler + dynamic subdivision + deformers |
| Volume / booleans | 3DCoat | True voxels, live booleans in a tree, soft booleans |
| Masking on touch | Nomad | Hold Mask button + tap gestures |
| Retopo | 3DCoat | Auto + a whole manual room |
| Painting | 3DCoat | Smart materials, conditions, modes |
| Recovery | ZBrush | Markers, local undo brush, projection from history |
| Customisation | Nomad (touch), 3DCoat (desktop) | Searchable bindings, toolbars; END-to-bind |
