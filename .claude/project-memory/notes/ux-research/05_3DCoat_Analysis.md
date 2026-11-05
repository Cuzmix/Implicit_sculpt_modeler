# 05 · 3DCoat Analysis

Built from 102 official pages (manual, library, FAQ, 2026 features post, licensing). IDs refer to `00_Sources.md`. One gap stands out: **the 3DCoat docs contain no touch or multitouch documentation at all**; pen support is described only through Windows tablet drivers (C031, C032).

## 1. The mental model 3DCoat teaches

3DCoat organises the whole product as **Rooms: "separate but connected mini-applications"**, one per pipeline stage (C053, C002): Sculpt, Paint, Tweak, UV, Retopology, Modeling, Render, Kitbash, Simplest, 3DPrint, Photogrammetry, Nurbs, Nodes, Factures, plus user-built rooms. Each room has its own left tool panel, menus and top bar; File/Edit/View/Curves/Windows/Scripts/Addons/Capture/Help stay constant.

Data model (C010, C012, C013, C040, C026, C034):

```
Scene
 ├─ Sculpt Tree (outliner): volumes/objects, nested; each row has V/S mode, resolution tag, eye, ghost, live-boolean op
 │   ├─ Voxel volume: 0..1 density grid, surface at iso 0.5, own density and resolution, colour, shader
 │   └─ Surface object: triangle skin with dynamic subdivision; multires levels; sculpt layers (surface only)
 ├─ Layers panel (scene-wide, Photoshop-like): colour, gloss/roughness, metalness, depth per layer, blend modes
 ├─ Paint objects (per-pixel / micro-vertex / Ptex / vertex / voxel modes), UV maps, UDIMs
 ├─ Retopo objects with Poly Groups (layers) — several versions can coexist
 ├─ Curves tree (curves, recorded strokes as data)
 └─ Masks: Freeze (surface/paint) ⇄ layer opacity ⇄ pose selection; voxel "masking" = Hide
```

**Why it is structured this way.** 3DCoat began as a voxel sculpting and texture painting tool and grew into an all-in-one pipeline (sculpt → retopo → UV → paint → render) (C052). Rooms keep each stage's dense tool set out of the others' way. The cost: data has to move between rooms (bake from Retopo to Paint, "Show voxels in the painting room"), and the rooms page does not explain how (C053).

## 2. Why artists use it

- **True volumetric sculpting**: no topology, punch holes, booleans with crisp edges, print-ready solids (C074, C016).
- **Retopology and UV rooms** that are genuinely complete (auto + manual) (C034, C035, C036, C037).
- **Texture painting depth**: smart materials, conditions (cavity, convex, top...), 5 paint modes, PBR channels in one stroke, Photoshop link (C041, C023, C042, C039).
- **Desktop configurability**: END to bind anything, stacked/sticky keys, navigation presets, rooms and menu scripts, Python and C++ Core API (C004, C005, C029, C049).
- **Perpetual licence / rent-to-own** (C062).

## 3. What makes it fast (world-class)

| Pattern | How it works | Evidence |
|---|---|---|
| **One gesture grammar everywhere** | LMB acts; RMB drag horizontally = size, vertically = depth (also scales/sinks placed primitives); Shift smooths; Ctrl inverts; Alt navigates when the tool owns LMB; Enter commits; Esc cancels. | C020, C081, C069 |
| **END to bind anything** | Hover any item, press END, press a key; reassign or *stack* (repeat press cycles tools) or *sticky* (hold = temporary tool). | C004 |
| **Space quick access with search** | Context-sensitive per room; type to filter; slots 1-9 filled by dragging; radial pie in Paint. Ctrl+F searches any UI item in the room. | C008, C073 |
| **E stroke-mode panel** | 20 drawing modes (pressure variants, lines, curves, stamps, lassos, shapes, splines) in one popup, shared by sculpt, paint, freeze, cut. | C021 |
| **Brushes as modifier stacks** | Smooth, Smudge, Pinch, Rotate, Side shift, Angulator blocks; duplicate any built-in brush and edit. | C019, C047 |
| **Navigation presets** | 3DCoat, Maya, ZBrush styles; full remap; modifier+wheel bound to any parameter. | C005, C030 |
| **Sculpt Tree drag with modifiers = booleans** | Shift-drag merge, Ctrl-drag subtract, Ctrl+Shift intersect, Shift+Alt split, Alt duplicate. | C045 |
| **Ghost mode** | Half-transparent, unpickable, protected objects still give context. | C010 |
| **Masks are interconvertible** | Freeze ⇄ layer opacity ⇄ pose selection; store/restore to disk. | C026, C071 |
| **Task-first Quick Start** | Launcher with 15 task entries (voxel sculpt, surface sculpt, vertex paint, retopo, UV, print, prototype...). | C063 |
| **Curated rooms for beginners** | Simplest room; free 3DCoatPrint with the same sculpt core. | C056, C065 |
| **Command discovery for scripting** | RMB+MMB over any command copies its script call. CLI `-script` for headless batch. | C029, C050 |

