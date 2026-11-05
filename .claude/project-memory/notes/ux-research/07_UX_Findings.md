# 07 · UX Findings

What the three products teach, as principles first, then the ranked lists the brief asks for: Top 100 UX problems, Top 100 opportunities, Top 50 workflows to preserve, Top 50 to replace and Top 50 modern improvements.

## Scoring

Every item carries four 1-5 scores, judged for **our app** (Odin + SDL3 + own touch-first kit, Windows/Linux/Android tablets, ZBrush for iPad as the touch model):

- **Impact**: how much the change moves the scorecard in 06.
- **Difficulty**: engineering effort in our codebase (1 = days, 5 = months).
- **Risk**: chance of regressions, perf cost or confusing existing users.
- **User value**: how much artists would feel it.

**Priority = 2 × Impact + 2 × User value − Difficulty − Risk** (0 to 18). Lists are sorted by priority, then impact. Evidence IDs point to `00_Sources.md`; `13` points to our own audit. "Seen in": Z ZBrush, N Nomad, C 3DCoat, Us our app.

## Twelve principles behind world-class sculpting UX

1. **The stroke is sacred.** Nothing a stroke depends on should need a menu. All three keep the secondary actions (smooth, invert, mask) one modifier away (Z019, N004, C020). On touch that modifier must be visible (N004, Z023).
2. **Where a gesture starts is information.** ZBrush's "on model vs off model" semantics are its fastest idea (Z061) and Nomad keeps it (N004). It only works when feedback shows what will happen (Z023 cursor colours, N012 pivot dot).
3. **Navigation never costs a tool change** (Z018, N012, C005), and always has a fallback when the model fills the screen (N012 two-down-lift-one, Z018 right-drag).
4. **Tap for the common case, long press for the rest.** ZBrush iPad and Nomad converge on this independently (Z032, N002). Right-click is the desktop twin.
5. **Search beats hierarchy for a big tool set.** Each product bolted on search late (Z033, C008, C073). Start with it.
6. **Everything is bindable where it is shown.** Ctrl+Alt+click (Z071), END (C004), searchable bindings (N003). Customisation should never mean editing files (C029).
7. **Destructive steps must stay recoverable.** The docs' worst admissions are lost history and lost work (Z096, Z058, C040, N005, N022). Snapshot, don't warn.
8. **One concept, one name.** Mask vs freeze vs hide vs selection (C026, C079), two curve systems (N022), three file types (Z109) all cost learnability.
9. **State must be visible.** Invisible channel toggles (Z091), sticky conditions (C023), per-tool symmetry (N004) and implicit booleans (N006) all bite.
10. **Stages are the real workflow.** Blocking → topology → detail → paint → deliver appears in every product (Z043, N021, C009). Make the transitions explicit.
11. **Presets are how artists own a tool.** Brush packs are among Nomad's most-viewed threads (N022); 3DCoat and ZBrush ship preset systems (C086, Z084).
12. **Performance is UX.** ZBrush's CPU engine and Nomad's mobile limits shape everything (Z001, N021). Our speed is our strongest card; expose it (budgets, live previews) rather than hide it.


## Top 100 UX problems

Problems found in the docs and forum (and in our app). "Us?" says whether the problem applies to our app today. Scores rate the value of fixing or avoiding it.

