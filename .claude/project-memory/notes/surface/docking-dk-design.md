# Docking DK1-DK3: design (2026-11-03)

Built from the docking mock (https://claude.ai/artifact/PhtFwCVdgKqMcKbg5awvHb, D1-D5) and plan v2's DK rows, against
odin-sculpt at #556. Bolt approved the Surface plan with its defaults on 2026-11-03 12:43.

## What exists (checked in src/app)
- `View_Grid` (grid.odin): a binary `Grid_Tree` of up to four leaves; pane 0 is the main view (tools, overlay, heavy
  passes), panes 1-3 each hold one `Second_View` (`g.views`), drawn at rest into `app.panes[i]` (one `Picture` each).
- Lens gestures (lens_areas.odin): corner drag splits/joins, the camera chip carries a pane (swap, dock on an edge),
  divider menu, double tap evens, drag to an edge closes; every change is a layout step (`Grid_Step`, undo ordered
  against History). Maximise per view pane. Work in any pane lends the main role. View windows on desktops.
- Workspaces keep `panes <tree>` and `pane N camera pass shading` lines.

## Words (one meaning each)
The mock's "frame" is our **pane** (the code already says pane, and "frame" means the render frame here). A pane holds
**tabs**; a tab has a **kind** (3D view now; Texture in DK2; UVs, Graph, Stack, References later). A pane that leaves
the tree is a **floating pane** (DK3). The docks-and-cards words (Dock, Window, Card, Section) stay for the chrome;
panes never become Windows, so the two systems never share a name.

## Rules
1. The main view's pane holds only the main view. The tools, the overlay, Viewport_Input and the heavy passes all
   live there; hiding it behind a tab would leave the app with no place to sculpt. A 2D editor that wants the whole
   screen is Maximised (DK3). (Lifted only if the main role ever follows focus, D4.)
2. Only the active tab of a pane draws. A pane keeps one `Picture`, whatever its tab count: switching tabs changes
   the picture's key and it is drawn again once, at rest. No new GPU target per tab, no memory per tab beyond its
   ~150-byte state.
3. Limits: 8 tabs a pane; the tree stays at 4 docked panes (a tablet has room for about four); 2 floating panes
   (DK3). Tabs suit kinds you switch between; two 3D views still read best side by side (the + tip says so).
4. The tree stays binary. The mock's rows of n children are the same layouts; the existing even/lined-up/divider math
   already treats a run of same-way splits as one row, so n-ary nodes would add churn and no capability.
5. Every structural change (a tab added, closed, moved; a pane floated or docked) is a layout step, undone in order
   with History as today. Switching tabs is not a step (as picking a camera is not).

## DK1: tabs in panes (this PR)
- Data: `Pane_Tab {kind: Tab_Kind, view: Second_View}`; `Pane_Tabs {tabs: [PANE_TABS]Pane_Tab, count, active}`;
  `View_Grid.tabs: [GRID_VIEWS]Pane_Tabs` replaces `views`; `grid_view(g, pane) -> ^Second_View` is the active
  tab's view, the one accessor every reader uses (59 call sites move to it). `Grid_Step` keeps the tabs.
- Head: the view pane's chip row becomes a tab strip. One tab looks exactly as today (camera chip, Shows, Link,
  Maximise, window). With two or more, the tabs share one glass pill as segments (iPadOS segmented control, Safari
  tab groups): the active segment is the camera chip (dot, name, sub, chevron = its menu, drag = carry the pane as
  today), the others show their dot and name dimmed, a tap makes one active. Narrow panes shrink inactive tabs to
  their dots first. A `+` chip after the strip adds a 3D view tab (the next axis camera not shown in the pane).
- The active tab's menu (the camera list) ends with New tab and Close tab (Close only with two or more).
- Commands (Search, scripts, keys): `Pane_Tab_New`, `Pane_Tab_Close`, `Pane_Tab_Next` (Ctrl+Tab),
  `Pane_Tab_Previous` (Ctrl+Shift+Tab); arg 0 = the view pane last pressed, else 1-3.
- Layout lines: each `pane N <camera> <pass> [shading]` line is one tab of pane N, in order; `pane_tab N A` when
  the active tab is not the first. One-tab layouts write what they write today. A `panes` line resets the tabs.
- Exit stats: `pane_tabs=` (tabs per view pane, e.g. 1,2), `pane_tab_switches=`, `pane_tab_adds=`, `pane_tab_closes=`.
- Cost: none per frame (one more loop over at most 8 tabs while laying out a head).

