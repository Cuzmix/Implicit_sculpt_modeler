# 04 · Nomad Sculpt Analysis

Built from all 21 pages of the official manual plus 17 forum pages (top lists, feature requests, bug reports, high-signal threads, change log). IDs refer to `00_Sources.md` (N001-N021 manual, N022 forum). The manual lags the app: v2.9 (Dec 2025) features such as Lattice, VDM brushes, Text, Link with Blender/ZBrush, surface repeater, Elastic/Polish brushes and project history replay appear only in the change log (N022).

## 1. The mental model Nomad teaches

Nomad's manual is organised **by menu, and the menus are organised by object of attention** (N001): scene menus on the top left (Files, Scene, Topology, Material, Shading, Post process, Background, Camera), tool menus on the top right (Stroke, Painting, Symmetry, Layers, Settings, Interface), a toolbox grid on the right, radius/intensity and context buttons on the left, and a bottom bar of display toggles (N002).

Data model (N006, N007, N017, N015):

```
Project (.nom)
 └─ scene graph (tree): mesh objects, groups, cameras (views + reference images), lights (≤4), repeaters (array/radial/curve/mirror)
     ├─ node = transform matrix (move/rotate/scale + pivot) — separate from vertices
     ├─ instances (linked mesh) vs clones; primitives stay parametric until Validate
     └─ mesh object
         ├─ topology: multires level stack (LV0 lock, per-level sharp border) | voxel remesh | dyntopo triangles
         ├─ per-vertex: colour, roughness, metalness, opacity, mask; per-face: face group
         ├─ layers: sculpt deltas (additive) + paint channels (25 blend modes); survive topology change
         └─ material (type, PBR params, optional UV textures)
```

**Why it is structured this way.** Nomad is one developer's app built for phones and tablets first (N020). Every design choice trades breadth for touch reach: a small toolbox (≈30 tools), menus that collapse on small screens, sticky buttons instead of modifier keys, long-press for options, and gestures for everything else. Desktop came later and reuses the same layout.

## 2. Why artists use it

- **Zero-friction start:** the app opens on a sphere with symmetry on and Clay selected (N002).
- **Touch-native interaction** that works with a finger or pen, no keyboard (N002, N012).
- **Good enough depth**: multires, voxel remesh, dyntopo, layers, PBR vertex paint, booleans, tubes, repeaters, bake, quad remesher (N004, N006, N007).
- **Price and platform**: one-time purchase, iOS/Android/desktop/web demo (N020).
- **Beautiful real-time render** with PBR, post-process and HDRIs (N009, N010).

## 3. What makes it fast (world-class)

| Pattern | How it works | Evidence |
|---|---|---|
| **Sticky buttons** | Tap Sub/Smooth/Mask/Hide/Gizmo/Color/Alpha = latch; hold = momentary. Replaces modifier keys on touch with no mode errors. | N004 |
| **Hold Mask + tap gestures** | While holding the Mask shortcut: tap background = invert, drag background = clear, tap masked = blur, tap unmasked = sharpen. ZBrush's grammar, made visible. | N004, N003 |
| **Long press / swipe-up for options** | Every bottom-bar toggle opens its settings this way (X-ray colour, voxel resolution, grid, wireframe). | N002, N016 |
| **Double-tap to set pivot / frame** | Double-tap model = pivot there; background = frame selection; pivot moves between two fingers. Pink pivot dot while orbiting. | N012 |
| **Two-phase shape tools** | Draw a lasso/rect/polygon; either auto-validate or a green ✓ appears so you can orbit and adjust before committing. | N004 |
| **Contextual top toolbar per tool** | Mask, Tube, Lathe, Hide, Quad Remesher each show their actions at the top of the viewport; collapsible, dockable top/bottom. | N004 |
| **Tools are presets** | Long-press any tool: Save, Clone, Last save, Icon, Reset. Community brush packs are among the most viewed forum threads. | N004, N022 |
| **Searchable bindings + floating toolbars** | Any function can go on the bottom bar or a floating toolbar, or be bound to key/stylus/gamepad; tap vs hold distinction. | N003 |
| **Resolution checkerboard preview** | Dragging voxel resolution shows a checkerboard of the polygon size before remeshing. | N007, N006 |
| **Tree view drag gestures** | Drag down the select or visibility column to toggle many rows; long-press to reorder/parent. | N006 |
| **Layers survive topology change** | Voxel remesh, multires and trim keep layers (unlike most apps). | N017 |
| **Memory-budgeted undo with camera restore** | History limit in MB; each step restores its view; memory shown per step. | N019 |
| **Stroke offset** | Brush centre shifted away from the finger on small screens. | N013 |
| **Accessibility assistive window** | Floating buttons for drag/pinch/roll for users who can't multitouch. | N003 |