| # | Problem | Seen in | Evidence | Us? | Impact | Difficulty | Risk | User value | Priority |
|---|---|---|---|---|---|---|---|---|---|
| 1 | Modal trap: a new primitive "drops" to the 2.5D canvas unless Edit mode is turned on, and can never be sculpted again | Z | Z107 | avoided | 5 | 1 | 1 | 5 | **18** |
| 2 | Save As can overwrite another project; data-loss reports | N | N022 | check our dialog | 5 | 2 | 1 | 5 | **17** |
| 3 | Touch users cannot invert, smooth or mask mid-flow (no modifier buttons) | Us | 13 A-12 | yes | 5 | 2 | 1 | 5 | **17** |
| 4 | Untested on a real tablet and pen | Us | sculpt-touch-camera | yes | 5 | 2 | 1 | 5 | **17** |
| 5 | Feature location follows implementation ("Tool" palette holds everything) | Z | Z159 | yes: Object tab holds 18 sections | 5 | 2 | 2 | 5 | **16** |
| 6 | No search for commands or settings | Us | 13 A-07 | yes | 5 | 3 | 1 | 5 | **16** |
| 7 | No background autosave; reminder popup only | N | N005 | yes: no autosave | 5 | 3 | 2 | 5 | **15** |
| 8 | Palm touches trigger undo, selection and camera moves | N | N022 | partly (pen-near ignores hand) | 5 | 3 | 2 | 5 | **15** |
| 9 | Three overlapping file types (document, tool, project); undo history saved only in one | Z | Z109,Z096 | avoided | 4 | 1 | 1 | 4 | **14** |
| 10 | Preferences and custom UI layouts do not save automatically | Z | Z072,Z073 | avoided | 4 | 1 | 1 | 4 | **14** |
| 11 | 24 palettes with nested sub-palettes; one open at a time | Z | Z072,Z159 | avoided | 4 | 1 | 1 | 4 | **14** |
| 12 | Some operations clear the whole undo history | Z | Z096 | avoided (History swaps) | 4 | 1 | 1 | 4 | **14** |
| 13 | Desktop vs tablet feature parity gaps | Z | Z017,Z149 | avoided by one codebase | 4 | 1 | 1 | 4 | **14** |
| 14 | Second tap on Save silently overwrites | Z,N | Z027,N022 | check our Save path | 4 | 1 | 1 | 4 | **14** |
| 15 | Mesh types native to rooms; UV only on Paint objects | C | C003,C037 | avoided | 4 | 1 | 1 | 4 | **14** |
| 16 | Rooms do not explain how data moves between them | C | C053 | avoided | 4 | 1 | 1 | 4 | **14** |
| 17 | Some merges and deletes are not undoable | C | C040,C072 | avoided | 4 | 1 | 1 | 4 | **14** |
| 18 | Navigation needs empty canvas; zoomed in, users must find a thin border | Z,N | Z019,N012 | yes (right-drag and 2-finger help) | 4 | 2 | 1 | 4 | **13** |
| 19 | Several overlapping remeshers with unclear roles | N | N007 | yes: Remesh, Decimate, Retopo, Dyntopo in one tab | 4 | 2 | 1 | 4 | **13** |
| 20 | Users lose the camera pivot | N | N012 | yes (no pivot dot) | 4 | 2 | 1 | 4 | **13** |
| 21 | Android: experimental keyboard, unreliable finger pressure | N | N003,N014 | risk on Android | 4 | 2 | 1 | 4 | **13** |
| 22 | "How to invert mask?" needs a forum thread | N | N022 | yes: no in-app help | 4 | 2 | 1 | 4 | **13** |
| 23 | Masks have three names and behaviours (Freeze, Hide, Pose selection) | C | C026,C079,C071 | partly (mask vs hide) | 4 | 2 | 1 | 4 | **13** |
| 24 | Save finishes 10-30 s after it looks done | C | C059 | check our save feedback | 4 | 2 | 1 | 4 | **13** |
| 25 | No onboarding, sample scenes or empty-state help | Us | 13 A-13 | yes | 4 | 2 | 1 | 4 | **13** |
| 26 | No tap-to-isolate polygroup | Us | 13 A-11 | yes | 4 | 2 | 1 | 4 | **13** |
| 27 | No user brush presets | Us | 13 A-03 | yes | 4 | 2 | 1 | 4 | **13** |
| 28 | Same Ctrl+Shift+click gives different results depending on current visibility | Z | Z063 | risk if we copy group isolate | 4 | 2 | 2 | 4 | **12** |
| 29 | No rebinding of shortcuts | Us | 13 A-02 | yes | 4 | 3 | 1 | 4 | **12** |
| 30 | Gizmo moves only; rotate and scale via typed values | Us | 13 A-10 | yes | 4 | 3 | 1 | 4 | **12** |
| 31 | Hover-dependent targeting (ZModeler) fails on touch screens | Z | Z130,Z153 | future poly tools must not need hover | 4 | 3 | 2 | 4 | **11** |
| 32 | No deformers until 2.9 (bend, twist, taper, lattice) | N | N021,N022 | yes | 4 | 3 | 2 | 4 | **11** |
| 33 | Android much slower than iPad | N | N020 | risk; measure on tablet | 4 | 3 | 2 | 4 | **11** |
| 34 | Voxel ⇄ surface switch nullifies sculpt layers | C | C011,C013 | avoid if we add volume mode | 4 | 3 | 2 | 4 | **11** |
| 35 | Flat object list, no groups | Us | 13 A-09 | yes | 4 | 3 | 2 | 4 | **11** |
| 36 | One key (D / Shift+D) changes meaning with mesh state | Z | Z069 | avoided | 3 | 1 | 1 | 3 | **10** |
| 37 | Mid-drag modifier-release chords for zoom and roll are undiscoverable | Z,N | Z018,N012 | partly (Alt-release not used) | 3 | 1 | 1 | 3 | **10** |
| 38 | Modifier timing before vs after the click changes the result | Z | Z141 | avoided | 3 | 1 | 1 | 3 | **10** |
| 39 | Primitives are parametric until converted; state invisible | Z | Z161 | avoided (our primitives are meshes) | 3 | 1 | 1 | 3 | **10** |
| 40 | Three-finger gestures collide with OS accessibility zoom | Z | Z038 | check Android gesture settings | 3 | 1 | 1 | 3 | **10** |
| 41 | Bottom bar mixes "tap runs" and "tap opens settings" | Z | Z028 | check dock and menus | 3 | 1 | 1 | 3 | **10** |
| 42 | Local vs World symmetry confuses; dev calls Local "maybe a mistake" | N | N016,N022 | we have world X/Y/Z only (keep it) | 3 | 1 | 1 | 3 | **10** |
| 43 | Boolean operation chosen by visibility state | N | N006 | avoided | 3 | 1 | 1 | 3 | **10** |
| 44 | Transform tools keep their own symmetry state, off by default | N | N004 | avoid when gizmo grows | 3 | 1 | 1 | 3 | **10** |
| 45 | Protect "Auto" depends on unrelated shading toggles | N | N013 | avoid hidden coupling | 3 | 1 | 1 | 3 | **10** |
| 46 | Gesture conflicts silently disable one binding | N | N003 | avoid when bindings land | 3 | 1 | 1 | 3 | **10** |
| 47 | Hotkey docs conflict (Ctrl+X cut vs unhide all) | C | C004 | avoid via registry conflict check | 3 | 1 | 1 | 3 | **10** |
| 48 | Overloaded RMB (short, long and hold differ) | C | C069 | risk with long press | 3 | 1 | 1 | 3 | **10** |
| 49 | Conditions limiter keeps limiting until reset | C | C023 | avoid sticky filters | 3 | 1 | 1 | 3 | **10** |
| 50 | No touch support documented at all | C | - | n/a | 3 | 1 | 1 | 3 | **10** |
| 51 | ≈50 panel types | C | C073 | avoid | 3 | 1 | 1 | 3 | **10** |
| 52 | Paint mode choice (per-pixel, micro-vertex, Ptex, vertex, voxel) before painting | C | C042 | avoided | 3 | 1 | 1 | 3 | **10** |
| 53 | Shortcut keys are not shown next to commands | Us | 13 A-07 | yes | 3 | 1 | 1 | 3 | **10** |
| 54 | Undo stacks per object make cross-object undo order confusing | Z | Z056 | avoided (scene-wide History) | 3 | 1 | 1 | 3 | **10** |
| 55 | Cannot sculpt or pose several objects at once | Z | Z057,Z104 | yes | 4 | 4 | 3 | 4 | **9** |
| 56 | Topology-changing tools destroy multires levels | N,Z | N007 | yes (remesh rebuilds) | 4 | 4 | 3 | 4 | **9** |
| 57 | Folder operations not undoable; folders cannot nest | Z | Z058 | n/a (no folders) | 3 | 2 | 1 | 3 | **9** |
| 58 | Invisible channel state (Zadd/Rgb/M) decides what a stroke does | Z | Z091 | partly (Paint is a brush) | 3 | 2 | 1 | 3 | **9** |
| 59 | Camera undo limited to 14 steps and has no default hotkeys | Z | Z110 | we have no camera undo | 3 | 2 | 1 | 3 | **9** |
| 60 | Perspective camera breaks trim/split/project | N | N004 | check our clip/slice in perspective | 3 | 2 | 1 | 3 | **9** |
| 61 | Two overlapping curve systems (tube vs curve repeater) | N | N022 | avoid: one curve model | 3 | 2 | 1 | 3 | **9** |
| 62 | Five stroke sub-menus with dozens of options per tool | N | N013 | partly (Brush tab long) | 3 | 2 | 1 | 3 | **9** |
| 63 | Manual lags the app by a major version | N | N022 | risk: README only | 3 | 2 | 1 | 3 | **9** |
| 64 | Surface freeze lost when returning to a voxel tool | C | C075 | avoid | 3 | 2 | 1 | 3 | **9** |
| 65 | Density vs resolution is "trial and error" | C | C018 | yes: remesh size by vertex count | 3 | 2 | 1 | 3 | **9** |
| 66 | Pen troubleshooting means switching drivers and renaming user folders | C | C032 | risk on Windows (SDL pen) | 3 | 2 | 1 | 3 | **9** |
| 67 | Remesh size is set as a vertex count, not a visible density | Us | 13 | yes | 3 | 2 | 1 | 3 | **9** |
| 68 | No camera undo | Us | Z110 | yes | 3 | 2 | 1 | 3 | **9** |
| 69 | Long inspector sections push tool settings below the fold on tablets | Us | 13 A-01 | yes | 3 | 2 | 1 | 3 | **9** |
| 70 | Live Boolean result depends on list order; cutters hidden | Z | Z051 | check our booleans' visibility | 3 | 2 | 2 | 3 | **8** |
| 71 | No glTF/USD export | Us | N005 | yes | 3 | 3 | 1 | 3 | **8** |
| 72 | Polygroups must be created at the lowest subdivision level | Z | Z049 | check our groups across levels | 3 | 3 | 2 | 3 | **7** |
| 73 | Layers must be created at top level; one-way transfer when adding levels | Z | Z089 | check our layers vs levels | 3 | 3 | 2 | 3 | **7** |
| 74 | Remeshing breaks Selection Sets | Z | Z097 | n/a (no sets yet) | 3 | 3 | 2 | 3 | **7** |
| 75 | Plugins needed for core multi-object tasks (Transpose Master) | Z | Z104 | n/a | 3 | 3 | 2 | 3 | **7** |
| 76 | No manual retopology (top request) | N | N022 | yes | 3 | 5 | 2 | 4 | **7** |
| 77 | No adjust-last-operation for remesh/decimate/retopo | Us | 13 A-14 | yes | 3 | 3 | 2 | 3 | **7** |
| 78 | No local (brush) undo | Us | Z140 | yes | 3 | 3 | 2 | 3 | **7** |
| 79 | Embedded UV editor uses another app's conventions and locks the main app | Z | Z098 | n/a | 2 | 1 | 1 | 2 | **6** |
| 80 | Docs contradict themselves (F-key order, cube size, touch strength) | Z,N,C | Z070,Z076,N009,C004 | risk: README drift | 2 | 1 | 1 | 2 | **6** |
| 81 | Pinch rolls the camera by default | Z | Z021 | avoided (10° threshold, Free only) | 2 | 1 | 1 | 2 | **6** |
| 82 | Brush picking by 3-key chords requires memorisation | Z | Z070 | avoided | 2 | 1 | 1 | 2 | **6** |
| 83 | Hotkeys stored in shared public folders; Restore unavailable after Store | Z | Z071 | n/a | 2 | 1 | 1 | 2 | **6** |
| 84 | Macros need strict folder and name rules | Z | Z106 | n/a | 2 | 1 | 1 | 2 | **6** |
| 85 | Python support announced without API docs | Z | Z015 | n/a | 2 | 1 | 1 | 2 | **6** |
| 86 | Gizmo "Pin" option confuses users | N | N020 | n/a | 2 | 1 | 1 | 2 | **6** |
| 87 | "Use Hide" toggle does nothing inside the Hide tool | N | N009,N018 | avoid | 2 | 1 | 1 | 2 | **6** |
| 88 | UI requests "largely ignored unless many ask" | N | N022 | process lesson | 2 | 1 | 1 | 2 | **6** |
| 89 | Debug options exposed to users | N | N003 | we keep them in Stats Advanced (fine) | 2 | 1 | 1 | 2 | **6** |
| 90 | Voxels cannot be thin; faceting without normals | C | C074,C012 | n/a | 2 | 1 | 1 | 2 | **6** |
| 91 | Menu customisation means editing script files | C | C029 | n/a | 2 | 1 | 1 | 2 | **6** |
| 92 | Space menu steals number keys into its search box | C | C008 | avoid in palette design | 2 | 1 | 1 | 2 | **6** |
| 93 | Training videos span many old UIs; no beginner order | C | C060 | n/a | 2 | 1 | 1 | 2 | **6** |
| 94 | Hover-only activity bar | C | C033 | avoided | 2 | 1 | 1 | 2 | **6** |
| 95 | Which brush Shift smooths with is hidden state | Z | Z121 | yes (fixed Smooth) | 2 | 2 | 1 | 2 | **5** |
| 96 | Undo history inflates file size | Z | Z096 | check .sculpt size | 2 | 2 | 1 | 2 | **5** |
| 97 | Every tool reports results differently | Us | 13 A-06 | yes | 2 | 2 | 1 | 2 | **5** |
| 98 | No low-poly / box modelling (top request) | N | N022 | yes | 3 | 5 | 3 | 3 | **4** |
| 99 | Four-light cap | N | N009 | n/a | 1 | 1 | 1 | 1 | **2** |
| 100 | No dual-monitor support | C | C002 | n/a | 1 | 3 | 2 | 1 | **-1** |

