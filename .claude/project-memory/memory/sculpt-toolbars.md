---
name: sculpt-toolbars
description: Remesh quick menu, own Shading/Camera rail buttons, customisable bars and dock swipe (Bolt feedback 2026-10-27)
metadata:
  type: project
  modified: 2026-10-27T18:52:56.277Z
---

Bolt's feedback 2026-10-27 (thread "Customise toolbars and remesh menu"):
- PR #207: press and hold Remesh opens a quick menu (density, Half/Same/Double, Remesh, More options); the right rail's combined View menu split into its own Shading and Camera buttons (commands Shading_Menu, Camera_Menu; Ortho moved into Camera).
- #209 merged: every bar customisable. Right rail (zone right_rail, max 16) and bottom tool strip (zone bottom_tools, max 8) hold any command; settings lines `bar_count <zone> N` and `bar <zone> <slot> <Command>` written only when changed. Dock keeps `dock ...` lines plus `dock <slot> command <Cmd>` and `dock_count N` (up to 42 slots, 6 pages). Customise bars mode (command Customise_Bars, Settings > Interface > BARS) shows a slot popover (move, remove, add, another command). Swiping the dock turns pages with a peek of the next page.
- The Figma UI thread asked for zone names; keep them stable (right_rail, bottom_tools) for its designs.
- Design notes and screenshots: /mnt/project-files/notes/toolbars/.

**Why:** Bolt wants every toolbar user-customisable, ZBrush-iPad base with Nomad/Procreate ideas ([[best-of-all-worlds]]).
**How to apply:** new rail/strip buttons should be registry commands so they can be placed in any bar; never hard-code a rail button.

2026-10-29 Bolt (iPad): the brush held must always show on the bottom shelf, first from the left. Done as a lit "active brush" tile on the shelf's off-hand side that appears only while no shown tile is lit for the brush held (`shelf_active_item`, lens_shelf.odin); the shelf and it stay centred together. The brush picker's cards scroll by finger/pen swipe; a card is carried to the shelf only by a drag that starts sideways.
