# 12 · Product Roadmap

Phased plan that turns 07-11 into PR-sized work for our app, ordered by the priority score (07) and by dependencies. IDs: `A-xx` from 13 (our audit), `P-xx` patterns from 09. Effort: S ≤ 3 days, M ≤ 2 weeks, L > 2 weeks of agent work. Every phase ends with the project's usual gate (`build check`, `test`, `smoke`, `touch_check.py`, bench before/after for anything near the hot path) and a Windows/tablet try by Bolt where marked 🧪.

## Phase 0 · Validate what we have (now)

| Item | Why | Effort | Done when |
|---|---|---|---|
| Run the `sm-touch-testing` device checklist on the OnePlus tablet 🧪 | Problem #4 in 07; all touch tuning (10 pt slop, 90 ms hold) is guessed | S (Bolt) | Checklist results recorded in memory |
| Windows try of PRs #8-#49 🧪 | Nothing since PR #7 has run on Windows | S (Bolt) | Issues filed per PR |
| Check Save / Save As cannot overwrite another file silently | Problem #2 (N022 data loss) | S | Scripted test |
| Housekeeping: A-28 (move spikes), A-31 (memory, done) | Clarity for agents | XS | – |

## Phase 1 · Foundations (no visible change)

| Item | Depends on | Effort | Done when |
|---|---|---|---|
| A-22 settings schema (one table for load/save, version field) | – | S | Round-trip test; 58 duplicated cases gone |
| A-21 brush descriptor table | – | S | Adding a brush touches 2 files |
| A-20 command registry: design review with `sm-architect`, then migrate shortcuts, menus, pie | – | M | Every shortcut/menu row runs through `run(cmd)`; no behaviour change; touch_check green |
| A-25 op result channel + toasts with Undo (P14) | A-20 | S | All `*_last` structs removed |
| A-26 unit tests for gesture classification, drag ownership, settings round-trip, history order | – | S-M | New `odin test` targets for app logic |

## Phase 2 · Touch parity (largest user value)

| Item | Pattern / evidence | Effort | Done when |
|---|---|---|---|
| Modifier rail: Smooth, Invert, Mask, Hide (tap latch / hold momentary) | P1 · N004, Z023 | M | Touch scenarios for latch, hold, combined with stroke |
| Colour-coded cursor | P15 · Z023 | S | Each mode visibly distinct |
| Start-location taps with Mask/Hide held (invert, blur, sharpen, clear, tap group isolate) | P2 · N004, Z061, A-11 | M | Scenarios + toasts |
| Long press = secondary everywhere, right-click on desktop | P3 · Z032 | M | Directory in 09 implemented |
| Double-tap pivot, pivot dot, two-down-lift-one orbit | P7, P8 · N012 | S-M | Camera scenarios |
| Hold-to-repeat undo/redo | P17 · N019 | S | Scenario |
| Android finger-pressure handling setting | N014 | S | Setting + default per platform 🧪 |

## Phase 3 · Find anything (discoverability)

| Item | Pattern / evidence | Effort | Done when |
|---|---|---|---|
| Command palette with synonyms, recents, shortcut hints | P9 · Z033, C008 | M | Every registry command findable; "dynamesh" finds Remesh |
| Shortcut and gesture shown in menus and tooltips | Z031 | S | 100% coverage from registry |
| Object tab split into Shape / Select / Surface / Build | A-23 · 08 §3 | S | No section lost; each page ≤ 6 sections |
| Contextual action bar | P11 · N004 | M | States in 08 §4 |
| Basic / More disclosure per section | P19 | S | Basic ≤ 5 controls |
| Help & gestures: glossary + cheat sheet generated from bindings | 08 §6 · N022 | S | Cheat sheet regenerates from data |
| First-run coach marks + starter scenes | P18 · N002, C063 | M | 5/5 hallway test 🧪 |

## Phase 4 · Make it yours (customisation)

