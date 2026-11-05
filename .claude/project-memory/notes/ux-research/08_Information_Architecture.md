# 08 · Information Architecture

How each product organises its features, why, and the IA this research recommends for our app. Constraint carried from Bolt's decisions: **one layout on every OS and device, touch-sized (48 pt) everywhere** (project memory, `sm-store`).

## 1. How the three products organise features

| | Organising principle | Top-level units | Strength | Cost | Evidence |
|---|---|---|---|---|---|
| ZBrush | **By subsystem** (palettes mirror internal data) | 24 palettes (Alpha … Zscript), "Tool" holds the model and most 3D features | Everything has exactly one home; docs mirror UI | Users must know the implementation to find a feature; "Tool" is overloaded | Z159, Z016, Z072 |
| ZBrush iPad | Subsystems + **toolbars by role** | Left = brush definition pipeline, right = view and object toggles, bottom = favourites and geometry ops, top = file/app | Brush pipeline as a vertical strip is readable | Palettes still behind one "Palettes" button | Z025-Z028 |
| Nomad | **By object of attention** | Scene menus top-left (Files, Scene, Topology, Material, Shading, Background, Camera), tool menus top-right (Stroke, Painting, Symmetry, Layers, Settings, Interface), toolbox right, quick controls left, display toggles bottom | Matches what the user is thinking about | Topology menu mixes five remeshing concepts | N001, N002 |
| 3DCoat | **By pipeline stage** (rooms) | 14 rooms, each with its own tools and menus; constant File/Edit/View/Windows | Focus per task | Data moves between rooms implicitly; mesh types tied to rooms | C053, C002, C003 |

