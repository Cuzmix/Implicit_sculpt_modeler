# 11 · Modern Sculpting Blueprint

The ideal sculpting application this research points to, written as twelve architectures. Each one names the strongest source concepts, the design, and how it lands in our codebase (packages from AGENTS.md: `app`, `ui`, `render`, `sculpt`, `geom`, `camera`, `gizmo`, `jobs`). Sketch types are Odin-flavoured and illustrative, not final API; anything touching `History`, `Scene_Command` or GPU layouts needs an `sm-architect` review first.

Design stance in one line: **ZBrush's expert grammar, Nomad's touch affordances, 3DCoat's configurability, on our engine's speed, with nothing destructive and nothing hidden.**

---

## 1. Navigation architecture

**From:** drag-empty-to-orbit (Z018, N012, C005); right-drag (Z018); two-down-lift-one (N012); double-tap pivot + pivot dot (N012); camera undo (Z110); named views with references (N012, N011); navigation presets (C005).

**Design.**
- Camera state lives in `camera` (pure). Add `View_History` (ring of 32 camera states pushed on settle after a navigation gesture ends) and `Saved_View{name, camera, reference_image}`.
- Pivot policy enum: `On_Double_Tap | Under_Pointer_On_Start | Selection_Centre`, default double-tap (N012), shown by a pivot dot overlay while orbiting.
- Navigation presets are binding sets in the command registry (`nav.orbit`, `nav.pan`, `nav.zoom` bound to mouse chords): `ZBrush` (default), `Blender`, `Maya`.
- Fallback orbit routes: two-down-lift-one in `touch.odin`; on-screen assistive puck (accessibility).

## 2. Viewport architecture

**From:** CPU-agnostic big-mesh drawing (Z001, Z060), low-res while orbiting (N018), progressive refine when idle (N010), live previews (N007), colour-coded cursor (Z023).

**Design.** Keep what we have (partial redraw, idle cache, simplified far chunks, grouped culling, studio render accumulating when still). Add an **overlay layer contract**: tools publish overlay primitives (cursor ring with mode colour, pivot dot, shape outline with ✓/✕ handles, density checkerboard, gizmo) into one list drawn by `render/ui_pass` just above the viewport image (we already do this with `ui.layer_mark`). Previews that need geometry (boolean ghost, retopo draft wireframe) render as extra draw items flagged `preview`, never written into the scene until commit.

## 3. Scene hierarchy architecture

**From:** Nomad tree with groups, instances, repeaters (N006); 3DCoat ghost, tree-drag booleans (C010, C045); ZBrush multi-object gizmo (Z160); ZBrush's flat list as the limit to beat (Z058).

**Design.**
```odin
Node :: struct {
    id:        Node_Id,
    parent:    Node_Id,          // 0 = root
    kind:      enum {Group, Mesh, Instance, Repeater, Light, View},
    name:      string,
    local:     matrix[4,4]f32,   // node transform, separate from vertices (N004 concept)
    flags:     bit_set[enum {Hidden, Ghost, Locked, Solo}],
    boolean:   enum {None, Union, Subtract, Intersect}, // explicit badge, never inferred (N006 lesson)
    mesh:      Object_Id,        // Mesh and Instance point at shared mesh data
}
```
- The existing `Scene` objects become `Mesh` nodes; groups and instances are additive. Every tree edit is a `History` entry (no un-undoable folder ops, Z058 lesson).
- Multi-select drives the gizmo (transform all selected, Z160) and batch commands ("apply to selected", Z005).

## 4. Brush architecture

**From:** brush = preset (N004, C086); modifier stacks (C019); Shift-smooth with own settings (Z121); filters (N013); paint channel on any brush (N015, C025); VDM (Z004).

