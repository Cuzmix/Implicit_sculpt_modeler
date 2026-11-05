# H2 History step menu and bookmarks (as built)

- Step menu (history_menu.odin, drawn after the pass menu): ui.secondary on a list row (anchored at the pointer) or a strip block (Above_Center over the block). Known by its first entry's `at` (history_step_of), never a position.
- Rows: Go here; Paint back to here (recall_to_entry, then picks the History brush via history_paint_back; dimmed with reason when undone / not a sculpt step / moving); Bookmark... or Rename bookmark... + Remove bookmark; View from this step (History_Entry.view = camera at record time, camera_go + camera ease, Previous view returns); Only <obj>'s steps (list only; select_only + only_selected); Delete everything older (history_delete_before, two taps).
- Marker button and the strip's "Delete older history" button are gone (the history tools row); Delete older history stays a command (= history_delete_before(len(done))).
- Bookmarks: History_Entry.bookmark owned, freed in entry_free, named through the rename popover (Rename_Entry.step); default "Bookmark N"; bookmarked strokes never group; list shows amber flag + name leading the subline; strip shows flags row (18 pt, only when a bookmark exists) above the bar, tap goes there.
- List row holding the History brush point shows a small accent brush.
- Strip bar moved down 53 pt (tools row gone): TIMELINE_STEPS_OF_3 y 616.
- Stats: history_bookmarks= history_menus=. Scenarios: history_step_menu_from_the_list (mouse/finger/pen), history_bookmark_flies_over_the_strip, strip ones rewritten; history_marker_and_delete_older renamed history_strip_menu_paint_back_and_delete_older.
- Left for later: H4's limits warn before dropping a bookmarked step; H3 "Show what it changed" row joins this menu.