## DK2: 2D tab kinds and the Texture tab
- `Tab_Kind.Texture`; a 2D tab draws with the UI kit inside its pane rect (an image, a checker ground, a grid), so
  it costs no GPU picture and animates for real. `grid_view` returns nil for a 2D tab; readers that draw 3D skip it.
- The pane picture pass: kinds whose content is the scene seen flat (UVs in UE2, a channel of a texel layer in
  PT4) draw through one render entry, `render.pane_flat_draw(target, items, uv_rect)`, which rasterises UV-space
  triangles into the pane's existing `Picture` target at rest (the same "drawn at rest" rule as 3D panes). Built
  (2026-11-03): moved to UE2, its first real user, since it needs a new shader (a design stop of its own); the
  Texture tab needs none, as the kit draws the map the textured preview already holds.
- Texture tab (read-only): the selected object's maps as the Textures card lists them (Colour, Normal, Roughness,
  ...), a map chip to pick one, two-finger pan and pinch zoom (wheel and middle drag on a mouse), Fit, a texel grid
  past 8 pt a texel. Built #569-ish without an RGB/Alpha switch (needs a shader) or the 3D pointer's UV dot (UE2). Layout line `pane N Texture <map>`.
- `+` opens a kind list (3D view, Texture), each with an icon; a tab's chip shows its kind's icon.

## DK3: floating panes, Maximise, Overview, drag and drop
- Floating panes: up to 2, each `Pane_Tabs` with a rect in shares of the stage, See-through (0.3-1) with hold to
  peek, Pin (kept across layouts and spaces; never fades under a stroke), Minimise to a chip tray at the off-hand
  corner. A floating 3D tab draws at rest into its own Picture (two more pictures, made on first float, freed when
  the float closes). Desktop: Open in its own window through view_window.odin.
- Drag and drop: a tab or a pane dragged by its head; over a pane the five-way target (centre = join as a tab,
  arrows = split there; mouse-sized arrows grow to 56 pt for a finger), edge targets on the stage, Swap on the
  centre for a whole pane; a tinted landing rect while dragging; let go elsewhere = float. Reflow only on drop,
  animated with a scaled snapshot of each 3D picture and one real draw at the end (no per-frame target resize).
- Maximise: any pane (and any floating one) fills the stage Lens-style (top bar, rail and shelf float over it), its
  tab strip as a small island under the top bar; Full screen hides everything but a tab pill that fades after 2.6 s
  (swipe = next tab, Esc leaves). The main view maximised hides the view panes, as today's maximise does for panes.
- Overview: every pane and tab as cards on a map of the real layout (floating ones in a side list); tap = go there,
  drag a card onto a pane = move that tab, drag a pane's head onto another = swap. Opened from the layout chip in the
  top bar's Spaces dock (name and pane count; carries Restore while maximised). The touch-first way to rearrange.
- References tab (from the Wafer study): an image file shown flat, Sample reads its pixels.

## Compare table
| Part | Taken from | Why it still holds | Avoided | Done better |
|---|---|---|---|---|
| Tabs in a pane | Dear ImGui docking, VS Code | switching kinds in one place keeps the model big | ImGui's tab bar hiding at one tab (hides the buttons) | one tab looks as today; segments, not thin mouse tabs; 44 pt targets |
| One picture a pane | own rule (draw at rest) | a big mesh is never drawn twice while you work | a GPU target per tab | tab switch = one redraw at rest, 0 MB per tab |
| Layout steps | Blender areas | rearranging is cheap to try when undo is sure | Blender's area changes outside undo | undone in order with sculpt steps |
| Five-way target | Dear ImGui | precise splits with a mouse | small arrows for a finger | 56 pt arrows on touch, landing preview |
| Overview | iPadOS app switcher, Mission Control | touch has no precise aim at an arrow mid-drag | dragging small targets on glass | whole layout in view, big cards |
| Floating panes | iPadOS Slide Over, Windows | a graph or UVs over the model while painting | overlapping clutter as the norm | 2 at most, see-through, pin, docked stays the rule |
| Reflow | iPadOS motion | showing where things went | live resize of 3D targets every frame (17 reallocs in 280 ms) | snapshot slide, one real draw |

## Budgets
No new per-frame cost; a tab switch costs one picture draw at rest (the pane's p50 `pane_ms`); a reflow costs one
frame of rendering; floating 3D panes draw at rest like view panes (`pane_draws=` proves it).
