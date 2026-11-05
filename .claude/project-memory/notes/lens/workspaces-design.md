# Lens P0-2: workspaces

Spec: Lens report (https://claude.ai/artifact/LT1ZgSsMuUtFFtd7tm1RZw), "Recommendation" table and "Customisation
model" items 4, 5 and 6. This builds on P0-1's panel model (panel-model-design.md).

## What exists when done
- A **workspace** is a named layout. It holds:
  - which zones show: the brush bar (left rail), the view bar (right rail), the dock (the shelf), the modifier wheel and the action bar;
  - which panels are open;
  - the two columns and the pinned sections;
  - each floating panel's place and fold.
  It does not hold the scene, the brush or view toggles (wireframe, studio). The pass and the pane join in P0-4 and P0-5.
- **Four built-ins:**
  - **Sculpt** (the default) is exactly today's layout.
  - **Focus** hides both rails and has no panels open. It keeps the dock (the brush strip) and the wheel (the off-hand cluster).
  - **Inspect** hides the brush bar and the dock. Stats is docked on the left; Camera and Look are pinned in the right column; the Thumbnail floats open.
  - **Studio** pins Lights, Material and Environment in the right column, with the tray closed and the Thumbnail open as a mini view.
- **Your own workspaces.** "Save as new" makes "Workspace 2", "Workspace 3" and so on; they can be renamed and deleted. There are at most 8 of your own.
- **The switcher** sits in the top bar, left of the file name. It is a chip showing the name, with an amber dot while the live layout differs from the saved one. A tap opens a menu:
  - every workspace (the current one checked);
  - Save (the dot goes);
  - Save as new;
  - Revert to saved;
  - Reset to built-in (built-ins only);
  - Rename and Delete (your own only).
- **Switching keeps unsaved changes.** Each workspace keeps its live layout as well as its saved one, so switching away and back loses nothing. The dot says the two differ; Revert drops the live changes.
- **Anchors cannot be lost.** When a rail that holds an anchor is hidden, its anchors move into the top bar: Undo and Redo after Export, and Search and Palettes before History. The top bar never hides.
- **Recovery.** Reset panel positions (Settings > Interface) resets the live layout of the current workspace to its saved one. Shift held at start opens Sculpt as it ships (desktop).

## Code
- `src/app/workspaces.odin`:
  - `Zone :: enum u8 {Brush_Bar, View_Bar, Dock, Wheel, Action_Bar}` and `Kit_State.hidden: bit_set[Zone]`.
  - `Workspace{name: [32]u8, built_in: Maybe(Built_In), saved, live: string}`, where a layout is text. The `layout_write` lines are a subset of the settings lines: `window`, `column`, `pinned`, `open <Panel>…` and `hidden <Zone>…`. `layout_apply` resets to the default (`panels_default`, windows closed and unmoved) and then reads those lines through the same parsers settings_load uses, pulled out into `layout_line`.
  - Modified means `layout_write(app) != ws.saved`, checked once a frame with the temp allocator (a few hundred bytes).
  - Built-ins are text constants in the same form, so Reset to built-in is `saved = live = BUILT_IN[b]`.
- Settings:
  - `workspace <index> <built_in name|custom> <name escaped>`, followed by `workspace_saved <index> <line escaped>` and `workspace_live <index> <line escaped>`, written only for workspaces that differ from their built-in;
  - `workspace_current <index>`.
  - Older files have no workspace lines: the current layout becomes Sculpt's live layout, so nothing moves.
- Commands: `Workspace` (args = 4 + 8; checked when current; enabled when it exists), `Workspace_Save`, `Workspace_Save_As`, `Workspace_Revert`, `Workspace_Reset`, `Workspace_Rename` (a pick on screen) and `Workspace_Delete`. They have no keys by default (Edit keys can add some), and macros skip the ones that change the workspace list.
- Hiding zones: `kit_layout` skips `kit_brush_bar`, `kit_view_bar`, `kit_bottom_bar`, `kit_modifier_rail` or `kit_action_bar` for a hidden zone. `kit_left`/`kit_right` already fall back to the edge when the bar is not laid out (prev_layout returns zero). The anchors' extra buttons go in `kit_top_bar` behind `.Brush_Bar in hidden` / `.View_Bar in hidden`. Touch routing that keys on the dock or wheel being present (the wheel's `rail_*`) already handles `rail_side == .Off`; a hidden wheel is treated the same.
- Exit stats: `workspace=<name> workspace_modified=0|1 workspace_count= hidden=<zones>|none`.

## Not in this PR
Workspace files (export and import, P1), per-workspace bars (Arrange mode, P0-3, once the toolbar thread's zone bars land), and the pass and panes (P0-4, P0-5).

## Review fixes (architect, 2026-10-27)
- **Text is canonical.** Built-ins are stored as `layout_write(layout_apply(text))`. A test checks that write∘apply is the identity for each built-in. The x anchor is written relative to the hand, so a layout reads the same left-handed. `kit_mirror` now mirrors the pins too, and writes 0 rather than -0 (fixed in PR 1).
- **What `open` covers.** It holds only the column panels and the floating Stats, Thumbnail and Objects/Colors cards. Settings, Help, Macros and Library stay outside the layout. History is out too, because a long press on Undo opens it.
- **Wheel.** Use `rail_side_shown(k)` (`rail_side != .Off && .Wheel not in hidden`) wherever the code tests `rail_side == .Off`. The Wheel and Action bar zones AND with the existing `modifier_rail` and `action_bar` settings; they do not replace them.
- **Action bar.** The hidden check goes inside `action_bar_shown`.
- **Brush bar.** Hiding it ends a scrub that is under way. `rail_inset` guards `bar.y > 0`.
- **Closing what a zone opened.** Hiding a zone closes the browser, `bar_pop`, the dock menu and the scrub. `palette_anchor` comes from the top bar's Search when the view bar is hidden, and the Camera and Shading menus fall back to the top bar as well.
- **Dock.** `dock_shown` and `dock_stack` follow the hidden dock.
- **Top bar.** `LEFT`/`RIGHT` add 2 buttons per hidden rail. Below about 628 pt the file name goes first.
- **Workspace numbers.** Each workspace has a stable slot number that Delete never compacts, so key and pie bindings keep pointing at the right one.
- **Macros and scripts.** Macros skip the Workspace commands. Scripts refuse Save, Delete and Rename. Delete asks for confirmation, since the change is interface state outside History.
- **Settings file.** The top-level `window`/`column`/`pinned` lines stay as the live layout, so there is no version bump. Workspaces are applied after the window lines. An old file becomes Sculpt's saved and live layout, so no dot shows on the first start.
- **Escaping and testing.** The exit stat escapes the name. A `--workspace=<name>` flag is for scripted runs.
