# 03 · ZBrush Analysis (desktop 2026-2027 and ZBrush for iPad)

Built from 162 official pages (maxon.net feature pages, desktop online help read via `.html.md`, ZBrush for iPad help). IDs refer to `00_Sources.md`. ZBrush for iPad matters doubly: it is the model Bolt chose for our touch and camera behaviour (PR #49).

## 1. The mental model ZBrush teaches

ZBrush's documentation explains its UI as **a set of named palettes mirroring the internal data** (Z016, Z159). The Reference Guide is literally organised palette by palette (Alpha, Brush, Color, Document, Draw, Edit, File, Light, Macro, Marker, Material, Movie, Picker, Preferences, Render, Stencil, Stroke, Texture, Tool, Transform, Zplugin, Zscript). "Tool" is both the 3D model and its giant settings palette.

The data model behind it (Z057, Z059, Z062, Z089, Z097):

```
Project (.ZPR) ── camera, canvas, undo history per SubTool
 └─ Tool (.ZTL) = ordered list of SubTools (≈1000 max), one folder level (100 per folder)
     └─ SubTool
         ├─ subdivision stack (Catmull-Clark, N+1 levels) + optional HD level (≈1B polys, windowed)
         ├─ per-vertex: mask 0..1, colour (polypaint), material index
         ├─ per-face: polygroup ID (stored at base level), hidden flag
         ├─ 3D layers (displacement + colour + mask deltas, order matters)
         ├─ one morph target (tied to level)
         ├─ selection sets (named masks / groups / paint / UVs / morphs; break on remesh)
         └─ undo history (per SubTool, saved only in ZPR)
```

**Why it is structured this way.** ZBrush began as a 2.5D "pixol" painting app (Z107, Z108). Its palettes, canvas document and "drop to canvas" behaviour are inheritances from that design. 3D sculpting was layered on top as "Edit mode", and every later feature (DynaMesh, ZRemesher, Live Boolean, Gizmo 3D, Sculptris Pro, Selection Sets) was added as another palette section or modifier rather than as a redesign. Maxon calls the menus "circular, non-linear and mode-free" (Z136); the docs then document several modes that trip users (Z107, Z069, Z077).

## 2. Why artists use it

- **Raw sculpt capacity on CPU.** Tens of millions of polys without a strong GPU; HD geometry to a billion (Z001, Z060). Desktop "3D display is CPU-based" (Z080).
- **Depth of brush behaviour.** 200-500+ brushes, per-brush modifiers, alphas, strokes, curve mode, IMM, VDM, cloth, history brushes (Z004, Z084, Z139).
- **A complete organic pipeline in one app**: DynaMesh → ZRemesher → subdivision levels → layers → polypaint → UV Master → maps → GoZ (Z075, Z078, Z059, Z102, Z103).
- **Muscle memory.** The forum thread "How to make Nomad feel like ZBrush" says "ZBrush was hardcoded in my brain" (N022). Switching cost is ZBrush's moat.

## 3. What makes it fast (world-class)

| Pattern | How it works | Evidence |
|---|---|---|
| **Modifier quasi-modes on one brush** | Ctrl = mask, Shift = smooth, Ctrl+Shift = select/hide, Alt = invert. The artist never picks a different tool for the four most common secondary actions. Shift's smooth brush keeps its own settings. | Z019, Z121 |
| **"Where the gesture starts" semantics** | Same key, different result on model vs empty canvas: Ctrl+drag on model paints mask, off model draws a mask rectangle, on background clears; Ctrl+drag background also re-DynaMeshes. | Z061, Z075 |
| **Navigation never needs a tool change** | Drag empty canvas to orbit; Alt to pan; right-drag navigation option. | Z018 |
| **Inline commit gestures** | Hold Ctrl+Shift, draw, release keys keeping pressure, hold Space to move the shape, Alt before lift flips to hide: one continuous gesture. | Z063, Z041 |
| **Click-to-place gizmo** | Short click on any surface moves the gizmo there and orients it to the face. | Z066 |
| **Subdivision propagation** | Big edits at low level, detail survives at high levels. | Z059 |
| **History as a resource** | Undo markers feed Morph/History Recall brushes, Project History restores detail after remesh, Mask/Group Changed Points selects the last strokes. | Z117, Z140, Z137, Z138 |
| **Adjust Last** | Scale the last stroke's intensity after the fact. | Z123 |
| **Customise anything in place** | Ctrl+Alt+click any button to bind a key; Ctrl+Alt+drag any button into a custom menu. | Z071, Z073 |
| **iPad: modifier wheel** | Desktop modifiers as a hold-and-slide wheel for the off hand, with colour-coded cursor showing the active mode. | Z023 |
| **iPad: long-press directory** | One consistent secondary gesture: long press = options / favourites / scrub value / object actions. | Z032 |
| **iPad: quick search** | Search across palettes, menus, subtools; picks become session shortcuts. | Z033 |

## 4. What causes friction (with the docs' own admissions)

| Friction | Evidence |
|---|---|
| Drawing a primitive without pressing T "drops" it to 2.5D pixols; it can never be sculpted again. Documented as a pitfall. | Z107 |
| Three file concepts (ZBR document, ZTL tool, ZPR project); undo history only in ZPR. | Z109, Z096 |
| Preferences and UI layout do not save automatically; Store Config required. Removing a custom menu requires restarting without saving. | Z072, Z073, Z108 |
| The same Ctrl+Shift+click gives different results depending on current visibility. | Z063 |
| D / Shift+D mean different things depending on whether the mesh has classic or dynamic levels. | Z069 |
| Mid-drag modifier release chords (Alt-click-release-drag = zoom; Shift-click-release = roll). | Z018, Z019 |
| Modifier timing changes meaning (ZModeler: Alt before click vs after). | Z141 |
| Polygroups must be created at the lowest level; layers at the top level; adding levels transfers layers one way. | Z049, Z089 |
| DynaMesh, ZRemesher and Sculptris Pro break Selection Sets; Merge SubTools clears all history. | Z097, Z096 |
| Cannot sculpt or pose several SubTools at once; posing needs the Transpose Master plugin. | Z057, Z104 |
| Many SubTool folder operations cannot be undone; folders cannot nest. | Z058 |
| Live Boolean result depends on list order; subtractors are hidden; duplicating resets the mode. | Z051 |
| Primitives are parametric generators that cannot be sculpted until Make PolyMesh3D; the state is invisible. | Z161 |
| The 2027 UV Editor embeds Cinema 4D conventions (right-drag rotate, W/E/R mean different things) and locks ZBrush while open. | Z098 |
| Docs disagree with themselves (F-key popup order, DynaMesh cube size, touch strength mode). | Z070, Z076, Z022 |
| Desktop/iPad parity "closing", not closed: iPad lacks plug-ins, UV editor, selection sets; free tier lacks quick menu and custom toolbars. | Z017, Z149 |
| iPad: three-finger gestures collide with iPadOS Zoom; pinch rolls by default; orbit needs empty space. | Z021, Z038 |
| iPad: ZModeler targeting depends on hover previews many touch screens lack. | Z130, Z153 |
| iPad: second tap on Save silently overwrites; bottom bar mixes "tap runs" and "tap opens settings". | Z027, Z028 |

## 5. What beginners struggle with

1. The canvas/Edit-mode trap and drop-to-canvas (Z107).
2. Finding anything in 24 palettes of nested sub-palettes; one open sub-palette at a time by default (Z072, Z159).
3. Invisible state: polymesh vs parametric, Zadd/Rgb channel toggles, which smooth brush is bound to Shift (Z161, Z091, Z121).
4. Navigation needs empty canvas; zoomed in, you drag outside a thin white border line (Z019).
5. Brush picking by 3-key chords (B, S, T) (Z070).
6. Three file types and manual saving discipline ("save incrementally about every hour, keep 3+ versions; files can corrupt") (Z109).

## 6. What experts love

1. Every secondary action is a modifier away (Z019).
2. Gestures that encode their own target (start on model vs off model) (Z061).
3. Ctrl+Alt binding and custom menus built from any button (Z071, Z073).
4. Subdivision levels + HD + layers + morph + history projection: non-linear, recoverable detail work (Z059, Z060, Z089, Z117).
5. Gizmo 3D + deformers + topological masking for posing and blockout (Z066, Z067, Z115).
6. CPU-bound engine that runs on any machine (Z001).

## 7. Outdated concepts

| Concept | Why it is outdated | Evidence |
|---|---|---|
| 2.5D pixol canvas as the root document | Exists for legacy illustration; its traps cost beginners their first model | Z107, Z118 |
| Palette-per-subsystem IA ("Tool" palette with everything) | Navigation by implementation, not by task | Z159 |
| Manual Store Config, no autosave of preferences | Every modern app autosaves settings | Z072 |
| Hotkey files in public folders, restore unavailable after Store | Fragile | Z071 |
| ZScript with strict folder/name rules for macros; Python only mentioned on marketing | Two scripting stories, thin docs | Z105, Z106, Z015 |
| Mid-drag modifier-release chords | Undiscoverable, impossible on touch | Z018 |
| One morph target per SubTool | Layers do this better | Z090 |
| Plugins for core operations (Transpose Master, Decimation Master preprocess) | Workarounds for missing multi-object editing | Z104, Z101 |

## 8. World-class concepts worth keeping

Modifier quasi-modes · start-location semantics · click-to-place gizmo · subdivision propagation · HD regional windows · history markers feeding brushes · Adjust Last · Ctrl+Alt bind-anything · iPad modifier wheel with colour-coded cursor · long-press directory · quick search · silhouette thumbnail · CamView · camera undo stack · Lock Camera · per-brush Shift-smooth settings · ZRemesher guides and density paint · Live Boolean preview while sculpting.

## 9. The 40 categories at a glance

| # | Category | ZBrush assessment | Evidence |
|---|---|---|---|
| 1 | Navigation | Drag empty canvas; Alt pan; Alt-release zoom; optional right-drag; fails when zoomed in | Z018, Z019 |
| 2 | Camera | Universal camera (focal length, auto-crop), stored cameras, separate 14-step camera undo, Lock Camera | Z110 |
| 3 | Input | Modifier-overloaded (~200 bindings); Ctrl+hover help | Z070 |
| 4 | Tablet | "Strongly recommended"; pressure attributes; Pencil roll/double-tap on iPad | Z001, Z029, Z030 |
| 5 | Touch | iPad: finger on model sculpts, empty canvas orbits, 3-finger size/focal, assignable taps, modifier wheel | Z021, Z022, Z023 |
| 6 | Mouse | Desktop: classic or right-click navigation; iPad mouse single-click only, no right-click nav | Z018, Z036 |
| 7 | Brush system | 200-500+ brushes, modifiers, chords B+letters, brush presets | Z084, Z070 |
| 8 | Stroke engine | Dots, FreeHand, DragRect, DragDot, Spray, Roll, LazyStep, Lazy Mouse 2.0, curve mode, replay | Z087, Z085, Z139 |
| 9 | Sculpt workflow | DynaMesh → ZRemesher → levels → HD | Z043, Z052, Z060 |
| 10 | Hard surface | ZModeler, dynamic subdivision, clip/trim/bevel brushes, deformers | Z082, Z068, Z143 |
| 11 | Organic | Clay/standard/move/snakehook + DynaMesh/Sculptris Pro | Z084 |
| 12 | Retopology | ZRemesher (guides, adaptive size, polypaint density), topology brush, ZSphere retopo | Z078, Z127, Z128 |
| 13 | Remeshing | DynaMesh (resolution cube, incremental), Remesh All with add/sub/intersect | Z076, Z126 |
| 14 | Dynamic topology | Sculptris Pro: brush size = triangle size; cursor colour shows compatibility | Z077 |
| 15 | Voxels | Only as DynaMesh remesh, not a volume | Z075 |
| 16 | Layers | 3D layers with REC, strength, bake; level constraints | Z089 |
| 17 | Hierarchy | Ordered SubTools + one folder level | Z057, Z058 |
| 18 | Scene | Project = tools + camera + canvas; Stager for home/target | Z109, Z113 |
| 19 | Materials | MatCap, LightCap, standard materials; per-vertex material channel | Z093, Z094, Z119 |
| 20 | Texturing | Polypaint → texture; SpotLight projection; Substance bridge | Z010, Z012, Z014 |
| 21 | Painting | Same brush with Zadd off, Rgb on (channel toggles) | Z091 |
| 22 | UV | UV Master one-click; 2027 UV editor (C4D conventions) | Z102, Z098 |
| 23 | Masking | Graded, Ctrl grammar, mask by cavity/topology/region, mask changed points | Z061, Z114, Z138 |
| 24 | Selections | Ctrl+Shift select brushes (green show / red hide), selection sets | Z063, Z097 |
| 25 | Polygroups | Per-face IDs at base level; isolate by Ctrl+Shift click; group masked Ctrl+W | Z062, Z049 |
| 26 | Visibility | Per-face hidden flag; grow/shrink visible; Solo | Z063 |
| 27 | Booleans | Live Boolean preview, Make Boolean Mesh, order-dependent | Z154, Z081 |
| 28 | Gizmos | Gizmo 3D (move/scale/rotate, deformers, operators), Transpose line | Z066, Z067, Z116 |
| 29 | Transforms | Q/W/E/R, multi-SubTool transform toggle | Z160 |
| 30 | Rendering | BPR, NPR, Redshift, KeyShot | Z095 |
| 31 | Workspace | Trays, shelves, palettes; stored config | Z072 |
| 32 | Customisation | Custom UI by Ctrl+Alt drag; custom menus; iPad custom toolbars/quick menus | Z073, Z039, Z134 |
| 33 | Shortcuts | Ctrl+Alt+click bind; iPad conflict detection, swipe delete, autosave | Z071, Z152 |
| 34 | Context menus | Space/right-click QuickMenu; ZModeler hover popup | Z070, Z082 |
| 35 | Radial menus | Modifier wheel (iPad) | Z023 |
| 36 | Performance | CPU display; Live Boolean preview slows; 60M boolean needs 24 GB | Z080 |
| 37 | Scripting | ZScript; Python announced | Z105, Z015 |
| 38 | Plugins | Zplugin palette (Decimation/UV/Transpose Master, 3D Print Hub) | Z101, Z102, Z104 |
| 39 | Automation | Macros (record everything), Apply Last Action, Repeat to Similar | Z106, Z005 |
| 40 | Pipeline | GoZ, Substance bridge, maps export, 3D print exporter | Z103, Z014, Z146 |

## 10. Lessons for our app

1. Keep the ZBrush grammar for desktop (we already copy the camera and touch model), but make every modifier visible on touch as a Nomad-style hold/latch button or a ZBrush-style wheel (A-12).
2. Never ship modal traps like drop-to-canvas. Our "Validate" moments (remesh, booleans, retopo) must stay undoable (we already put rebuilds in `History` swap entries).
3. Copy the iPad long-press directory as a rule: every control's secondary action is long press (and right-click on desktop).
4. Copy quick search as a command palette over a command registry (A-20).
5. Copy history-as-resource: markers, local undo brush, Adjust Last.
6. Do not copy the palette IA or the level-placement constraints (polygroups at base, layers at top).
