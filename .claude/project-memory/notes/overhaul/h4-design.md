# H4 History settings (as built)

- Gear at the History panel head row end (and "Limits in Settings" link over the list) opens Timeline.settings page, placed where the list stands; a List/Strip tab goes back.
- Page = Settings blocks Undo_History (now: History may use + Undo steps kept + memory rows), History_Steps (Light changes, Scene tree changes), History_Back (Camera follows the History, Group repeated strokes). Same blocks in Settings > Files (LENS_FILES) and the narrow System tab.
- App fields (off = default): history_limit_mb, history_no_lights, history_no_tree, history_camera, history_ungrouped; settings lines of the same names.
- history_cap: steps cap and memory cap both via history_drop_unmarked (stops at first bookmarked step, one note per bookmark via History.held_at); history_limits_apply gives every sculptor + swap_limit the MB limit when set, back to defaults once when set back to Automatic (History.limit_mb tracks).
- No lights: history_record_lights skips, bumps edits. No tree: only pure tree edits in the Arrange scene command skip (Delete folder with objects still records).
- Camera follows: undo_run/redo_run and timeline_seek_done (seek_from tracked in timeline_frame) call history_camera_follow -> history_view_go (camera_go + ease); not during playback or time-lapse.
- Stats history_page= history_limit_mb=. Scenario history_settings_page_from_the_list. HISTORY_GEAR (1500,146), HISTORY_LIST_TAB (1185,146).
- Gestures section left for H5 (scrub).
