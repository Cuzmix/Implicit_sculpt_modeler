# 10 · Redesign Proposal (for our app)

A concrete redesign of what exists at `922f797`, keeping Bolt's standing decisions:

- Odin + SDL3 + our own kit (`src/ui`), no ImGui, no Flutter/Qt (cross-platform-flutter-plan).
- One touch-sized layout on every OS and device, scaled by DPI (`sm-store`).
- ZBrush for iPad is the behaviour model for touch, pen and camera (sculpt-touch-camera).
- ~4 ms input-to-screen is the line; UI at ≤1 ms p50 (today 0.65 ms).

The proposal changes *where things live and how secondary actions are reached*, not the visual language or the input router.

## 1. Goals and measures

| Goal | Measure | Today → target |
|---|---|---|
| A new user sculpts, smooths, masks and undoes in the first minute on a tablet without help | Hallway test on the OnePlus tablet, 5 people | not measured → 5/5 |
| Any command is reachable in ≤ 2 actions from the canvas | Count over the registry | Object-tab items need 3-5 (open inspector, tab, scroll, open section, tap) → ≤ 2 via search, bar or pie |
| Touch users can invert, smooth, mask and hide mid-stroke | Scripted scenarios in `touch_check.py` | impossible → yes |
| Every command has a visible shortcut and is rebindable | Registry coverage | 0% → 100% |
| No lost work after a crash | Kill the app mid-session; reopen | everything since last manual save lost → ≤ 2 min lost |
| UI cost stays flat | `ui_ms_p50` release | 0.65 ms → ≤ 0.8 ms |

Scorecard targets (06): Discoverability 4→7, Customisability 2→7, Onboarding 3→7, Touch 7→9, Expert efficiency 6→8.

## 2. Layout (tablet 1366×1024 and desktop 1440×900 alike)

```
┌───────────────────────────────────────────────────────────────────────────────────────┐
│ ≡  ↶ ↷  ⏱            [ Move | Sculpt | Curve | Insert ]   X Y Z           🔍  👁  ▤    │  top bar (existing + 🔍 search)
│                                                                                       │
│ ┃S┃                                                                     ┌──────────┐  │
│ ┃i┃                                                                     │ Inspector│  │
│ ┃z┃                         viewport                                    │ Brush    │  │
│ ┃e┃                                                                     │ Object ▸ │  │
│ ┃ ┃                         (pivot dot while orbiting)                  │ Shape    │  │
│ ┃S┃                                                                     │ Select   │  │
│ ┃t┃                                                                     │ Surface  │  │
│ ┃r┃                                                                     │ Build    │  │
│ ──                                                                      │ Scene    │  │
│ (◐) Smooth                                                              └──────────┘  │
│ (±) Invert          ┌───────────────────────────────────────────┐                     │
│ (▣) Mask            │ Clear  Invert  Blur  Grow  Shrink  Extract│  contextual bar     │
│ (◌) Hide            └───────────────────────────────────────────┘  (only when active) │
│                [Draw][Smooth][Clay][Flatten][Inflate][Grab][Mask][ + ][ ▦ ]  Sphere · 1.2M│
└───────────────────────────────────────────────────────────────────────────────────────┘
```

Changes against today, region by region:

