# H1 History list view (as built)

- History panel has two views, `Timeline.view` (setting `history_view`): List (new default) and Strip (the old bar over the shelf).
- List anchors at the pen side under the chip bar, 400 wide; head row: List/Strip tabs + "All objects / Selected" chip.
- Memory line: "N steps · X MB" with a meter of the undo memory against its limit ("Limits in Settings" until H4 adds the tab).
- Rows newest first (`history_rows`): a step = non-chain entry + chained entries after it. Groups: consecutive same-brush strokes, one object, same side of `done`, none adjusted; opened by the oldest stroke's `at` so undoing the newest keeps it open.
- Tap a row seeks to row.last + 1 via `timeline_seek_to`; the root row ("Opened <file>" / "New scene" · ago, "N older dropped") seeks to 0.
- Sizes recorded at record time in `History_Entry.bytes` (sculpt, voxel, swap, texture).
- Virtualized scroll with spacers. Exit stats history_view= history_rows= history_bytes= history_dropped=.
- Five bar scenarios set `history_view strip`; new scenario history_list_groups_and_goes_to_a_step.
- Next: H2 step menu + bookmarks (Paint back to here replaces Marker).
