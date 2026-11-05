# Split view with pane kinds (plan, 2026-11-01)

Bolt (2026-11-01 09:59): use the split view we have for the shader graph and UVs; compare and contrast; rewrite and enhance it to be flexible like the graph's view types; new mock.
Mock: https://claude.ai/artifact/Rm5R6Yi89MiR6CG7MRfmxe (source notes/surface/split-view-mock.html). Companion: plan.md (Surface content).

## Today (checked in src/app: grid.odin, lens_panes.odin, lens_areas.odin, thumbnail.odin, view_window.odin)
- `View_Grid` holds a `Grid_Tree` of up to four leaves (GRID_PANES 4): pane 0 is the main view (tools, heavy passes), panes 1-3 are `Second_View`s (camera Follow/axes/Free/Mirror, `Second_Pass` Silhouette..Render) drawn only at rest.
- Six presets, Lens corner drags split/join/swap/dock, divider grips (double tap evens, drag to edge closes), Maximise, layout undo ordered against History, workspaces keep the tree (`panes` line), work in any pane lends the main role, view windows (desktop OS windows).
- Every pane is a 3D view. The first Surface mock gave the graph a private Overlay/Split/Full and the UVs a fixed panel: a second and third arrangement system.

## Proposal
- Pane kinds: View (today's Second_View, and pane 0), UVs, Graph, Stack, Texture; later Render preview, Reference picture, Timeline. Kinds that one pane shows at a time (UVs, Graph, Stack, Texture) move when picked elsewhere.
- Four places for any kind: Docked (tree), Floating see-through (max two; head drag, corner resize, See-through slider, Hold to peek; Dock returns it), Full (others as chips), Sheet (phone: first pane fills, others are tabs in a two-height sheet). Floating 3D views draw at rest.
- The shelf follows the pane last touched (UV tools, node tools, brushes, texture paint tools); focus is the pane outline.
- Panes talk: seams drawn in 3D show in UVs, picked island lights in 3D, Texture paint shows on the model, Probe fills the graph and stack.
- Portrait: a side-by-side split is laid out stacked when its room is taller than wide (setting, on).
- Data: `Pane { kind, view: Second_View, ... per-kind state }`; tree unchanged; `floats: [2]Pane_Float {pane, rect in stage fractions, see_through}`; workspace lines `pane_kind N kind` and `float N x y w h a`, which older readers skip (verify the workspace parser ignores unknown lines before relying on it).
- Cost: 3D panes unchanged; other kinds are UI kit drawing (UVs of a big mesh need a render pass of UV-space triangles into the pane picture, at rest while sculpting).

## Stages (before Surface S1)
- V1 pane kinds (3D only at first: no visible change), kind chip, workspace lines.
- V2 floating panes + Full with chips.
- V3 shelf follows the focused pane.
- V4 portrait stacking and phone sheet.
- V5 Texture and Reference kinds; then S1+ adds UVs, Stack, Graph as kinds.

## Choices (defaults first)
1. Split view first (V1-V4), then Surface stages; vs Surface panes first and merge later.
2. Four docked + two floating; vs more docked.
3. Floating 3D views allowed, drawn at rest; vs floats only for 2D kinds.

## Revision 2026-11-01 10:34: docking (Bolt: tabs like imgui, windows like Windows/Linux, drag to rearrange like Blender, animated)
Mock: https://claude.ai/artifact/PhtFwCVdgKqMcKbg5awvHb (source notes/surface/docking-mock.html). Replaces V1-V4 with D1-D5:
- D1 frames and tabs: tree rows/columns of any number of children (binary splits read in), a frame holds tabs, a tab is a kind (3D view = today's view pane); tab bar replaces the chip head; workspace lines older apps skip; ships 3D-only.
- D2 drag and drop: tab or frame dragged by its bar; imgui five-way target over a frame (centre = tab, arrows = split), edge targets, Swap; landing preview rect; drop elsewhere pops out; each drop a layout undo step; reflow animated (snapshot rule below).
- D3 windows: pop out / dock back home, Pin (on top, kept across layouts and spaces, never fades under strokes), See-through + hold to peek, Minimise to a tray at the off-hand corner, Maximise/restore, Snap to a half, desktop "own OS window" via view-window code.
- D4 shelf follows the focused frame's active tab; portrait stacks side-by-side; phone: first frame fills, others are chips in a sheet.
- D5 Texture and Reference kinds; then UVs, Stack, Graph with the Surface stages.
Push-backs given to Bolt: pop-out is in-app on tablets (OS windows on desktop only); animate a scaled snapshot of 3D frames and render once at the end (no per-frame target realloc); show a landing preview while dragging, reflow only on drop; four states only (Docked, Floating, Minimised, Maximised) + Pin flag; tabs for kinds you switch between, not two 3D views; limits 6 docked, 3 floating, 8 tabs a frame.

## Revision 2026-11-01 11:50: full screen with tabs, Overview, the top bar

Bolt asked how a full-screened frame with several tabs looks, how to switch its tabs, and whether the top bar needs a redesign. Added to the docking mock (screen 3, https://claude.ai/artifact/PhtFwCVdgKqMcKbg5awvHb):
- Maximise (fills the stage, app around it): tabs stay on the frame's own bar (A, recommended). B, tabs moving into the top bar's middle island with Restore, is in the mock as a toggle; possible as a setting, not the default (tabs in two places, no room on a portrait iPad).
- Full screen (everything hidden): a pill at the top with leave, the tabs, prev/next and Overview; fades after 2.6 s, returns when the pointer reaches the top; swipe the pill to change tab (content slides), Ctrl+Tab, Shift+F/F11, Esc; dots on a phone.
- Overview (the better idea): every frame and tab as live cards on a map of the real layout; tap to go there, drag a card onto a frame to move the tab, drag a frame's head to swap; floating and minimised frames in a side list. The touch-first way to rearrange; drop targets stay for the mouse. Build it in D2 beside drag and drop.
- Top bar: no redesign. One new layout chip in the middle island (layout name and frame count, opens Overview, carries Restore while maximised; icon and count on iPad and phone); it replaces the rail's layout button.
- 11:58 Bolt clarified: "full screen" also means the Lens way, the view edge to edge with the top bar, rail and shelf floating over it (the app already does this for the main viewport, a Lens round 2 rule). The mock's Maximise now does exactly that; the maximised frame's tab bar becomes a small island at the top left under the top bar. Full screen (everything hidden, the tab pill) stays as the second, rarer step.