**Design.**
```odin
Brush_Info :: struct {                     // one row per sculpt.Brush_Kind, replaces 6 scattered tables (A-21)
    kind: sculpt.Brush_Kind, name, help: string, icon: rune,
    family: enum {Displace, Smooth, Grab, Plane, Mask, Paint, Sim},
    defaults: Brush_Params,
    caps: bit_set[enum {Alpha, Dyntopo, Paint_Channel, Drag_Rect, Pressure_Size}],
}
Brush_Preset :: struct {                   // user-owned, saved in settings or .brush files
    id: Preset_Id, base: sculpt.Brush_Kind, name: string, thumbnail: Image_Id,
    params: Brush_Params,                  // size, strength, falloff curve, alpha, stroke, lazy, pressure curves
    filters: bit_set[enum {Front_Only, Connected, Protect_Mask, Protect_Hidden}],
    paint: Maybe(Paint_Channel),           // colour/roughness/metal if the preset also paints
}
```
- Secondary brush slots: `smooth_preset`, `invert` behaviour per family, both remembered separately (Z121).
- Dab kernels split by `family` in `sculpt/brush.odin` (A-30) so new brushes are data, not new switch arms.
- Filters render as chips on the Brush page and in the cursor (no sticky hidden filters, C023 lesson).

## 5. Input architecture

**From:** ZBrush for iPad routing (Z021, Z022) we already ship; sticky buttons (N004); long press directory (Z032); bindings for keys/stylus/gamepad (N003); stacked and sticky keys (C004).

**Design.** Three layers, each already partly in place:
1. **Devices → events** (`device.odin`, `touch.odin`): SDL events, one owner per touch, palm rules. Unchanged.
2. **Events → gestures** (`navigate.odin`, `ui` gesture arena): tap, double tap, long press, drag, two/three/four-finger forms, pen buttons. Add long press, double tap, hold-repeat, two-down-lift-one.
3. **Gestures and keys → commands** (new `bindings.odin`): a table from `Trigger` to `Command_Id` with context.
```odin
Trigger :: struct {
    device: enum {Key, Mouse, Touch, Pen, Gamepad},
    code:   u32,                 // key code, button, finger count, gesture kind
    mods:   bit_set[Modifier],   // Ctrl, Shift, Alt, plus on-screen Smooth/Invert/Mask/Hide
    where_: enum {Anywhere, On_Model, Off_Model, On_Mask, On_Unmasked, On_UI}, // start-location semantics (Z061)
    style:  enum {Press, Hold_Momentary, Tap_Latch, Repeat},                   // sticky (N004, C004)
}
Binding :: struct { trigger: Trigger, command: Command_Id, context: Context_Mask }
```
- On-screen modifier buttons set the same `Modifier` bits as keys, so one rule set serves keyboard and touch.
- Strokes are not commands; they stay on the hot path in `sculpt_tool.odin` and only *read* the modifier set (perf line untouched).

## 6. Layer architecture

**From:** ZBrush REC layers (Z089); Nomad layers that survive topology change and carry paint channels (N017); 3DCoat per-channel opacity and blend (C040).

**Design.** Keep `sculpt/sculpt_layers.odin` deltas. Extend in order: (1) layers at any level, propagated like strokes (removes ZBrush's top-level rule, Z089); (2) reproject layer deltas after Rebuild (Nomad's strength, N017); (3) paint channels per layer with blend mode; (4) per-channel factor. A layer is always recording when selected (Nomad/3DCoat model, no REC toggle trap).

## 7. Workspace architecture

**From:** Nomad's object-of-attention menus (N001), ZBrush iPad toolbars by role (Z025-Z028), 3DCoat contextual top bar (C002) without rooms (C053 lesson).

