# Rail groups: design note (PR6)

Built on PR5 (the Panels picker, `Show_Panel`, any card or section on the rail).

## What exists when PR6 is done

- Dropping a carried rail panel button on the middle of another rail panel button makes a
  panel group: one rail button whose icon is the shown panel's with a small count badge and,
  when the group has a colour, a coloured edge. Dropping more panels on it adds them (6 at most).
- A tap on a group opens it beside the rail. **Tabs** shows a tab row and the shown panel;
  **Stacked** shows every panel one under another, each with a foldable header.
- A long press or right-click on a group button, or on one of its tabs, opens the group menu:
  name, colour (none + 6 swatches), Show as Tabs / Stacked, Pin open, each panel with Take out,
  Ungroup, Remove from rail.
- **Pin open** docks the group into the panel column: its panels are kept in the stack as one
  joined group (Tabs) or as consecutive cards (Stacked). Unpinning takes them back out.
- Groups are saved with the bars (`view_rail` slot `Rail_Group:N` plus `rail_group N ...` lines
  in settings and workspace layouts). Old files read unchanged.

## Data

```odin
RAIL_GROUPS :: 12
RAIL_GROUP_PANELS :: 6
Rail_Group :: struct {
	used:    bool,
	panels:  [RAIL_GROUP_PANELS]Panel_Kind,
	count:   u8,
	shown:   u8,                 // the tab shown
	stacked: bool,               // Stacked rather than Tabs
	pinned:  bool,               // docked in the panel column
	folded:  bit_set[0 ..< 8],   // Stacked: the panels folded to their header
	colour:  u8,                 // 0 none, else GROUP_COLOURS[colour - 1]
	name:    [24]u8, name_len: u8,
}
```
In `Kit_State` (`rail_groups: [RAIL_GROUPS]Rail_Group`). A rail slot `{.Rail_Group, g}` points at
group g; a group no slot points at is freed when the rail is saved or reset. The interface
keeps no references between frames: the popover holds the group index only.

## Commands and popovers

- `Rail_Group` command (arg group index): on a bar opens `Bar_Pop_Kind.Group`; from Search or a
  key it opens beside the rail's top, as Camera's menu does.
- `Bar_Pop_Kind.Group` and `.Group_Menu` (both with `group` in `Bar_Pop`), drawn in
  `rail_groups.odin`. Bodies come from `panel_body`, so a group shows exactly what the stack does.

## Drag

`bar_target` gains `join`: on the View rail, not the end spot, the pointer in the middle third
of a button along the rail, and both the carried slot and the target slot are panel slots
(`Show_Panel`, `Show_Section` of a palette) or groups. The target is ringed in the accent colour
instead of the between-buttons line. `bar_drop` with `join` calls `rail_join`: the target becomes
(or stays) a group holding its panels then the carried ones; the carried slot comes off its bar.
Over the cap, or a panel already in the group, the drop is refused with a note, as a full bar is.

## Pin and the stack

Pin runs `stack_keep` for each panel; Tabs then joins them with `stack_join_at` behind the first,
Stacked leaves them as consecutive cards after the first (`stack_order_place`). Unpin runs
`stack_keep(.., false)`. Pinning or unpinning from the stack's own header is not added here.

## Pushback: retiring the stack's own controls is a separate PR

We agreed the rail becomes the stack folded to icons and the stack's order, Panels button and
beside columns retire, with old layouts migrating. That change touches the stack engine, every
workspace layout and about 40 touch scenarios that drive the stack directly. I'd ship rail groups
first (above, additive, nothing retired), then do the retirement as its own PR (PR6b) with the
migration and its tests, so a regression in one does not hold up the other.

## Tests

- `rail_groups_test.odin`: join, extend, cap, refuse a duplicate, take out, ungroup, remove,
  save and read back (settings and workspace layout), a damaged `rail_group` line ignored, pin
  keeps the panels in the stack joined (Tabs) or consecutive (Stacked) and unpin hides them.
- Touch: drag Material onto Layers on the rail makes a group whose tap shows two tabs; a long
  press on the group opens its menu and Stacked shows both bodies.
