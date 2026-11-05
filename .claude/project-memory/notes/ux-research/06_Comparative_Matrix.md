# 06 · Comparative Matrix

Scores are 1 (poor) to 10 (best in class) and are judgements built from the documentation, not user testing. Each score has a one-line justification with evidence IDs from `00_Sources.md`. Our app is scored too, against the same bar, so the gaps feed the roadmap (12).

ZBrush is scored on desktop unless the line says iPad. "Touch friendliness" for ZBrush means ZBrush for iPad.

## Scorecard

| Criterion | ZBrush | Nomad | 3DCoat | Us (today) |
|---|---|---|---|---|
| Discoverability | 3 | 6 | 4 | 4 |
| Learnability | 3 | 8 | 4 | 6 |
| Expert efficiency | 10 | 7 | 8 | 6 |
| UI consistency | 4 | 7 | 5 | 8 |
| Workflow consistency | 5 | 6 | 4 | 6 |
| Cognitive load (10 = lowest load) | 2 | 7 | 3 | 6 |
| Touch friendliness | 7 (iPad) | 9 | 1 | 7 |
| Desktop friendliness | 9 | 6 | 9 | 6 |
| Customisability | 9 | 7 | 9 | 2 |
| Scalability (scene size, project complexity) | 9 | 5 | 7 | 7 |
| Performance | 9 | 6 | 6 | 9 |
| Feature depth | 10 | 6 | 9 | 6 |
| Onboarding | 4 | 7 | 6 | 3 |
| Documentation quality | 6 | 5 | 5 | 4 |
| **Average** | **6.4** | **6.6** | **5.7** | **5.7** |

## Justifications

### Discoverability
- **ZBrush 3.** 24 palettes of nested sub-palettes with one open at a time (Z072, Z159); core actions are modifier+location gestures (Z061); Ctrl+hover help exists but is itself hidden (Z070). iPad adds quick search, hover tooltips and a long-press directory (Z033, Z031, Z032), which is why it is not lower.
- **Nomad 6.** Small toolbox with colour categories, visible sticky buttons (N004); but key gestures are hidden (two-down-lift-one orbit, four-finger tap, hold-Mask taps) and "How to invert mask?" has 10k views (N012, N021, N022).
- **3DCoat 4.** Searchable Space menu and Ctrl+F UI search help (C008, C073); undermined by 14 rooms, ≈50 panels, hover-only activity bar and conflicting hotkey docs (C053, C073, C033, C004).
- **Us 4.** Tooltips on undo/redo and labelled controls; but no search, no shortcut hints, 18-section Object tab, help only in the README (13: A-01, A-07).

### Learnability
- **ZBrush 3.** Canvas/Edit-mode trap, three file types, mode-dependent keys, level-placement rules (Z107, Z109, Z069, Z049).
- **Nomad 8.** Zero-step start, symmetry on, Sub/Smooth toggles explained on the first page (N002); docs lean on community videos (N001).
- **3DCoat 4.** Task-first Quick Start and Simplest room help (C063, C056); voxel vs surface, mesh types per room and paint modes must be understood early (C003, C042, C011).
- **Us 6.** Opens on a sphere, large labelled touch targets, plain-words stats; no onboarding and many features only discoverable from the README.

### Expert efficiency
- **ZBrush 10.** Modifier quasi-modes, start-location semantics, bind-anything, history markers, Adjust Last (Z019, Z061, Z071, Z117, Z123).
- **Nomad 7.** Sticky buttons, presets, bindings and floating toolbars (N004, N003); fewer power operations (no deformers until 2.9, no scripting).
- **3DCoat 8.** END bind with stacked/sticky keys, E-panel, RMB size/depth grammar, scripting (C004, C021, C020, C049); slowed by room switching.
- **Us 6.** ZBrush mouse/touch grammar, brush pie, stroke recorder; no rebinding, no custom toolbars, no command search, several tools need inspector trips.

### UI consistency
- **ZBrush 4.** Same click means different things by state (Z063); iPad bottom bar mixes tap-runs and tap-opens-settings (Z028); UV Editor imports C4D conventions (Z098).
- **Nomad 7.** Long-press/swipe-for-options and tap/hold sticky buttons applied uniformly (N002, N004); exceptions: per-tool symmetry, visibility-chosen booleans (N004, N006).
- **3DCoat 5.** Uniform LMB/RMB/Shift/Ctrl grammar (C020); but rooms differ in menus and panels, RMB overloaded (C069).
- **Us 8.** One token set, one control kit, 48 pt targets everywhere, same layout on every device (sculpt-new-ui, README "Interface").

### Workflow consistency
- **ZBrush 5.** Stage model is clear (DynaMesh → ZRemesher → levels) but each stage has its own constraints and breaks (selection sets break, history clears) (Z097, Z096).
- **Nomad 6.** Nine documented ways to start a model, several remeshers with overlapping roles (N021, N007).
- **3DCoat 4.** Room hops and mesh-type conversions at every stage boundary; layers and freeze lost on voxel/surface switches (C053, C075).
- **Us 6.** All operations undoable via History swaps; but stages are scattered across Object sections with no guided transition.

### Cognitive load (higher score = lower load)
- **ZBrush 2.** ≈200 bindings, invisible state (Zadd/Rgb/M, polymesh/parametric), palette depth (Z070, Z091, Z161).
- **Nomad 7.** Small surface; load rises in Stroke settings (five sub-menus) and Topology (N013, N007).
- **3DCoat 3.** Rooms × mesh types × paint modes × voxel/surface (C003, C042, C012).
- **Us 6.** Clean floating chrome, but the Object tab exposes every geometry feature at once.