## Top 100 UX opportunities

Ideas to adopt, each traced to the product that proves it.

| # | Opportunity | From | Evidence | Impact | Difficulty | Risk | User value | Priority |
|---|---|---|---|---|---|---|---|---|
| 1 | Command palette search over commands, settings and brushes | Z,C | Z033,C008,C073 | 5 | 2 | 1 | 5 | **17** |
| 2 | On-screen modifier buttons: Smooth, Invert, Mask, Hide with tap = latch, hold = momentary | N,Z | N004,Z023 | 5 | 2 | 1 | 5 | **17** |
| 3 | Brush presets: Save, Clone, Revert, Rename, Icon on any brush | N,C | N004,C086 | 5 | 2 | 1 | 5 | **17** |
| 4 | Full gizmo: move, rotate, scale, pivot edit, tap-handle numeric entry | N,Z | N004,Z066 | 5 | 3 | 1 | 5 | **16** |
| 5 | Command registry: every action has an id, label, icon, help, default keys, enabled/checked state | Z,C | Z071,C004 | 5 | 3 | 2 | 5 | **15** |
| 6 | Autosave snapshots in the background (incremental, crash-safe) | N,C | N005,C059 | 5 | 3 | 2 | 5 | **15** |
| 7 | Show each command's shortcut and gesture next to it in menus and tooltips | Z | Z031,Z132 | 4 | 1 | 1 | 4 | **14** |
| 8 | Colour-coded brush cursor showing the active modifier mode | Z | Z023,Z077 | 4 | 1 | 1 | 4 | **14** |
| 9 | Double-tap model sets the orbit pivot; double-tap background frames the selection | N | N012 | 4 | 1 | 1 | 4 | **14** |
| 10 | Solo / isolate the selected object in one tap | Z,N | Z026,N002 | 4 | 1 | 1 | 4 | **14** |
| 11 | Save that confirms only when the file is fully written | C | C059 | 4 | 1 | 1 | 4 | **14** |
| 12 | RMB drag horizontal = size, vertical = strength (desktop) | C | C020 | 4 | 1 | 1 | 4 | **14** |
| 13 | Bind-anything: long-press (touch) or press a key while hovering (desktop) to assign a shortcut | Z,C | Z071,C004 | 4 | 2 | 1 | 4 | **13** |
| 14 | Hold-Mask tap grammar: tap background invert, drag background clear, tap mask blur, tap unmasked sharpen | N,Z | N004,Z061 | 4 | 2 | 1 | 4 | **13** |
| 15 | Long press = secondary action on every control (right-click on desktop), with haptic | Z,N | Z032,N002,Z151 | 4 | 2 | 1 | 4 | **13** |
| 16 | User pie menus (choose the slots) | Z,C | Z039,C008 | 4 | 2 | 1 | 4 | **13** |
| 17 | Custom favourites row / floating toolbar | N,Z | N003,Z134 | 4 | 2 | 1 | 4 | **13** |
| 18 | Contextual top toolbar for tools with a lifecycle (mask shapes, curve, insert, retopo) | N | N004 | 4 | 2 | 1 | 4 | **13** |
| 19 | Two-phase shape tools: draw, then confirm with a green check after orbiting | N | N004 | 4 | 2 | 1 | 4 | **13** |
| 20 | Resolution checkerboard preview while dragging remesh size | N | N007 | 4 | 2 | 1 | 4 | **13** |
| 21 | Tap a polygroup to isolate, hide or mask it | Z,N | Z062,N003 | 4 | 2 | 1 | 4 | **13** |
| 22 | Tap a surface to place and orient the gizmo pivot | Z | Z066 | 4 | 2 | 1 | 4 | **13** |
| 23 | Starter scenes and base meshes on first run | Z,N | Z131,N021 | 4 | 2 | 1 | 4 | **13** |
| 24 | First-run coach marks for the three core gestures | N | N002 | 4 | 2 | 1 | 4 | **13** |
| 25 | In-app help per control (long-press "?" or hover) instead of README | Z,N | Z031,N022 | 4 | 2 | 1 | 4 | **13** |
| 26 | Mask by cavity / curvature / normal direction | Z,C | Z037,C023 | 4 | 3 | 1 | 4 | **12** |
| 27 | Command scripts (text) for automation and tests | C | C050 | 4 | 3 | 1 | 4 | **12** |
| 28 | Adjust last operation: change remesh/decimate/retopo parameters after running | Z | Z123 | 4 | 3 | 2 | 4 | **11** |
| 29 | History brush: undo locally by painting | Z | Z140 | 4 | 3 | 2 | 4 | **11** |
| 30 | One selection concept convertible between mask, group, hide and layer | C,N | C026,N004 | 4 | 3 | 2 | 4 | **11** |
| 31 | Scene tree with groups, parenting, drag-to-reorder | N,C | N006,C010 | 4 | 3 | 2 | 4 | **11** |
| 32 | Stage-aware workflow: "next stage" button (remesh → retopo → subdivide → detail) | Z,N,C | Z043,N021,C009 | 4 | 3 | 2 | 4 | **11** |
| 33 | Posing with rotate gizmo + topological mask | Z,C | Z064,C071 | 4 | 3 | 2 | 4 | **11** |
| 34 | Gizmo deformers: bend, twist, taper, lattice | Z,N,C | Z067,N022,C071 | 4 | 4 | 2 | 4 | **10** |
| 35 | Conflict detection and per-binding reset when rebinding | Z | Z152 | 3 | 1 | 1 | 3 | **10** |
| 36 | Long-press-drag on any slider icon scrubs its value | Z | Z032 | 3 | 1 | 1 | 3 | **10** |
| 37 | Pivot dot shown while orbiting | N | N012 | 3 | 1 | 1 | 3 | **10** |
| 38 | Drag down a list column to toggle many rows | N | N006 | 3 | 1 | 1 | 3 | **10** |
| 39 | Shift-smooth brush with its own remembered settings | Z | Z121 | 3 | 1 | 1 | 3 | **10** |
| 40 | Mouse wheel + modifier mapped to any parameter | C | C030 | 3 | 1 | 1 | 3 | **10** |
| 41 | Show memory and vertex budget before heavy operations | N | N018 | 3 | 1 | 1 | 3 | **10** |
| 42 | Two-fingers-down-lift-one continues as an orbit when no background is visible | N | N012 | 3 | 2 | 1 | 3 | **9** |
| 43 | Camera undo stack (separate from model undo) | Z | Z110 | 3 | 2 | 1 | 3 | **9** |
| 44 | Named camera views with attached reference images | N | N012,N011 | 3 | 2 | 1 | 3 | **9** |
| 45 | View cube / snap cube for one-tap axis views | Z,N,C | Z125,N018,C007 | 3 | 2 | 1 | 3 | **9** |
| 46 | Brush packs: import/export brushes with alphas and settings | N,C | N022,C086 | 3 | 2 | 1 | 3 | **9** |
| 47 | Remesh density shown as a visible size, not a vertex count | N,C | N007,C018 | 3 | 2 | 1 | 3 | **9** |
| 48 | Select what I just sculpted (mask / group changed points) | Z | Z137,Z138 | 3 | 2 | 1 | 3 | **9** |
| 49 | Selection sets: named masks/groups stored per object | Z,C | Z097,C026 | 3 | 2 | 1 | 3 | **9** |
| 50 | Two-finger placement: first finger moves, second scales/rotates | N | N004 | 3 | 2 | 1 | 3 | **9** |
| 51 | Ghost objects (visible, unpickable) | C | C010 | 3 | 2 | 1 | 3 | **9** |
| 52 | Task-first "New" sheet for returning users (Sculpt, Blockout, Paint, Retopo) | C | C063 | 3 | 2 | 1 | 3 | **9** |
| 53 | Searchable in-app glossary/cheat sheet | N | N022 | 3 | 2 | 1 | 3 | **9** |
| 54 | Version history for projects (keep N recent saves) | Z | Z109 | 3 | 2 | 1 | 3 | **9** |
| 55 | Paint channel on any brush (sculpt and paint in one stroke) | N,C | N015,C025 | 3 | 2 | 1 | 3 | **9** |
| 56 | Straight-line and snap-continue stroke helpers | Z,N | Z085,N013 | 3 | 2 | 1 | 3 | **9** |
| 57 | Plane locks for flatten/planar to stop drift | N | N004 | 3 | 2 | 1 | 3 | **9** |
| 58 | Front-only, connected-only and protect filters per brush | N | N013 | 3 | 2 | 1 | 3 | **9** |
| 59 | Navigation presets: ZBrush, Blender, Maya | C | C005 | 3 | 2 | 1 | 3 | **9** |
| 60 | Stylus side-button bindings | N,C | N002,C007 | 3 | 2 | 1 | 3 | **9** |
| 61 | Accessibility window: on-screen orbit/pan/zoom buttons | N | N003 | 3 | 2 | 1 | 3 | **9** |
| 62 | Left-handed mirror layout | N,Z | N002,Z132 | 3 | 2 | 1 | 3 | **9** |
| 63 | Silhouette thumbnail | Z | Z158 | 3 | 2 | 1 | 3 | **9** |
| 64 | Reference image planes per view | N,C | N011,C005 | 3 | 2 | 1 | 3 | **9** |
| 65 | Turntable / video export | Z,C | Z095,C055 | 3 | 2 | 1 | 3 | **9** |
| 66 | Grid and snapping for curves and gizmo | N,C | N018,C088 | 3 | 2 | 1 | 3 | **9** |
| 67 | Device-aware defaults (Android tier, RAM) for max vertices | N | N018,N021 | 3 | 2 | 1 | 3 | **9** |
| 68 | Depth masking / conditions as a brush filter, never sticky | N,C | N013,C023 | 3 | 3 | 1 | 3 | **8** |
| 69 | PBR vertex paint (roughness, metalness) | N | N015 | 3 | 3 | 1 | 3 | **8** |
| 70 | More stroke modes: roll, spray, lock+intensity, curve along path | Z,N,C | Z087,N013,C021 | 3 | 3 | 1 | 3 | **8** |
| 71 | glTF and USD export with layers as morph targets | N | N005 | 3 | 3 | 1 | 3 | **8** |
| 72 | Macro recording from the command log | Z | Z106 | 3 | 3 | 1 | 3 | **8** |
| 73 | Retopo guides and density painting | Z,N,C | Z127,N004,C035 | 3 | 3 | 1 | 3 | **8** |
| 74 | Adjust last stroke strength | Z | Z123 | 3 | 3 | 2 | 3 | **7** |
| 75 | History markers that brushes and commands can use | Z | Z056,Z117 | 3 | 3 | 2 | 3 | **7** |
| 76 | Project detail from any history point | Z | Z117 | 3 | 3 | 2 | 3 | **7** |
| 77 | Topological mask by dragging from the gizmo | Z | Z115 | 3 | 3 | 2 | 3 | **7** |
| 78 | Instances (linked copies) and clones | N,C | N006,C044 | 3 | 3 | 2 | 3 | **7** |
| 79 | Paint layers with blend modes | N,C | N017,C040 | 3 | 3 | 2 | 3 | **7** |
| 80 | Apply last action to all selected objects | Z | Z005 | 3 | 3 | 2 | 3 | **7** |
| 81 | Live boolean preview while sculpting | Z | Z154 | 3 | 3 | 2 | 3 | **7** |
| 82 | Repeaters: array, radial, mirror, curve as non-destructive parents | N,Z | N006,Z100 | 3 | 4 | 2 | 3 | **6** |
| 83 | VDM / 3D stamp brushes | Z,N,C | Z004,N022,C090 | 3 | 4 | 2 | 3 | **6** |
| 84 | Live link to Blender (send and receive) | N,Z | N022,Z103 | 3 | 4 | 2 | 3 | **6** |
| 85 | Proxy pose (temporary low-res to pose) | Z | Z155 | 3 | 4 | 2 | 3 | **6** |
| 86 | Memory-budgeted undo with per-step size shown | N | N019 | 2 | 1 | 1 | 2 | **6** |
| 87 | Stroke offset for finger sculpting on small screens | N | N013 | 2 | 1 | 1 | 2 | **6** |
| 88 | Fade paint to judge form | Z | Z156 | 2 | 1 | 1 | 2 | **6** |
| 89 | Per-step camera restore on undo (option) | N | N019 | 2 | 1 | 1 | 2 | **6** |
| 90 | Manual retopo tools (strokes, quads) on touch | C,N | C036,N022 | 3 | 5 | 2 | 3 | **5** |
| 91 | Tree drag with modifier to boolean (Shift merge, Ctrl subtract) | C | C045 | 2 | 2 | 1 | 2 | **5** |
| 92 | Measure tool with units | N,C | N004,C080 | 2 | 2 | 1 | 2 | **5** |
| 93 | Light theme and high-contrast option | N,C | N003,C030 | 2 | 2 | 1 | 2 | **5** |
| 94 | Haptic tick on detents (snap views, sticky toggles, long-press) | Z | Z151 | 2 | 2 | 1 | 2 | **5** |
| 95 | Python or Lua scripting over the command registry | Z,C | Z015,C049 | 3 | 5 | 3 | 3 | **4** |
| 96 | Voxel/volume mode for blockout with booleans | C | C074,C016 | 3 | 5 | 3 | 3 | **4** |
| 97 | 3D mouse support | Z,N,C | Z111,C078 | 2 | 3 | 1 | 2 | **4** |
| 98 | Gamepad / MIDI controller bindings | N | N003 | 2 | 3 | 1 | 2 | **4** |
| 99 | Soft booleans (bevelled joins) | C | C016 | 2 | 4 | 2 | 2 | **2** |
| 100 | Plugin packages bundling brushes, materials, scripts | C | C083 | 2 | 4 | 3 | 2 | **1** |