**Design.** One workspace with fixed regions (Bolt's rule), content that adapts: inspector pages (Brush / Object ▸ Shape·Select·Surface·Build / Scene), a contextual action bar driven by `Active_State` flags (mask present, hidden present, shape pending, curve pending, last op adjustable), and the command palette as the universal entrance. Stages (block → topology → detail → surface → deliver) are expressed as Object pages and stage hints, never as rooms.

## 8. Tool architecture

**From:** ZBrush's few modes + modifiers (Z019); Nomad's per-tool top toolbar (N004); ZModeler action×target grammar (Z083).

**Design.** Keep four tools (Move, Sculpt, Curve, Insert) as *modes of the pointer*; everything else is a command. A tool implements:
```odin
Tool_VTable :: struct {
    begin, update, end, cancel: proc(app: ^App, input: Viewport_Input),
    overlay:  proc(app: ^App, dl: ^ui.Draw_List),
    actions:  proc(app: ^App) -> []Command_Id,   // feeds the contextual bar
    commit:   proc(app: ^App) -> Op_Result,      // two-phase tools (P4)
}
```
Future poly-modelling tools follow the action × target grammar (Z083) with touch-down preview and lift-to-commit instead of hover (Z153 lesson).

## 9. Customisation architecture

**From:** Ctrl+Alt bind-anything (Z071), END bind with stacked/sticky (C004), iPad conflict detection and swipe-delete (Z152), Nomad bottom-bar bindings and floating toolbars (N003), custom quick menus (Z039).

**Design.** Customisation = data over the registry, stored by the settings schema (A-22):
- `bindings: [dynamic]Binding` (defaults + user overrides; reset per binding).
- `dock: [7]Preset_Id`, `pies: [4][8]Command_Id`, `favourites: [dynamic]Command_Id`.
- `gesture_map` (Settings ▸ Touch and pen) with conflict detection.
- Export/import as one text file. Never layout changes (single-layout rule).

## 10. Onboarding architecture

**From:** Nomad's ready sphere (N002), 3DCoat Quick Start and missions (C063), ZBrush Home starters (Z131), Simplest room / 3DCoatPrint as reduced tool sets (C056, C065).

**Design.**
- First run: sphere ready (as today) + three coach marks (P18), each dismissed by doing it.
- New ▸ starter scenes: sphere, head, bust, body, hand, creature base, hard-surface block (our own meshes; licence-clean).
- Help & gestures: searchable glossary (08 §6), gesture cheat sheet generated from the bindings table (so it can't drift, Nomad/3DCoat doc-lag lesson), "what does this do" long-press cards fed by `Command.help`.
- "Basic" disclosure on every inspector section; experts pin "More".
- Stage hints: e.g. after long dyntopo sessions "Mesh is uneven: Rebuild ▸ Quads?" (dismissible, never modal).

## 11. Plugin architecture

**From:** 3DCoat extensions and .3dcpack packages (C083), Core API in C++ (C050), ZBrush Zplugins (Z101), Nomad's absent API (N022 request).

**Design (later phase).** Plugins call the same registry as the UI, nothing else:
- **Content packs** first: zip of brush presets, alphas, matcaps, starter meshes with a manifest. No code, store-safe on Android (`sm-store`).
- **Script plugins** second: a sandboxed scripting language (Lua or a small Odin-hosted VM) with access to `run(command, args)`, read-only scene queries and mesh read/write through `geom`. No native plugins on mobile.

## 12. Automation architecture

**From:** 3DCoat CLI `-script` (C050) and script recorder (C034), ZBrush macros (Z106), Apply Last Action (Z005), our ~100 start-up flags (A-05).

**Design.**
- **Command log**: every executed command (id + args) is appended to an in-memory log; History labels come from it.
- **Command scripts**: plain text, one command per line (`remesh density=0.8; slice axis=x; boolean op=subtract target="Cube 2"`), run by `--run file.cmd` or from the palette. Replaces the tool-mirroring flags; `touch_check.py` and benches use the same path, so tests exercise exactly what users run.
- **Macros**: save a range of the command log as a script, bind it like any command.
- **Batch**: "Apply to selected objects" for any object-scoped command.

---

## How the twelve fit together

```
 devices → gestures → bindings ─┐
 menus · pies · bar · palette ──┼──► Command registry ──► run(cmd, args) ──► Op_Result ──► History · toasts · bar "Adjust…"
 scripts · macros · plugins ────┘          │                                   │
                                           └── help text, icon, shortcut ──────┴──► onboarding, cheat sheet, search
 tools (Move/Sculpt/Curve/Insert) ── hot path reads modifier set ──► sculpt / geom (unchanged perf path)
```

The registry is the spine: build it first (12, phase 1).