| Item | Evidence | Effort | Done when |
|---|---|---|---|
| Brush presets: save, clone, revert, rename, thumbnail; dock slots user-editable | N004, C086 | M | Presets persist; dock long-press works |
| Bind where you see it (hover + bind key; long press → Assign) with conflict prompt | P10 · Z071, C004, Z152 | M | Conflicts resolved inline |
| User pies (4 × 8 slots) and favourites | Z039, C008 | S | Editable from palette ⋯ |
| Settings ▸ Keys and buttons (search, reset per binding), navigation presets ZBrush/Blender/Maya | C005, N003 | M | Presets switch cleanly |
| Gesture map editor with conflict detection | N003 | S | Conflicts never silent |

## Phase 5 · Never lose work, try freely (safety)

| Item | Evidence | Effort | Done when |
|---|---|---|---|
| Autosave snapshots on a worker, rotate N, crash recovery prompt | N005, C059, Z109 | M-L | Kill test loses ≤ 2 min; stroke frame unchanged at 10M (bench) |
| Save that finishes before saying so; Save a copy; Versions list | C059, N022 | S | – |
| Adjust last operation (remesh, decimate, retopo, smooth all, extract, mirror) | P12 · Z123 | M | Re-run from swap snapshot |
| Camera history (back/forward views) | P22 · Z110 | S | – |
| Two-phase shapes with ✓/✕ and auto-apply setting | P4 · N004 | S | Default off on touch |
| Rebuild panel with density checkerboard preview | P13 · N007 | M | Preview cost < 1 ms |

## Phase 6 · Depth where artists feel it

| Item | Evidence | Effort | Done when |
|---|---|---|---|
| Full gizmo: rotate, scale, pivot by surface tap, snapping, numeric entry | A-10 · Z066, N004 | M | Blockout flow W2 without typed values |
| Scene tree: groups, parenting, solo, ghost, column drag, multi-select transform | A-09 · N006, C010, Z160 | L | 50-object scene stays manageable |
| Selection model: saved selections, mask ⇄ group ⇄ hide conversions, mask by cavity | Z097, C026, Z037 | M | – |
| Posing: rotate gizmo + topological mask | Z064, Z115 | M | Bend a limb in one flow |
| Stroke engine: roll, spray, straight line, snap-continue, plane locks, filter chips | Z087, Z085, N013 | M | – |
| History brush (local undo), adjust last stroke | Z140, Z123 | M | – |
| Layers at any level; reproject layers after Rebuild | Z089, N017 | L | – |
| Deformers: bend, twist, taper, lattice | Z067, N022, C071 | L | – |

## Phase 7 · Pipeline and automation

| Item | Evidence | Effort | Done when |
|---|---|---|---|
| Command scripts (`--run`), retire tool-mirroring flags | A-24 · C050 | M | Benches and touch_check use scripts |
| Macro recording from the command log | Z106 | S | – |
| glTF and USD export (layers as morph targets) | N005 | M | Opens in Blender |
| Content packs (brushes, alphas, matcaps, base meshes) | C083 | M | Store-safe on Android |
| Live link with Blender | N022, Z103 | L | – |
| Script plugins over the registry (Lua or embedded VM) | C049, Z015 | L | Sandboxed, desktop first |

## Not on the roadmap (and why)

- Rooms or per-stage workspaces: 3DCoat's own docs show the cost (C053).
- Separate desktop-dense layout: Bolt's single-layout rule.
- Collaborative/LAN sculpting: vetoed by Bolt.
- 2.5D canvas or projection-master workflows: outdated (Z107, Z118).
- Voxel volume mode as a second representation: high cost (C011, C075 show the data-loss traps); revisit after Phase 6 using `src/sdf_trial`.

## Expected scorecard after each phase (06 criteria)

| Phase | Discover | Learn | Expert | Touch | Custom | Onboard |
|---|---|---|---|---|---|---|
| Today | 4 | 6 | 6 | 7 | 2 | 3 |
| After 2 | 5 | 7 | 7 | 9 | 2 | 3 |
| After 3 | 7 | 8 | 7 | 9 | 3 | 7 |
| After 4 | 7 | 8 | 8 | 9 | 7 | 7 |
| After 6 | 8 | 8 | 9 | 9 | 8 | 7 |