## 4. What causes friction (docs and forum)

| Friction | Evidence |
|---|---|
| No background autosave by design (3D files too big); only a reminder popup. Forum: Save As overwrote other projects; "week of work lost". | N005, N022 |
| Topology-altering tools (voxel remesh, dyntopo, trim, split) destroy multires levels (with a warning). | N007 |
| Several overlapping remeshers (voxel, dyntopo remesh, Instant quads, Quad Remesher, voxel merge) confuse. | N007 |
| Local vs World symmetry: users get lost; developer admits adding Local "may have been a mistake". | N016, N022 |
| Getting lost with the camera pivot (docs admit). | N012 |
| Boolean operation chosen by *visibility* state (union = both visible, subtract = one hidden). Implicit. | N006 |
| Gizmo/transform tools have their own symmetry checkbox, off by default; "Pin" confusion. | N004, N020 |
| Perspective camera breaks Trim/Split/Project (warning shown). | N004 |
| Two curve systems (Tube vs Curve repeater) — forum thread "TUBE NEEDS TO DIE". | N022 |
| Palm touches trigger undo/selection/camera (forum, partly fixed). | N022 |
| Protect "Auto" depends on Shading menu toggles (hidden coupling); Use Hide only works outside the Hide tool. | N013, N009 |
| Huge per-tool option count in Stroke (Stroke/Alpha/Falloff/Filter/Pressure). | N013 |
| 4-light cap, no animation, no low-poly modelling, no deformers until 2.9. | N009, N020, N021 |
| Android: keyboard support experimental, finger pressure unreliable, Quad Remesher unavailable, much slower devices. | N003, N014, N020 |
| UI/UX feature requests "largely ignored unless many ask"; manual has typos and lags features; users ask for a glossary/cheat sheet. | N022 |

## 5. What beginners struggle with

1. Where the camera rotates around (pivot) and why the model drifts away (N012).
2. Symmetry space (Local/World) and off-axis symmetry (N016, N022).
3. Saving: Save vs Save As vs project browser; reflexive confirmations (N022).
4. Discovering hidden gestures (two-down-lift-one orbit, four-finger tap, hold-Mask taps) (N012, N021).
5. Which remesher to use (N007).
6. "How to invert mask?" has 10k views in the bug forum: a discoverability failure (N022).

## 6. What experts love

1. Speed of touch workflow with sticky buttons and gestures (N004).
2. Tool presets and community brush packs (N004, N022).
3. Tubes/lathe/repeaters/instances for procedural blockout (N004, N006).
4. Layers that survive remeshing (N017).
5. PBR vertex painting without UVs and the bake/reproject loop (N015, N007).
6. Customisable bottom bar and floating toolbars (N003).

## 7. Outdated or weak concepts

| Concept | Problem | Evidence |
|---|---|---|
| Visibility-chosen boolean op | Implicit state as a command parameter | N006 |
| Separate symmetry state per transform tool | Surprise when the gizmo ignores symmetry | N004, N016 |
| Save reminder instead of safe autosave | Data loss; modern apps snapshot incrementally | N005, N022 |
| Debug options exposed in the UI | Cognitive noise | N003 |
| Two curve systems | Duplicated concepts | N022 |

## 8. World-class concepts worth keeping

Zero-step start · sticky (tap latch / hold momentary) buttons · hold-Mask tap grammar · long-press for options · double-tap pivot · pivot dot · two-phase shape with green ✓ · contextual top toolbar · tools as presets with Save/Clone/Reset · searchable bindings for key/stylus/gamepad · floating toolbars · resolution checkerboard · tree-column drag selection · layers that survive topology change · memory-budgeted undo with view restore · stroke offset · accessibility window · clear export capability matrix.

## 9. The 40 categories at a glance