## 4. What causes friction (docs' own admissions)

| Friction | Evidence |
|---|---|
| Voxel ⇄ surface switch nullifies sculpt layers; surface freeze is lost when switching back to a voxel tool; voxel masking uses Hide because Freeze is surface-only. | C011, C075, C079 |
| Voxels can't be thin (jaggies), have no normals (faceting), can't take open meshes; density vs resolution is "trial and error". | C074, C012, C018 |
| Several mesh types, each native to one room (Paint object, Sculpt object, Retopo object); UV room works only on Paint objects. | C003, C037 |
| Rooms page doesn't explain how data moves between rooms. | C053 |
| Hotkey docs conflict (Ctrl+X = Cut and Unhide all; NUM+/- with and without Ctrl). | C004, C072 |
| Some merges and deletes are not undoable (Merge Down/Up, Delete Hidden Faces, Clear caches). | C040, C072, C046 |
| Saves complete in the background 10-30 s after they look finished; reboot can destroy the scene. | C059 |
| Customising menus means editing `menu.cpp`; no dual-monitor support; panels reset. | C008, C029, C002 |
| Overloaded RMB (short click = menu, long click = pick plane, hold = slide). | C069 |
| Conditions limiter keeps limiting strokes until reset to Always/None. | C020, C023 |
| Spacebar menu: cursor lands in search, so number hotkeys type into search. | C008 |
| Pen troubleshooting: switch Wintab/Windows Ink, rename the user folder, copy assets back. | C032, C059 |
| Training videos span 2012-2022 UIs; no official beginner order. | C060 |
| Hover-to-open Activity Bar has no touch equivalent. | C033 |

## 5. What beginners struggle with

1. Choosing a room, a mesh type and a paint mode before doing anything (C003, C042, C063).
2. Voxel vs surface: when to switch and what is lost (C011, C075).
3. Density/resolution (C018).
4. Masks with three names and three behaviours (Freeze, Hide, Pose selection) (C026, C079).
5. The sheer number of panels (≈50 window types) (C073).
6. Outdated videos (C060).

## 6. What experts love

1. Voxels + live booleans in a tree + soft booleans for hard/organic mixes (C016).
2. END-to-bind with stacked/sticky keys (C004).
3. E-panel stroke modes and conditions for surgical control (C021, C023).
4. Full retopo and UV rooms; Autopo with guides (C035, C036, C037).
5. Smart materials and node texturing (C041, C066).
6. Python + C++ Core API with CLI batch (C049, C050).

## 7. Outdated concepts

| Concept | Problem | Evidence |
|---|---|---|
| Rooms as separate apps with separate mesh types | Pipeline friction; data-moving is implicit | C053, C003 |
| Menu customisation by editing script files | Desktop-only, error-prone | C029 |
| AngelScript (deprecated, no Apple Silicon) | Legacy | C049 |
| Wintab/Ink driver troubleshooting as normal workflow | Platform debt | C032 |
| Hover-only activity bar | Not touch-capable | C033 |
| Non-undoable merges | Modern apps make all edits undoable | C040 |

## 8. World-class concepts worth keeping

One gesture grammar across tools · RMB-drag size/depth · END bind with stacked and sticky keys · searchable Space menu with numbered slots · E stroke-mode popup · brush modifier stacks · navigation presets · tree drag-with-modifier booleans · ghost objects · interconvertible masks · task-first launcher · curated beginner room · voxel/surface hybrid per object · smart materials with conditions · CLI scripting and command-name discovery.

## 9. The 40 categories at a glance