## Top 50 workflows worth preserving

Conventions artists already have in their hands. Keep them exactly; most are already in our app (see 01).

| # | Workflow | Products | Evidence | Why keep it | Impact | Difficulty | Risk | User value | Priority |
|---|---|---|---|---|---|---|---|---|---|
| 1 | Drag on empty space to orbit with the drawing tool still active | Z,N,C | Z018,N012,C005 | Navigation never needs a tool change | 5 | 1 | 1 | 5 | **18** |
| 2 | One finger/pen on model sculpts, on background orbits | Z,N | Z021,N012 | The touch default every touch sculptor expects | 5 | 1 | 1 | 5 | **18** |
| 3 | Two-finger pan and pinch zoom toward the fingers | Z,N | Z020,N012 | Universal touch grammar | 5 | 1 | 1 | 5 | **18** |
| 4 | Two-finger tap undo, three-finger tap redo | Z,N | Z022,N019 | Fastest possible undo on a tablet | 5 | 1 | 1 | 5 | **18** |
| 5 | Ctrl inverts, Shift smooths on desktop | Z,C | Z019,C020 | Muscle memory across apps | 5 | 1 | 1 | 5 | **18** |
| 6 | Subdivision levels: big forms low, detail high | Z,N,C | Z059,N007,C043 | Core non-linear detailing | 5 | 1 | 1 | 5 | **18** |
| 7 | Voxel remesh for even topology while blocking | Z,N,C | Z075,N007,C013 | Topology-free blocking | 5 | 1 | 1 | 5 | **18** |
| 8 | Three-finger drag for brush size and strength | Z,N | Z021,N003 | Brush params without UI | 4 | 1 | 1 | 4 | **14** |
| 9 | Shift snaps orbit to axis views | Z,N,C | Z019,N012,C005 | Instant orthographic checks | 4 | 1 | 1 | 4 | **14** |
| 10 | Ctrl + drag off-model draws a mask shape | Z | Z061 | Start location chooses the target | 4 | 1 | 1 | 4 | **14** |
| 11 | Right-drag orbits anywhere, Alt/Shift pan, Ctrl zoom | Z,C | Z018,C005 | Navigation over the model on desktop | 4 | 1 | 1 | 4 | **14** |
| 12 | HD regional windows for beyond-RAM detail | Z | Z060 | Unique scaling story | 4 | 1 | 1 | 4 | **14** |
| 13 | Dynamic topology with detail tied to screen or brush | Z,N,C | Z077,N007,C013 | Detail where you need it | 4 | 1 | 1 | 4 | **14** |
| 14 | Sculpt layers with strength slider and bake | Z,N,C | Z089,N017,C011 | Non-destructive detail | 4 | 1 | 1 | 4 | **14** |
| 15 | Polypaint per vertex without UVs | Z,N,C | Z091,N015,C042 | Paint before topology is final | 4 | 1 | 1 | 4 | **14** |
| 16 | Polygroups as part IDs on one mesh | Z,N | Z062,N004 | Organise without splitting | 4 | 1 | 1 | 4 | **14** |
| 17 | Hide by rectangle/lasso, show all, invert hidden | Z,N,C | Z063,N004,C072 | Isolate regions | 4 | 1 | 1 | 4 | **14** |
| 18 | Live boolean preview before committing | Z,C | Z154,C016 | Hard-surface iteration | 4 | 1 | 1 | 4 | **14** |
| 19 | Auto retopology with a quad target | Z,N,C | Z078,N004,C035 | Clean topology in one step | 4 | 1 | 1 | 4 | **14** |
| 20 | Project detail from old to new topology | Z,N,C | Z117,N007,C044 | Safe retopo | 4 | 1 | 1 | 4 | **14** |
| 21 | Pressure curves for size and strength | Z,N,C | Z030,N013,C025 | Pen expressiveness | 4 | 1 | 1 | 4 | **14** |
| 22 | Space opens a quick menu/pie at the cursor | Z,C | Z070,C008 | Tools where the hand is | 4 | 1 | 1 | 4 | **14** |
| 23 | Same layout on every device | N | N002 | Consistency (Bolt's rule) | 4 | 1 | 1 | 4 | **14** |
| 24 | Ctrl+D subdivide, D / Shift+D step levels | Z | Z070 | Shared industry shortcut | 3 | 1 | 1 | 3 | **10** |
| 25 | Morph target + Morph brush | Z | Z090 | Local restore | 3 | 1 | 1 | 3 | **10** |
| 26 | Ctrl+W group masked | Z | Z070 | Shared shortcut | 3 | 1 | 1 | 3 | **10** |
| 27 | Mask blur, sharpen, grow, shrink | Z,N,C | Z138,N004,C026 | Mask refinement | 3 | 1 | 1 | 3 | **10** |
| 28 | Extract shell from mask | Z,N | Z162,N004 | Clothes and armour | 3 | 1 | 1 | 3 | **10** |
| 29 | Insert mesh by click-drag (position then size) | Z,N | Z120,N004 | Kitbashing | 3 | 1 | 1 | 3 | **10** |
| 30 | Curve tool for tubes, stitches, zippers | Z,N | Z139,N004 | Repeated detail along a path | 3 | 1 | 1 | 3 | **10** |
| 31 | Bake normal and displacement maps | Z,N,C | Z059,N007,C034 | Delivery | 3 | 1 | 1 | 3 | **10** |
| 32 | Falloff curve editor with presets | N,C | N013,C025 | Brush profile control | 3 | 1 | 1 | 3 | **10** |
| 33 | Alphas with follow-stroke, fixed and random rotation | Z,N,C | Z086,N013,C024 | Texture detail | 3 | 1 | 1 | 3 | **10** |
| 34 | Lazy mouse / rope for clean lines | Z,N,C | Z085,N013,C069 | Precision | 3 | 1 | 1 | 3 | **10** |
| 35 | Drag rectangle stamp | Z,N | Z087,N013 | Precise stamps | 3 | 1 | 1 | 3 | **10** |
| 36 | Brush keys 1-9 | C | C008 | Fast switching | 3 | 1 | 1 | 3 | **10** |
| 37 | Stroke recorder and replay | Z,C | Z070,C101 | Repeat marks | 3 | 1 | 1 | 3 | **10** |
| 38 | History timeline scrub | Z | Z096 | Visual undo | 3 | 1 | 1 | 3 | **10** |
| 39 | Studio / best preview render | Z,N | Z095,N010 | Presentation in-app | 3 | 1 | 1 | 3 | **10** |
| 40 | Matcap materials for reading form | Z,N | Z093,N009 | Form legibility | 3 | 1 | 1 | 3 | **10** |
| 41 | Wireframe (Shift+F) and flat shading toggles | Z,N,C | Z070,N018,C088 | Topology inspection | 3 | 1 | 1 | 3 | **10** |
| 42 | Orthographic toggle (P / keypad 5) | Z,C | Z070,C004 | Shared shortcut | 3 | 1 | 1 | 3 | **10** |
| 43 | F frames the selection | Z,C | Z070,C005 | Shared shortcut | 3 | 1 | 1 | 3 | **10** |
| 44 | Symmetry X/Y/Z toggles with X key | Z | Z070 | Shared shortcut | 3 | 1 | 1 | 3 | **10** |
| 45 | Mirror and weld | Z,N | Z050,N016 | Fix asymmetric topology | 3 | 1 | 1 | 3 | **10** |
| 46 | Decimate preserving paint | Z,N | Z101,N007 | Export and print | 3 | 1 | 1 | 3 | **10** |
| 47 | Memory-budgeted undo | N | N019 | Avoid OOM on tablets | 3 | 1 | 1 | 3 | **10** |
| 48 | Solo mode | Z,N | Z026,N002 | Focus | 3 | 1 | 1 | 3 | **10** |
| 49 | Keypad axis views | C | C004 | Shared shortcut | 2 | 1 | 1 | 2 | **6** |
| 50 | Reduce motion option | N | N003 | Accessibility | 2 | 1 | 1 | 2 | **6** |

## Top 50 workflows worth replacing

Workflows that cost more than they give, with the replacement this research recommends.

| # | Workflow | Seen in | Evidence | Replace with | Impact | Difficulty | Risk | User value | Priority |
|---|---|---|---|---|---|---|---|---|---|
| 1 | Modifier keys as the only way to mask, smooth or invert on touch | Z,Us | Z019,13 | Visible sticky modifier buttons + optional wheel | 5 | 2 | 1 | 5 | **17** |
| 2 | Object tab with 18 sections (ours) | Us | 13 A-01 | Intent-grouped pages | 5 | 2 | 1 | 5 | **17** |
| 3 | Finding features in deep palettes / long inspector tabs | Z,Us | Z159,13 | Command search + intent-grouped panels | 5 | 3 | 1 | 5 | **16** |
| 4 | Reminder popup instead of autosave | N | N005 | Background incremental snapshots | 5 | 3 | 2 | 5 | **15** |
| 5 | Manual Store Config for preferences and layouts | Z | Z072 | Autosave every setting | 4 | 1 | 1 | 4 | **14** |
| 6 | Save that silently overwrites on second tap | Z,N | Z027,N022 | Explicit Save vs Save copy; versions | 4 | 1 | 1 | 4 | **14** |
| 7 | Operations that wipe all undo history | Z | Z096 | Swap snapshots (we already do this) | 4 | 1 | 1 | 4 | **14** |
| 8 | Non-undoable merges, deletes and folder ops | Z,C | Z058,C040 | Every scene edit undoable | 4 | 2 | 1 | 4 | **13** |
| 9 | Several overlapping remeshers with unclear roles | N | N007 | One "Rebuild" panel with goal presets (even, quads, fewer) | 4 | 2 | 1 | 4 | **13** |
| 10 | Need for empty canvas to orbit | Z | Z018 | Fallbacks: right-drag, two-down-lift-one, navigation buttons | 4 | 2 | 1 | 4 | **13** |
| 11 | Docs outside the app (README, videos) | Z,N,C,Us | N022,C060 | In-app help and glossary | 4 | 2 | 1 | 4 | **13** |
| 12 | Hard-coded shortcuts (ours) | Us | 13 A-02 | Registry bindings | 4 | 3 | 1 | 4 | **12** |
| 13 | Typed transform values as the only rotate/scale (ours) | Us | 13 A-10 | Full gizmo | 4 | 3 | 1 | 4 | **12** |
| 14 | Rooms per pipeline stage | C | C053 | One workspace with contextual panels | 4 | 3 | 2 | 4 | **11** |
| 15 | Three different mask concepts (Freeze, Hide, Pose) | C | C026,C079 | One selection model with conversions | 4 | 3 | 2 | 4 | **11** |
| 16 | Mid-drag modifier-release chords for zoom/roll | Z,N | Z018,N012 | Right-drag/Ctrl-drag and two-finger gestures | 3 | 1 | 1 | 3 | **10** |
| 17 | 3-key brush chords | Z | Z070 | Search + numbered slots + pies | 3 | 1 | 1 | 3 | **10** |
| 18 | Separate symmetry checkbox per transform tool | N | N004 | One symmetry state with a per-tool override badge | 3 | 1 | 1 | 3 | **10** |
| 19 | Background save that looks done before it is | C | C059 | Progress until fsync completes | 3 | 1 | 1 | 3 | **10** |
| 20 | Embedded editor with another app's conventions | Z | Z098 | One grammar everywhere | 3 | 1 | 1 | 3 | **10** |
| 21 | Pivot you can't see | N | N012 | Pivot dot + double-tap to set | 3 | 1 | 1 | 3 | **10** |
| 22 | Hidden gestures (four-finger tap, lift-one orbit) | N | N021 | Coach marks + gesture list in Settings > Touch | 3 | 1 | 1 | 3 | **10** |
| 23 | Task dialog before any mark | C | C063 | Sphere ready; task sheet only under New | 3 | 1 | 1 | 3 | **10** |
| 24 | Overloaded RMB short/long/hold | C | C069 | Right-click = context menu only | 3 | 1 | 1 | 3 | **10** |
| 25 | Per-object undo stacks | Z | Z056 | Scene-wide history (we have it) | 3 | 1 | 1 | 3 | **10** |
| 26 | Destructive topology ops delete multires | N,Z | N007 | Reproject levels/detail automatically after remesh | 4 | 4 | 3 | 4 | **9** |
| 27 | Editing menu.cpp to customise menus | C | C029 | Long-press-drag items into toolbars/pies | 3 | 2 | 1 | 3 | **9** |
| 28 | Choose a paint mode before painting | C | C042 | One paint model; bake to maps on export | 3 | 2 | 1 | 3 | **9** |
| 29 | Visibility-chosen boolean operation | N | N006 | Explicit op badge on each object | 3 | 2 | 1 | 3 | **9** |
| 30 | List order decides boolean targets | Z | Z051 | Explicit targets in the tree | 3 | 2 | 1 | 3 | **9** |
| 31 | Local vs World symmetry choice | N | N016 | World symmetry + "symmetry from gizmo" as one explicit action | 3 | 2 | 1 | 3 | **9** |
| 32 | Remesh size as voxel resolution or vertex count | N,C,Us | N007,C018 | Visible density preview | 3 | 2 | 1 | 3 | **9** |
| 33 | Separate camera undo with 14 steps and no hotkey | Z | Z110 | Camera history gesture (e.g. two-finger long-press) | 3 | 2 | 1 | 3 | **9** |
| 34 | Sticky filters (conditions) that keep limiting strokes | C | C023 | Filters shown as chips on the brush, cleared per brush | 3 | 2 | 1 | 3 | **9** |
| 35 | Brush identity spread across files (ours) | Us | 13 A-03 | Brush descriptor table | 3 | 2 | 1 | 3 | **9** |
| 36 | Move tool as the only way to select objects (ours) | Us | 13 | Tap-select in any tool + scene list | 3 | 2 | 1 | 3 | **9** |
| 37 | Undo history only saved in one file type | Z | Z096 | History saved with the scene by default, trimmed | 3 | 3 | 1 | 3 | **8** |
| 38 | Two curve systems | N | N022 | One curve object with profiles and repeat modes | 3 | 3 | 1 | 3 | **8** |
| 39 | Ad-hoc start-up flags mirroring tools (ours) | Us | 13 A-05 | Command scripts over the registry | 3 | 3 | 1 | 3 | **8** |
| 40 | Polygroups only at lowest level | Z | Z049 | Groups stored per face at every level | 3 | 3 | 2 | 3 | **7** |
| 41 | Hover-dependent element targeting | Z | Z153 | Touch-down preview, lift to commit | 3 | 3 | 2 | 3 | **7** |
| 42 | Remeshing breaks stored selections | Z | Z097 | Reproject selections after topology change | 3 | 4 | 2 | 3 | **6** |
| 43 | Plugin for multi-object posing | Z | Z104 | Multi-object gizmo and mask in core | 3 | 4 | 2 | 3 | **6** |
| 44 | Proprietary scripting languages (ZScript, AngelScript) | Z,C | Z105,C049 | Command scripts now, a mainstream language later | 3 | 4 | 2 | 3 | **6** |
| 45 | Hover-to-open panels | C | C033 | Tap-to-open sheets | 2 | 1 | 1 | 2 | **6** |
| 46 | Voxel vs surface as per-object modes that lose data | C | C011,C075 | Volume blockout that converts once, keeping layers | 3 | 4 | 3 | 3 | **5** |
| 47 | Layers only created at top level | Z | Z089 | Layers at any level, propagated | 3 | 4 | 3 | 3 | **5** |
| 48 | Hand-written settings parsers (ours) | Us | 13 A-04 | One schema for load and save | 2 | 2 | 1 | 2 | **5** |
| 49 | Bespoke per-tool result reporting (ours) | Us | 13 A-06 | One result/toast channel | 2 | 2 | 1 | 2 | **5** |
| 50 | Fixed Smooth for Shift (ours) | Us | Z121 | Choosable Shift brush with own settings | 2 | 2 | 1 | 2 | **5** |

## Top 50 modern UX improvements

Improvements none of the three does fully, drawn from modern app practice and the gaps above.

| # | Improvement | Why | Impact | Difficulty | Risk | User value | Priority |
|---|---|---|---|---|---|---|---|
| 1 | Command palette with fuzzy search, recent commands and inline shortcut hints | Ranks as the single biggest discoverability gain; works with keyboard and touch | 5 | 2 | 1 | 5 | **17** |
| 2 | Every edit undoable, including scene structure and settings changes | Trust; lets users explore | 5 | 2 | 1 | 5 | **17** |
| 3 | Contextual action bar that follows the selection (object, mask, curve, retopo) | Keeps the right 4-6 actions within thumb reach; replaces deep tabs | 5 | 3 | 2 | 5 | **15** |
| 4 | Autosave with crash-safe incremental snapshots and version list | Removes the top data-loss complaints of all three products | 5 | 3 | 2 | 5 | **15** |
| 5 | Toasts with Undo for destructive actions | Safety without confirm dialogs | 4 | 1 | 1 | 4 | **14** |
| 6 | First-run coach marks (3 gestures), skippable and replayable | Onboarding without a manual | 4 | 2 | 1 | 4 | **13** |
| 7 | Progressive disclosure: Simple vs Advanced per panel | Beginners see 5 controls, experts see all | 4 | 2 | 1 | 4 | **13** |
| 8 | Inline long-press help card on any control | Discoverability on touch without hover | 4 | 2 | 1 | 4 | **13** |
| 9 | Per-device performance profile (auto max verts, LOD) on first run | Android tiers differ 10x | 4 | 2 | 1 | 4 | **13** |
| 10 | Brush presets with thumbnails, favourites, folders and sharing | Personal kits | 4 | 2 | 1 | 4 | **13** |
| 11 | User pies and toolbars built by long-press-drag from any command | Customisation without files | 4 | 2 | 1 | 4 | **13** |
| 12 | Starter scenes and base meshes (head, body, hands, animals) | Fast start, Nomad's most-viewed downloads | 4 | 2 | 1 | 4 | **13** |
| 13 | Palm rejection that ignores large contact areas and touches while pen is near (already partly) | Stops accidental undo | 4 | 2 | 1 | 4 | **13** |
| 14 | Crash recovery that reopens the last snapshot and explains what was kept | Trust | 4 | 2 | 1 | 4 | **13** |
| 15 | Command scripts and macro recording from the command log | Automation and tests share one path | 4 | 3 | 1 | 4 | **12** |
| 16 | Adjust-last-operation sheet for every parameterised command | Try values without undo cycles | 4 | 3 | 2 | 4 | **11** |
| 17 | Live previews for heavy ops (density checkerboard, boolean ghost, retopo wireframe preview) | See before you commit | 4 | 3 | 2 | 4 | **11** |
| 18 | Non-blocking background tasks with progress and cancel (remesh, retopo, bake) | App stays responsive | 4 | 3 | 2 | 4 | **11** |
| 19 | Unified selection model (mask/group/hide/layer) with chips showing what's active | Fewer hidden states | 4 | 3 | 2 | 4 | **11** |
| 20 | Scene tree with groups, instances, solo, ghost and drag-reorder | Scale to 50+ parts | 4 | 3 | 2 | 4 | **11** |
| 21 | Empty states that teach (e.g. Layers: "Add a layer to sculpt without changing the base") | Help in place | 3 | 1 | 1 | 3 | **10** |
| 22 | Visible budget meters (vertices, memory, undo) before heavy ops | Prevents OOM crashes (Nomad FAQ) | 3 | 1 | 1 | 3 | **10** |
| 23 | Numeric entry by tapping any handle or value | Precision on touch | 3 | 1 | 1 | 3 | **10** |
| 24 | Hold-to-repeat undo/redo gesture | Fast multi-step undo | 3 | 1 | 1 | 3 | **10** |
| 25 | Cross-device project files with the same UI (already a rule) | Continuity | 3 | 1 | 1 | 3 | **10** |
| 26 | Settings search | Find a setting by name | 3 | 1 | 1 | 3 | **10** |
| 27 | In-app glossary and gesture cheat sheet | Answers "how do I invert the mask" in the app | 3 | 2 | 1 | 3 | **9** |
| 28 | Left-handed layout mirror | Accessibility and comfort | 3 | 2 | 1 | 3 | **9** |
| 29 | Brush filters as visible chips (front only, connected, protect) | No sticky hidden filters | 3 | 2 | 1 | 3 | **9** |
| 30 | Gesture editor in Settings with conflict detection | Safe customisation | 3 | 2 | 1 | 3 | **9** |
| 31 | Navigation presets (ZBrush, Blender, Maya) | Lower switching cost | 3 | 2 | 1 | 3 | **9** |
| 32 | Time-lapse and turntable share (already partly) | Artist sharing | 3 | 2 | 1 | 3 | **9** |
| 33 | Reference image planes and view-linked references | Proportions | 3 | 2 | 1 | 3 | **9** |
| 34 | Silhouette and value-check view modes | Form judgement | 3 | 2 | 1 | 3 | **9** |
| 35 | Pen hover preview of brush footprint and target element | Precision; replaces desktop hover on tablets | 3 | 2 | 1 | 3 | **9** |
| 36 | Camera history (back/forward views) | Recover the view | 3 | 2 | 1 | 3 | **9** |
| 37 | Accessibility: on-screen navigation buttons and one-finger modes | Users who can't multitouch | 3 | 2 | 1 | 3 | **9** |
| 38 | Snapping system shared by gizmo, curves, insert | One mental model | 3 | 3 | 1 | 3 | **8** |
| 39 | glTF/USD export with presets for Blender, Unreal, Unity | Pipeline | 3 | 3 | 1 | 3 | **8** |
| 40 | Stage-aware hints ("mesh is stretched: Remesh?") | Guides the pipeline | 3 | 3 | 2 | 3 | **7** |
| 41 | Live link with Blender | Pipeline round trip | 3 | 4 | 2 | 3 | **6** |
| 42 | GPU compute for whole-mesh ops (smooth all, remesh) with CPU fallback | Keeps heavy ops interactive | 3 | 4 | 2 | 3 | **6** |
| 43 | Reduce motion everywhere (already) + respects OS setting | Accessibility | 2 | 1 | 1 | 2 | **6** |
| 44 | Dynamic type / interface size (already) + per-panel density | Readability | 2 | 1 | 1 | 2 | **6** |
| 45 | Haptics on long press, snaps and toggles (Android vibration API) | Confirms gestures without looking | 2 | 2 | 1 | 2 | **5** |
| 46 | Theme tokens with light and high-contrast variants | Accessibility and daylight use | 2 | 2 | 1 | 2 | **5** |
| 47 | Telemetry-free local usage stats shown to the user (most-used commands → suggest favourites) | Personalisation without privacy cost | 2 | 2 | 1 | 2 | **5** |
| 48 | Two-finger long-press = eyedropper for brush/material/colour under fingers | Fast sampling | 2 | 2 | 1 | 2 | **5** |
| 49 | Plugin/script API over the command registry (later) | Ecosystem | 3 | 5 | 3 | 3 | **4** |
| 50 | Split view: orthographic reference view next to perspective | Hard-surface precision | 2 | 4 | 2 | 2 | **2** |