| # | Category | Nomad assessment | Evidence |
|---|---|---|---|
| 1 | Navigation | One finger on background orbits; two-down-lift-one when no background; double-tap pivot/frame | N012 |
| 2 | Camera | Turntable default, trackball roll, FOV, ortho snap with Shift or nav cube, named views with reference images, first person | N012, N011 |
| 3 | Input | Gestures assignable per finger/stylus/mouse; bindings for key/stylus/gamepad | N003 |
| 4 | Tablet | Pressure curves for radius and intensity; Wacom rocker mapping | N013, N002 |
| 5 | Touch | Best in class: sticky buttons, tap gestures, 2/3/4-finger taps, 3-finger drags, stroke offset | N003, N021 |
| 6 | Mouse | Alt-drag pan / Alt-release zoom; right-click on tools | N012, N004 |
| 7 | Brush system | ≈30 tools grouped by colour; each a saveable preset | N004 |
| 8 | Stroke engine | Dot/Roll/Lock+radius/Lock+intensity, Grab vs Drag, rope, smoothing, snap radius, randomise, offset | N013 |
| 9 | Sculpt workflow | Nine documented starting strategies (sphere+multires, dyntopo, voxel, multi-object, tubes, import, presets...) | N021 |
| 10 | Hard surface | Trim/Split with boolean fill, Planar, no low-poly modelling | N004, N022 |
| 11 | Organic | Clay/Brush/Move/Drag/Inflate/Crease with dyntopo or multires | N004 |
| 12 | Retopology | Quad Remesher (paid, not Android) or Instant quads; no manual retopo (top request) | N004, N007, N022 |
| 13 | Remeshing | Voxel remesher with checkerboard preview, build multires, keep sharp edges | N007 |
| 14 | Dynamic topology | Detail by screen/radius/constant; uniformise/subdivide/decimate; per-tool toggle icon | N007 |
| 15 | Voxels | Voxel remesh + triplanar voxel primitive (mask on 3 planes) | N006 |
| 16 | Layers | Sculpt + paint layers, channel factors, extract from layer, survive remesh | N017 |
| 17 | Hierarchy | Full tree with groups, parenting, instances, repeaters | N006 |
| 18 | Scene | Lights (4), cameras, background, reference images, post-process | N009, N011, N010 |
| 19 | Materials | Opaque/Subsurface/Blending/Additive/Refraction/Dithering/Shadow catcher; per-object Auto settings | N008 |
| 20 | Texturing | Textures only via import or bake; triplanar projection | N008, N007 |
| 21 | Painting | PBR vertex paint; paint while sculpting checkbox; Paint All | N015 |
| 22 | UV | UVAtlas / BFF auto unwrap; no editor | N007 |
| 23 | Masking | Mask/SelMask tools, top toolbar ops, hold-Mask taps, extract/split/carve from mask | N004 |
| 24 | Selections | Shape selection controls shared by 6 tools; auto-validate vs confirm | N004 |
| 25 | Polygroups | Face groups: dot paint, flood fill, relax borders; tap to mask/hide | N004, N021 |
| 26 | Visibility | Hide tool, solo, x-ray, lock | N004, N006 |
| 27 | Booleans | Voxel merge vs manifold boolean; op chosen by visibility | N006 |
| 28 | Gizmos | Full gizmo with pivot editing, snapping, numeric entry by tap | N004 |
| 29 | Transforms | Two-finger Transform tool; Insert tool | N004 |
| 30 | Rendering | Real-time PBR + post-process with progressive refine; render export | N010, N005 |
| 31 | Workspace | Single layout; collapsing menus; left-handed mirror | N002, N003 |
| 32 | Customisation | Bottom bar bindings, floating toolbars, UI scale, colours, transparency | N003 |
| 33 | Shortcuts | Searchable bindings with tap vs hold, sticky toggles | N003 |
| 34 | Context menus | Long-press on tools, tree items; "..." object menu | N004, N006 |
| 35 | Radial menus | None documented | – |
| 36 | Performance | Max verts 10M cap; low-res while orbiting; mobile thermal/memory limits documented | N018, N021 |
| 37 | Scripting | None (plugin API requested) | N022 |
| 38 | Plugins | Quad Remesher only | N004 |
| 39 | Automation | None beyond history replay (2.9) | N022 |
| 40 | Pipeline | glTF/OBJ/USD/PLY/STL/FBX; Link (Blender, ZBrush GoZ) in 2.9; Procreate round trip | N005, N022 |

## 10. Lessons for our app

1. Nomad is the right reference for *touch affordances* even though ZBrush for iPad is our behaviour model. Sticky buttons and hold-Mask taps are the cleanest touch translation of ZBrush's modifiers we found.
2. Copy the contextual top toolbar for tools that have a lifecycle (mask shapes, curve, insert, retopo).
3. Copy tools-as-presets (A-21) and searchable bindings (A-20).
4. Copy the resolution preview, pivot dot and double-tap pivot.
5. Avoid: implicit boolean ops, per-tool symmetry state, reminder-only saving.