| # | Category | 3DCoat assessment | Evidence |
|---|---|---|---|
| 1 | Navigation | LMB empty orbit, RMB zoom, MMB pan, Alt+button anywhere; nav zones; nav panel widgets | C005, C007 |
| 2 | Camera | FOV guidance, pivot F, look along normal, camera shortcuts store grid/stamp too, reference images per axis | C005, C007 |
| 3 | Input | Universal LMB/RMB/Shift/Ctrl/Alt/Enter/Esc grammar | C020 |
| 4 | Tablet | Pen/mouse response toggles per parameter; pressure curves; tapering; Wintab vs Ink | C025, C031 |
| 5 | Touch | Not documented | – |
| 6 | Mouse | Strongest desktop mouse model; wheel+modifiers mappable | C030 |
| 7 | Brush system | 100+ brushes, presets, modifier stacks, clay engine | C015, C019, C047 |
| 8 | Stroke engine | 20 E-panel modes; steady stroke; dabs/spacing; jitter | C021, C022 |
| 9 | Sculpt workflow | Voxels low-res → Res+ → surface → retopo | C009 |
| 10 | Hard surface | Modeling room, voxel booleans, cut off, sculpt bevel, soft booleans | C054, C079, C080 |
| 11 | Organic | Voxel clay, surface brushes, Remove Stretching + Auto-Subdivide | C014, C015 |
| 12 | Retopology | Autopo (3 engines, guides, density) + full manual room | C035, C036 |
| 13 | Remeshing | Enter = temporary voxelize+remesh; Resample; screen-space subdivide | C013, C046 |
| 14 | Dynamic topology | Remove Stretching / Auto-Subdivide (replaced Live Clay 2022) | C013 |
| 15 | Voxels | True volume, density/resolution per volume, clay engine | C074, C018, C047 |
| 16 | Layers | Scene-wide PS-style layers with depth; sculpt layers surface only | C040, C011 |
| 17 | Hierarchy | Sculpt Tree with nesting, ghost, V/S, live booleans | C010 |
| 18 | Scene | Rooms share scene; kitbash joints; scale master | C087, C092 |
| 19 | Materials | PBR shaders recommended over MatCaps; GGX variants | C007, C088 |
| 20 | Texturing | Per-pixel, micro-vertex, Ptex, vertex, voxel; smart materials; nodes | C042, C041, C066 |
| 21 | Painting | Paint room tools, conditions, stencils, PS link | C099, C023 |
| 22 | UV | UV room, LSCM/ABF/GU, live distortion, UDIMs | C037 |
| 23 | Masking | Freeze (surface/paint), Hide (voxels) | C026, C079 |
| 24 | Selections | Pose selection modes (line/ring/sphere/paint), save/load | C071 |
| 25 | Polygroups | Retopo poly groups as layers | C085 |
| 26 | Visibility | Hide menu, ghosting, isolate | C072, C046 |
| 27 | Booleans | Live booleans (voxel), soft booleans, tree drag | C016, C045 |
| 28 | Gizmos | Transform gizmo, pose gizmo, primitives lattice | C044, C071, C081 |
| 29 | Transforms | Modal W/E/R + axis keys like Blender | C092 |
| 30 | Rendering | Render room, turntables, passes | C055 |
| 31 | Workspace | Rooms, dockable windows, store layouts | C028, C073 |
| 32 | Customisation | Customize UI checkboxes, menu scripts, custom rooms, themes | C028, C029, C030 |
| 33 | Shortcuts | END bind, stacked/sticky, Hotkeys Manager | C004 |
| 34 | Context menus | RMB menus everywhere (tree, viewport, curves) | C045, C101 |
| 35 | Radial menus | Paint room pie on Space | C099 |
| 36 | Performance | Voxel memory, GPU quad reduction while brushing, multi-core | C030, C059 |
| 37 | Scripting | Python, C++ Core API, (AngelScript deprecated) | C049, C050, C051 |
| 38 | Plugins | Extensions/addons, .3dcpack packages | C083 |
| 39 | Automation | Script recorder, retopo record, CLI `-script` | C034, C050 |
| 40 | Pipeline | Applinks, PS/Krita, export presets per engine, StemCell validation | C039, C067, C048 |

## 10. Lessons for our app

1. 3DCoat is the reference for *desktop configurability* and a *uniform gesture grammar*. Copy END-style "press a key while hovering to bind it" (A-20) and RMB-drag size/depth as a desktop alternative to our three-finger gesture.
2. Copy the voxel/surface hybrid idea at the level we can afford: our SDF spike (`src/sdf_trial`) plus voxel remesh already sit close to "volume mode" for blockout.
3. Copy ghost objects, tree drag-with-modifier booleans, interconvertible masks.
4. Do not copy rooms or per-room mesh types. Use contextual panels inside one workspace instead (see 08, 10).