| Region | Today | Proposed | Code |
|---|---|---|---|
| Top-right | View menu, inspector | + **Search** button (command palette) | `kit_layout`, new `kit_search.odin` |
| Left rail | Size, Strength | + **modifier buttons** Smooth / Invert / Mask / Hide (P1) | `kit_layout`, `sculpt_tool.odin` modifier set |
| Above dock | – | **Contextual action bar** (08 §4) | new `kit_action_bar.odin` |
| Dock | 7 fixed brushes | 7 **user favourite** slots (long press to change), last slot "+" to pin the current brush | `kit_layout`, settings |
| Object chip | name + vertices | tap = Object page; long press = object actions (duplicate, delete, solo, ghost, rename) | `kit_layout` |
| Inspector Tool tab | 7 sections | renamed **Brush**; Basic/More disclosure; Presets section | `kit_tool.odin` |
| Inspector Object tab | 18 sections | **segmented Shape / Select / Surface / Build** (08 §3) | `kit_object.odin`, `Kit_Section` |
| Inspector Scene tab | flat list | **tree** with groups, solo, ghost, column drag (P16) | `kit_scene.odin` |
| Viewport | brush outline | colour-coded cursor (P15), pivot dot (P7), shape ✓/✕ (P4) | `overlay.odin`, `navigate.odin` |
| Menu | file items | + New ▸ starter scenes, Versions, Help & gestures | `kit_menu` |

## 3. Key flows after the redesign

**Mask a region and extract it (touch).** Tap Mask on the rail (latched, amber cursor) → paint on the model → bar appears: tap Grow twice → Extract → bar shows "Adjust…" for thickness → tap Mask again to unlatch. *Today:* Mask brush from grid or Ctrl (no Ctrl on tablet), then inspector → Object → scroll to Mask → Grow → scroll to Extract.

**Smooth mid-stroke (touch).** Hold Smooth with the off hand while drawing (momentary), release to return. *Today:* impossible without a keyboard.

**Remesh to an even mesh.** Search "remesh" or Object ▸ Shape ▸ Rebuild ▸ Even → drag Density and see the checkerboard → Apply → bar "Adjust…". *Today:* Object tab → scroll to Remesh → pick a vertex count blind.

**Find a feature you heard of ("DynaMesh").** 🔍 → type "dyna" → "Rebuild: Even remesh (DynaMesh)" with its shortcut Ctrl+R.

**Isolate a part.** Hold Hide → tap a group → only that group shows; tap background → invert; bar → Show all.

**Recover from a crash.** Reopen → "Restored from 1 minute ago (autosave). Open the last saved version instead?"

## 4. What we deliberately do not change

- The input router (one owner per touch, gesture arena) and its tuning, until the tablet checklist comes back.
- The camera model (Free/Turntable, 360° orbit, Shift snap).
- Visual tokens, motion and the kit; ImGui stays removed.
- The single layout rule. Customisation happens *inside* it (favourite slots, pie slots, bindings), never by moving regions.

## 5. Engineering foundations the redesign needs

These come from the audit (13) and are prerequisites, not extras:

1. **Command registry (A-20)** — every button, menu row, pie slot, shortcut, gesture and search result points at a command id. Unlocks search, bindings, favourites, contextual bar, macros, scripts. Needs an `sm-architect` design first (AGENTS.md: touches `Scene_Command` and `History`).
2. **Brush descriptor table + presets (A-21)** — one row per brush kind; presets layered on top.
3. **Settings schema (A-22)** — one table for load and save, versioned, so new remembered values (favourites, bindings, gestures) cost one line.
4. **Op result channel (A-25)** — every command returns `{ms, changed, message}`; drives toasts, the bar's "Adjust…" and History labels.
5. **Autosave snapshots** — reuse the `.sculpt` writer on a worker with a copy-on-write snapshot of the scene's dirty objects; write to `autosave/`, rotate N.

## 6. Risks

| Risk | Mitigation |
|---|---|
| Modifier rail and contextual bar crowd small tablets | Rail collapses to one "modifiers" button under 900 pt height; bar is one row, scrolls horizontally |
| Long press conflicts with scroll and drag | Gesture arena already decides by slop; long press only fires when no movement past slop (10 pt) |
| Registry refactor touches every UI file | Land it behind the same UI first (no visual change), then move features page by page |
| Autosave stalls strokes on big meshes | Snapshot dirty nodes only; write on worker; skip while a stroke is active; measure at 10M |
| Too many options again | Every new control goes through 07's priority and the "Basic ≤ 5 controls" rule |