### Touch friendliness
- **ZBrush iPad 7.** Modifier wheel, long press, quick search, assignable taps (Z023, Z032, Z033, Z022); ZModeler needs hover; 3-finger gesture conflicts; orbit needs empty space (Z130, Z038, Z021).
- **Nomad 9.** The best touch model found: sticky buttons, hold-Mask taps, double-tap pivot, stroke offset, accessibility window (N004, N012, N013, N003). Palm issues keep it from 10 (N022).
- **3DCoat 1.** No touch documentation; hover activity bar; RMB-based grammar (C033, C020).
- **Us 7.** ZBrush-for-iPad routing, one owner per touch, 3-finger size/strength, 2/3-finger undo/redo, 48 pt targets (PR #49). Missing touch modifiers, long-press convention and double-tap pivot; untested on a real tablet.

### Desktop friendliness
- **ZBrush 9.** Built for keyboard + tablet; right-click navigation option (Z018).
- **Nomad 6.** Desktop reuses the tablet layout; Alt-based navigation; bindings help (N012, N003).
- **3DCoat 9.** Navigation presets, wheel+modifier mapping, modal transforms, END bind (C005, C030, C092, C004).
- **Us 6.** ZBrush mouse map, keypad views, F12, Ctrl+S/O; but touch-sized layout on desktop (a deliberate choice) and no rebinding.

### Customisability
- **ZBrush 9.** Custom UI from any button, custom menus, hotkeys, macros, iPad toolbars/quick menus (Z073, Z071, Z106, Z039).
- **Nomad 7.** Bottom bar and floating toolbars, gestures, bindings, UI scale/colours (N003); no scripting.
- **3DCoat 9.** END bind, Customize UI, menu scripts, custom rooms, themes, navigation remap (C004, C028, C029, C005).
- **Us 2.** Settings panel only (interface size, camera, touch gestures, performance).

### Scalability
- **ZBrush 9.** ≈1000 SubTools, HD to a billion polys (Z058, Z060); folders don't nest (Z058).
- **Nomad 5.** Mobile RAM limits (≈1-8M polys comfortable), 4 lights, 10M default cap (N021, N018).
- **3DCoat 7.** Deep tree, voxel memory cost, 16k textures (C010, C052).
- **Us 7.** 10M at under 2 ms, 20-50M with grouped culling, HD windows; flat object list.

### Performance
- **ZBrush 9.** CPU engine with tens of millions of polys on modest hardware (Z001); Live Boolean preview slows display (Z080).
- **Nomad 6.** Good on iPad, "an order of magnitude slower" on Android tablets; thermal limits (N020, N021).
- **3DCoat 6.** Voxel memory/CPU heavy; GPU quad reduction while brushing; saves lag (C013, C030, C059).
- **Us 9.** <1 ms GPU at 10M on an RTX 3060 Ti, 1.4 ms CPU stroke at 10M, ~4 ms pointer-to-screen (project memory). Android unmeasured.

### Feature depth
- **ZBrush 10.** Broadest sculpt toolset found (Z004-Z015, Z016 TOC).
- **Nomad 6.** Solid core, missing manual retopo, low-poly, scripting (N022).
- **3DCoat 9.** Sculpt + retopo + UV + paint + nodes + render (C052).
- **Us 6.** Surprisingly broad for its age (levels, HD, dyntopo, remesh, retopo, bake, booleans, layers, paint, cloth, curves), but shallow per area (14 brushes, move-only gizmo, auto-only retopo).

### Onboarding
- **ZBrush 4.** Home/LightBox starters and Pro Projects (Z131, Z112), but the first-run trap (Z107).
- **Nomad 7.** Sphere ready, presets, tips page with nine starting strategies (N002, N021).
- **3DCoat 6.** Quick Start dialog, interactive tutorials and missions, Simplest room (C063, C056).
- **Us 3.** Sphere ready; nothing else.

### Documentation quality
- **ZBrush 6.** Deep, structured by palette, cheat sheet; inconsistencies; desktop help needs JS; Python undocumented (Z016, Z019, Z070).
- **Nomad 5.** Clear, flat, but lags the app, has typos, defers to videos (N001, N022).
- **3DCoat 5.** Broad sitemap and AI chat; conflicting hotkeys, headings without content, old videos (C001, C004, C084, C060).
- **Us 4.** One long README that is accurate and current, plus agent skills; no user-facing help in the app.

## Where each product wins

| Criterion | Winner | What to borrow |
|---|---|---|
| Discoverability | Nomad / ZBrush iPad | Visible sticky buttons + quick search + long-press directory |
| Learnability | Nomad | Zero-step start, symmetry default, toggles explained on page one |
| Expert efficiency | ZBrush | Modifier quasi-modes, start-location semantics, history tools |
| UI consistency | Us, then Nomad | Keep our tokens/kit; adopt Nomad's long-press rule |
| Touch | Nomad | Sticky buttons, hold-Mask taps, double-tap pivot, stroke offset |
| Desktop | ZBrush / 3DCoat | Right-click nav, END bind, navigation presets, wheel mapping |
| Customisability | ZBrush / 3DCoat | Bind-anything, custom toolbars and pies |
| Performance | Us | Keep perf as a feature (show it in onboarding and Stats) |
| Feature depth | ZBrush | Prioritise depth in sculpt, gizmo, masking before breadth |
| Onboarding | Nomad + 3DCoat | Ready sphere + task-first launcher for returning users |

## Radar summary (text)

- **ZBrush**: deep and fast for experts, heavy for everyone else.
- **Nomad**: light and touch-native, shallower.
- **3DCoat**: configurable desktop pipeline, room-fragmented, no touch.
- **Us**: fastest engine and most consistent UI, weakest at customisation and onboarding. The cheapest score gains are customisation (2 → 7 via the command registry, bindings and toolbars) and onboarding (3 → 7 via starter scenes, first-run hints and in-app help).