**Lesson.** Organise by *what the user is attending to* (Nomad), keep a *visible brush pipeline* (ZBrush iPad), and give each *stage* a clear home without making it a separate room (3DCoat's lesson in reverse).

## 2. Our IA today

```
Viewport (full window)
├─ Top-left:   Menu (open, save, save as, import, export, screenshot, reduce motion, settings, stats) · Undo · Redo · History
├─ Top-middle: Tools (Move, Sculpt, Curve, Insert) · Symmetry X Y Z
├─ Top-right:  View menu (wireframe, flat, polygroups, studio, ortho, focus, reset) · Inspector button
├─ Left:       Size and Strength sliders
├─ Bottom:     Brush dock (7) + all-brushes grid · object name and vertex count
└─ Inspector (right, Tab)
   ├─ Tool:   Stroke · Colour · Falloff · Alpha · Pen · Options · Stroke recorder
   ├─ Object: Transform · Subdivision levels · HD detail · Dynamic topology · Mask · Hide, clip and slice ·
   │          Polypaint and polygroups · Morph target · Layers · Deformation · Remesh · Mirror and weld ·
   │          Retopology and baking · Project detail · Booleans · Extract          ← 18 sections, one scroll
   └─ Scene:  Objects · Add object · Material · Studio render · Camera
```

Problems (from 13 and 07): the Object tab is implementation-ordered and long (A-01); the four remesh-like operations (Remesh, Decimate, Retopo, Dyntopo) sit in four different sections; masking actions live in the inspector instead of near the stroke; no search; no home for help.

## 3. Recommended IA

Same screen regions (no layout change on any device), new homes for features:

```
Viewport (full window)
├─ Top-left:   App menu ▸ File (New ▸ starter scenes, Open, Save, Save a copy, Versions, Import, Export, Screenshot)
│              · Settings · Help & gestures · Stats  │  Undo · Redo (hold = repeat) · History
├─ Top-middle: Tools  Move · Sculpt · Curve · Insert   │  Symmetry X Y Z (long press: radial, mirror and weld)
├─ Top-right:  Search (command palette) · View menu · Inspector
├─ Left rail:  Size · Strength  │  Modifier buttons: Smooth · Invert · Mask · Hide  (tap = latch, hold = momentary)
├─ Above dock: Contextual action bar (appears only when something is active, see §4)
├─ Bottom:     Brush dock = user favourites (long press a slot to change it) + All brushes
│              · Object chip (name, vertices; tap = Object page, long press = object actions)
└─ Inspector (right)
   ├─ Brush    (was Tool)   Basics: Size, Strength, Stroke · Advanced: Falloff, Alpha, Pen, Filters, Paint channel, Presets
   ├─ Object   segmented:   Shape │ Select │ Surface │ Build
   │    Shape    Subdivision levels · HD detail · Dynamic topology · Rebuild (Even remesh, Fewer polygons, Quads) · Mirror and weld · Deform
   │    Select   Mask (ops, by cavity) · Groups (make, show, tap-to-isolate) · Hide · Saved selections
   │    Surface  Layers · Morph target · Paint (fill, colour) · Material
   │    Build    Booleans · Extract · Project detail · UVs and baking
   │    (Transform lives on the gizmo, with numeric entry on handle tap; the page keeps a compact copy)
   └─ Scene                Objects tree (groups, solo, ghost) · Add object · Lights and studio · Camera views and references
```

Why these four Object pages: they match the four questions an artist asks of a selected object — *what shape/topology is it* (Shape), *which part am I working on* (Select), *what is on its surface* (Surface), *what am I making from it* (Build). Every current Object section maps to exactly one page:

| Current section | New page | Note |
|---|---|---|
| Transform | Gizmo + Shape (compact) | numeric entry on handle tap (N004) |
| Subdivision levels, HD detail, Dynamic topology | Shape | stage 3 |
| Remesh (and Decimate), Retopology | Shape ▸ Rebuild | one panel, three goals: Even, Fewer, Quads; density preview |
| Mirror and weld, Deformation | Shape | |
| Mask, Hide clip and slice, Polypaint and polygroups (groups part) | Select | plus contextual bar |
| Layers, Morph target, Polypaint (paint part) | Surface | |
| Booleans, Extract, Project detail, Baking | Build | |

## 4. Contextual action bar (the IA's "now" layer)

A single floating bar above the dock shows the 3-6 actions that apply to what is active. It replaces trips to the inspector for the commonest follow-ups (pattern from Nomad's per-tool top toolbar, N004, and 3DCoat's contextual top bar, C002).

| Active state | Bar shows |
|---|---|
| Mask exists | Clear · Invert · Blur · Sharpen · Grow · Shrink · Extract · Make group |
| Something hidden | Show all · Invert hidden · Delete hidden |
| Shape drawn (mask/hide/clip/slice) and auto-confirm off | ✓ Apply · ✕ Cancel · Flip side |
| Curve in progress | ✓ Finish · Close loop · Undo point · Profile |
| Insert placed | ✓ · Duplicate · Snap to surface |
| Object rebuilt (remesh/decimate/retopo) | Adjust… (reopens parameters, adjust-last) · Undo |
| HD window open | Close window |
| Dyntopo on | Detail size · Off |

## 5. Command palette taxonomy

Search (top-right; Ctrl+K or `/` on desktop; one tap on touch) indexes four kinds, each result showing its shortcut and gesture:

1. **Commands** (every registry entry: "Invert mask", "Remesh selected", "Subdivide").
2. **Brushes and presets** ("Clay", "Clay – my soft").
3. **Settings** ("Orbit style", "Two-finger tap undo").
4. **Help topics** ("How to invert the mask" → shows the gesture and runs it).

Ranking: exact prefix > word prefix > fuzzy; recent and frequent first; synonyms table for cross-app vocabulary (DynaMesh → Remesh, Freeze → Mask, SubTool → Object, Polygroup → Group, ZRemesher → Quads). The synonym table directly addresses switching cost (N022 "ZBrush was hardcoded in my brain").

## 6. One concept, one name (glossary)

| We call it | Not | Means |
|---|---|---|
| Object | SubTool, layer (3DCoat tree), mesh | A thing in the scene tree |
| Group | Polygroup, face group, poly group | Per-face part ID on one object |
| Mask | Freeze | Per-vertex 0..1 protection |
| Hide | Visibility, ghost | Per-face not drawn and not sculpted |
| Ghost | X-ray | Object drawn faintly, not pickable |
| Layer | 3D layer, sculpt layer | Non-destructive delta (shape and later paint) |
| Level | SDiv, multires level | Subdivision level |
| Rebuild | DynaMesh, ZRemesher, voxel merge, decimate | Any topology-replacing operation |
| Brush | Tool (Nomad) | What the Sculpt tool applies |
| Preset | Brush file | A saved brush configuration |

The glossary lives in Help and in the palette synonyms.

## 7. Settings IA (extends today's four tabs)

Interface (size, motion, theme, left-handed, help hints) · Camera (orbit style, speeds, inversion, navigation preset) · Touch and pen (gestures on/off, gesture map, palm rules, stroke offset, finger pressure on Android) · Keys and buttons (bindings list with search, conflicts, reset) · Saving (autosave interval, versions kept, history in file) · Performance (stats, VSync, device profile, max vertices).
