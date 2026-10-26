---
name: sm-touch-testing
description: Testing the app the way a tablet user uses it — fingers, the pen and the mouse on the panels and the viewport, one- and multi-finger gestures, cancels, the camera's orbit, pan and zoom, scrolling panels, the Settings that change them — with scripts/touch_check.py (scripted SDL finger, pen and mouse events in the real app), the unit tests under it, an Android tablet run, and an honest report of which of automated, desktop simulation, emulator and real-device testing actually ran. Load for ANY task that changes or questions input, gestures, the camera, panels that scroll, touch or pen settings, or anything to be tried on a tablet, e.g. "a finger turns the view by itself", "scrolling the inspector moves a slider", "add a three-finger gesture", "test the touch controls", "does it work on the tablet?". Requires sm-build and sm-ui; Android packaging is sm-store and sm-build.
---

# Tablet and touch testing

The goal is that no change brings back an input bug a tablet user has already hit: the view turning when a panel is
touched, a first drag that moves a slider instead of scrolling, a stroke that does not stop, an orbit that jumps. Test
as a user would, with each kind of pointer, then say exactly how it was tested.

## Honesty: four levels, never blurred
| Level | What runs | What it proves | Report it as |
|---|---|---|---|
| Unit | `build.bat test`: `src/ui/ui_test.odin` (hit areas, the gesture arena, scrolling, cancels, `fingers.odin`), `src/camera/camera_test.odin` (full turns, poles, roll, snap, zoom toward) | the logic, in isolation | "unit tests" |
| Desktop simulation | `python scripts/touch_check.py`: the debug app on a desktop, driven by `--ui-events` pushed as SDL finger, pen and mouse events | the whole routing end to end: who owns a touch, slop, the arena, gestures, cancels, the camera, saved settings | "desktop touch simulation (scripted SDL events), not a tablet" |
| Emulator | an Android emulator running the APK (mouse as one finger; multi-touch only through the emulator's own tools) | the APK starts, lays out inside the safe area, takes single touches | "Android emulator, <image>" |
| Real device | the APK on a tablet, or the app on a touch-screen PC with a pen, by a person or `adb shell input` | timing, real palms, pen pressure and tilt, the OS's own cancels, how it feels | "real device: <model, OS>, by <who>, <finger/pen>"; `adb shell input` is "real device, injected single-pointer input" |

- Never write that tablet testing passed unless a device ran it and someone saw the result. A cloud or CI session has no
  tablet: run the strongest levels it has, then list what still needs a device (the checklist below).
- A scenario that passes in simulation proves the code path, not the hardware: SDL's touch and pen drivers, the
  screen's sampling rate and the OS's palm rejection are not in it.

## 1. Know the targets and devices
- Windows (mouse; touch screens and pens through Windows pointer messages), Linux (X11 and Wayland: mouse, touch, pen),
  Android tablets (fingers, active stylus; Bolt's is a OnePlus tablet). iPad comes later.
- In the app every pointer is a `ui.Pointer_Kind`: Mouse, Finger or Pen (`device.odin`). Touchpads report fingers too
  but are not screens and must never move the view (`touch_event` keeps `DIRECT` devices only).

## 2. Read the routing before testing it
| File | What to check |
|---|---|
| `src/app/android.odin` `platform_hints` | `HINT_TOUCH_MOUSE_EVENTS` is "0": SDL's own touch mouse warps the pointer and was the jump-orbit bug |
| `src/app/touch.odin` | `touch_event` (first finger drives the pointer with `jump = true`), `touch_route` (one owner per touch, gestures, taps, palm, cancel) |
| `src/app/navigate.odin` | `pointer_route` / `drag_decide` (one owner per drag: Tool, Orbit, Pan, Zoom, Muted), the slop, `FINGER_HOLD`, `camera_apply_input`, `Nav_Prefs` |
| `src/ui/ui.odin` | `interact` (tentative presses in `drag_scroll` areas), `claim_drag`, `scroll_update`, `scroll_take`, `hit_extend`; `src/ui/fingers.odin` |
| `src/camera/camera.odin` | `orbit_rotate` (Free, Turntable), `orbit_turn_about` (the pivot stays put), `orbit_roll`, `orbit_snap`, `orbit_zoom_toward` |
| `src/app/kit_settings.odin`, `settings.odin` | every touch and camera preference, its default, reset and saved key |

Red flags while reading: a camera or tool path reachable from a press the interface took; a delta taken from SDL's
motion sums instead of last frame's position; gesture state that is not reset when a touch starts; anything that waits
on window focus or hover to decide ownership; a widget that acts on a finger press before `claim_drag`.

## 3. Build and run
    build.bat                                   # or ./build.sh: the debug app the scenarios drive
    python scripts\touch_check.py --list        # the scenarios and what each proves
    python scripts\touch_check.py               # all of them; names or patterns ('rail_*') to run some; --screens writes build\touch\<name>.png of the last run, --screen-run=N of run N (no copied script needed to picture a middle state)
    python scripts\gate.py --only touch -- 'rail_*'   # the same through the gate, with the log in build\gate\touch.log
- It needs a display. On Linux with `Xvfb` installed it starts one per job itself (`start_displays`) and runs the
  scenarios side by side (`--jobs=N`, default one per CPU); otherwise one at a time on the current display (on a
  headless box with one job, run it under `xvfb-run -a -s "-screen 0 1600x1400x24"`, as `gate.py` does).
- Every scenario is a fresh run with `--no-settings` (or `--settings-file`), so remembered settings never leak in.
- After it, `build.bat test`, `build.bat smoke`, and on Linux `./build.sh wincheck` and `./build.sh androidcheck`.
- Real tablet: `build.bat androidrun` (sm-build), then the device checklist in section 6.

## 4. Required scenarios (and where they live)
| What a user does | Scenarios in `touch_check.py` |
|---|---|
| taps every major region: the camera does not move, nothing is sculpted | `tap_ui`, `rapid_taps` |
| touches down far from where the last finger lifted | `tap_viewport_far_apart` |
| drags vertically through a panel from the very first touch, on a control | `first_touch_scrolls_inspector`, `inspector_tab_switch_then_scroll`, `settings_scroll_and_persist` |
| scrolls a panel straight after opening it; opens, scrolls, closes, repeats | `settings_scroll_right_after_opening`, `settings_open_scroll_close_repeat` |
| drags a slider: the value changes, no orbit, no scroll | `slider_drag_sideways` |
| sculpts on the model with a finger, the pen, the mouse | `finger_sculpts_model`, `palm_while_pen_near`, `pen_stroke_with_hand_resting`, `mouse_controls`, `mouse_click_within_one_frame` |
| navigates on empty space as the settings say | `finger_orbits_empty_space`, `pen_on_empty_space_orbits`, `finger_orbits_setting`, `changed_touch_setting_takes_effect` |
| orbits through several full turns both ways and over the top | `orbit_full_turns_free`, `orbit_full_turns_turntable` |
| orbits after sculpting off the middle: the stroke stays put on screen; or about the centre when set so | `orbit_turns_about_the_last_stroke`, `orbit_about_the_centre_setting` |
| zoomed in until the model fills the screen, turns the view from the edges (the safe zone), or sculpts there with it off | `edge_orbits_over_the_model`, `edge_off_sculpts` |
| hovers the brush over the model: the ring lies on the surface; off the model it is flat | `ring_lies_on_the_surface`, `ring_off_the_model_is_flat` |
| folds, opens, closes, reopens and drags the panel windows, and finds them where they were after a restart | `window_minimise_folds_to_the_title_bar`, `window_tap_on_folded_title_opens_it`, `window_close_and_reopen`, `window_drag_by_title_is_remembered`, `window_position_comes_back` |
| pinches, pans and twists with two fingers | `pinch_zoom`, `two_finger_pan`, `twist_rolls_free_only`, `twist_wobble_rolls_nothing`, `twist_rolls_nothing_in_turntable` |
| lands several fingers at once or one after another | `second_finger_on_model_sculpts_nothing`, `second_finger_soon_after_sculpts_nothing`, `three_finger_size` |
| taps two or three fingers to undo and redo, on the viewport and on a panel | `tap_history`, `two_finger_tap_on_panel_does_nothing` |
| has the touch cancelled by the system, or by the pen landing | `cancelled_stroke_is_taken_back`, `pen_landing_cancels_finger_stroke` |
| uses the desktop mouse and keys | `mouse_controls`, `shift_snaps_orbit` |
| changes and resets settings, and restarts | `settings_scroll_and_persist`, `settings_reset_everything`, `settings_reset_needs_second_tap` |
| uses another window size | `small_window` (1280 x 800), `rail_fits_a_large_interface`, `rail_fits_portrait`, `rail_on_the_right_clears_the_panels` |
| long-presses a control: its secondary action or its tooltip, never a tap; a press short of it still taps | `long_press_shows_the_tooltip_and_does_not_tap`, `long_press_a_scene_row_opens_its_menu`, `slow_tap_on_a_folded_title_still_opens_it`, `a_press_short_of_long_still_taps`, `long_press_undo_opens_history`, `right_click_undo_opens_history`, `long_press_dock_brush_opens_its_settings`, `long_press_size_slider_resets_it`, `size_slider_drag_still_slides`, `status_chip_tap_and_long_press` |
| holds or taps a modifier button with one hand while the other sculpts | `rail_hold_smooth_with_pen`, `rail_tap_latches_invert`, `rail_mask_paints_mask`, `rail_mask_shape_from_empty_space`, `rail_hide_gesture`, `rail_lift_mid_stroke_keeps_mode`, `rail_mouse_click_latches` |
| holds a modifier button while the pen lands, hovers, or two fingers pinch; a window covers it; a latched one at the edge | `rail_finger_survives_pen_down`, `rail_finger_while_pen_near`, `rail_finger_during_pinch`, `rail_under_window_goes_to_window`, `rail_latched_edge_still_orbits` |
| taps the model quickly with a modifier latched: the dab keeps it | `finger_tap_with_invert_latched_dabs_inverted` |
| double-taps: empty space frames; the model pins the pivot (sculpting or orbiting) and neither tap sculpts; too slow, too far, in the edge band or switched off does nothing | `double_tap_empty_frames_the_object`, `double_tap_model_pins_the_pivot`, `double_tap_model_while_sculpting_pins_without_dabs`, `pinned_pivot_ends_with_the_next_stroke`, `double_tap_too_slow_is_two_taps`, `double_tap_too_far_is_two_taps`, `double_tap_in_the_edge_band_does_nothing`, `double_tap_off_frames_nothing` |
| taps with Mask on: off the model inverts, on the mask blurs, off the mask sharpens, never a dot; the pen too; Ctrl+click off the model inverts, on it still sculpts inverted | `mask_tap_off_the_model_inverts`, `mask_tap_on_the_mask_blurs`, `mask_tap_off_the_mask_sharpens`, `mask_pen_tap_inverts_too`, `ctrl_click_off_the_model_inverts_the_mask`, `ctrl_click_on_the_model_still_sculpts_inverted` |
| taps the model once: the dab lands after the double tap's gap, or at once before an Undo tap, a stroke or a pinch; with double taps off, at once | `single_tap_dab_lands_after_the_gap`, `tap_dab_waits_for_nothing_else`, `tap_then_stroke_keeps_both`, `tap_then_two_fingers_keeps_the_dab`, `double_tap_off_taps_dab_at_once` |
| puts two fingers down and lifts one to turn the view; not after a pinch, not when off | `lift_one_finger_turns_the_view`, `pinch_then_lift_turns_nothing`, `lift_one_off_turns_nothing` |
| holds two or three fingers still to repeat undo or redo; never with the pen near, a late (palm) finger, a slow pinch, or when off | `hold_two_fingers_repeats_undo`, `hold_three_fingers_repeats_redo`, `hold_with_the_pen_near_does_nothing`, `hold_with_a_late_finger_does_nothing`, `slow_pinch_never_undoes`, `hold_off_undoes_nothing` |

Repeat the critical ones (taps, first-touch scroll, full turns, pinch) after any change to camera or touch settings,
with the setting changed (`--orbit-style=turntable`, `--finger-orbits`, `--orbit-pivot=centre`, `--no-edge-orbit`, or through the Settings panel as
`changed_touch_setting_takes_effect` does). Live window resizing, rotation and split screen cannot be scripted: they
are on the device checklist.

## 5. Writing a new scenario
- A scenario is a function under `@scenario` returning `(Script, extra_args, checks)`. `Script` builds `--ui-events`
  frame by frame: `ftap(x, y)`, `fdrag(path)`, `fingers(starts, moves, frames)`, `mouse_drag(path, button="left|middle|right", keys=...)`,
  `press(key, mods)`, `type("text")` (each letter as its key and as `text:` input, which lands only while a text field
  has the keys, so from about the second frame after the palette opens), or
  `add("pdown:x,y")` and the rest of the raw events (README "App flags"). `line(a, b, n)` makes a path; `past_slop`
  makes one whose first move only crosses the slop, so the rest counts in full.
- Checks are functions of the exit stats (`camera_yaw`, `camera_pitch`, `camera_roll`, `camera_distance`,
  `camera_target`, `dabs`, `undo_steps`, `redo_steps`, `brush_radius_px`, `brush_strength`, `inspector_scroll`,
  `settings_scroll`, `settings_open`, `orbit_pivot`, `pivot_source`, `cursor_hit`, `cursor_normal`, `window_<name>`,
  `stroke_kind`, `stroke_invert`, `rail_latched`, `masked`, `hidden_triangles`, `long_tip` (the last long-press
  tooltip, spaces as underscores, or none), `long_tip_keys` (its shortcut and gesture, the same way), `object_menu`, `pinned`, `framed` (double taps on empty space), `mask_mean` (the selected object's mask, 0 to 1),
  `last_op` (the last operation's result up to " in " or a comma, underscores for spaces), `toast_undo` (it offered Undo),
  `adjust_op` (what the action bar can adjust now, `none`, `remesh`, `smooth_all`, ...), `adjusts` (re-runs), `adjust_pop`,
  `camera_views` (views kept for Previous/Next view), `camera_view` (the one shown, from 1), `camera_steps`,
  `shape_pending` (a drawn shape waiting for Apply: `mask`, `hide`, `clip`, `slice` or `none`), `shape_points`, `shape_flip`, `shape_box` (x0,y0,x1,y1),
  `rebuild_goal` (`even`, `fewer`, `quads`), `rebuild_preview` (the density checkerboard drawn last frame), `rebuild_cell`, `rebuild_area_ms`/`rebuild_step_ms` (its measuring, in all and in the longest frame; `open_rebuild(s, goal)` folds the sections above and opens Rebuild),
  `gizmo_at` (where the gizmo's centre was drawn), `gizmo_mode`, `gizmo_hover`, `gizmo_last` (the handle of the last drag that changed something), `gizmo_drags`, `gizmo_snap`, `transform` (x,y,z,turns,scale of the selected object; `transform_is(test)` reads it), `transform_undo` (the `GIZMO_*` points and `gizmo_where` assume the starting sphere and camera),
  `touch_repeats` (undo and redo steps taken by holding fingers), `inspector_tab`, `brush_kind`, `tool`, `palette` (open),
  `palette_runs`, `palette_last` (the last row it ran, by its saved name: `Wireframe`, `Brush:Clay`), `settings_tab`, `layout_<name>` (x,y,w,h of the
  modifier rail, sliders, dock, status and inspector), ...); `camera_still()` checks nothing moved; keys starting with `@` are checks given every stat at once or checks on
  files, such as `saved(key="value")` and `saved_line(line)` on the settings file, or `on_screen` comparing where a
  point shows before and after an orbit. A value the scenario needs that the app does not print
  is a new key in the exit stats (`main.odin`), not a guess from a screenshot.
- Find positions by looking: `--dump-screen=build/x.png` (or `--screens`) with the events that open the panel, then
  read the PNG. Positions are window points at 1600 x 900 unless the scenario sets `--width`/`--height`.
- `palette_run(s, "words")` runs the palette's first match (Ctrl+K, type, Enter): the steady way to start a command
  whose button moves with the layout. `same_file(a, b)` compares two exports; an operation checked against a straight
  run of the same thing (`--remesh=N`, `--smooth-all=N`, `--retopo=N`) shows it bit for bit.
- A value from one run that a later run must match: a check `"@remember": f` on the first step stores the stats in a
  dict the later step's `@` check reads (`camera_back_and_forward_from_the_view_menu`).
- A finger's or the pen's mask, hide or clip shape waits for Apply by default (two-phase shapes): a scenario that
  means the shape to apply presses `Return` after it (or taps the bar's Apply); a mouse's applies at once.
- A popover whose height follows its text keeps its controls at its foot, by the anchor, so their positions hold
  whatever the lines above say (the adjust popover: `ADJUST_SIZES`, `ADJUST_AXES`).
- The menu's rows are computed from `MENU_FILE_ROWS` (touch_check.py, kit_menu's order): a new File row goes in that
  list, never as hand-shifted coordinates. A scenario with several app runs (a save, then an open) returns
  `Steps([...])`; files a scenario makes go under `autosave_folder()`, its own per-scenario path.
- Write the scenario for a bug before fixing it, and confirm it fails on the old code (build the old commit in a git
  worktree if the old code cannot run the new events, and replay the closest event sequence it understands).
- A second hand's finger (a modifier button held while another finger or the pen works) gets an id of its own
  (`RAIL_FINGER`, 9), never 0. The scripted pen has no pressure (no `PEN_AXIS` event), so a pen stroke whose effect
  scales with pressure (the mask) changes nothing: use a finger stroke to check the effect.
- The interface's clock is fixed: `touch_check` passes `--ui-dt=1/60`, so tweens, tooltip delays and long presses
  count frames (`LONG_PRESS_FRAMES`, 30, is a long press; `long_press(s, x, y)` makes one). Never hold a finger still
  on a control for 27 frames or more unless the scenario means a long press. Every timed gesture in the app reads
  `input_clock(app)` (touch.odin), which is that fixed clock under `--ui-dt`: `FINGER_HOLD` (90 ms, 6 frames), the
  fingers' 0.25 s tap window (15 frames), the rail's taps and the pie's tap. A new timed gesture uses it too, never
  `time.tick_now`, or its scenario passes alone and fails when the machine is busy.
- Timing: events are per frame, not per millisecond; keep "together" fingers within a frame or two.
- A single finger tap on the model lays its dab only after the double tap's gap (`DOUBLE_TAP_GAP`, 18 frames): wait
  24 frames before the run ends, or the dab never lands. Two finger taps on the model within the gap are a double
  tap, not two dabs (`double_tap 0` in the scenario's settings file turns that off).

## 6. Real-device checklist (for Bolt, or a session on the device)
Record the device, OS version, build (commit, debug or release) and whether a finger or the pen was used. For each:
what was done, what should happen, what happened; a screen recording when something is wrong; `adb logcat -s SDL/APP`.
1. Tap every toolbar button, the dock, the inspector tabs and Settings rows: the view never turns, nothing is sculpted.
2. First touch on an inspector slider, drag up: the inspector scrolls, the slider keeps its value; drag sideways: it sets.
3. One finger on the model sculpts at once with no dot left by a second finger landing; on empty space it orbits.
4. Pen on the model sculpts with pressure; a palm resting while the pen hovers does nothing; the pen landing mid-touch cancels it.
5. Two fingers: pan, pinch toward the fingers, twist to roll (Free); quick two-finger tap undoes, three redoes.
6. Three fingers up and down size the brush, sideways set its strength.
7. Orbit round and round both ways and over the top: smooth, no jump, no flip; Shift snap with a keyboard if attached.
8. Pull down the notification shade or switch apps mid-stroke: the stroke is taken back, nothing stays pressed.
9. Rotate the tablet, use split screen, resize a desktop window: panels stay inside the safe area and keep working.
10. Change Touch and Camera settings, close the app from the task switcher, reopen: they are kept; reset puts them back.
11. Mouse and keyboard on Windows and Linux: left drag sculpts, empty space and right drag orbit, wheel zooms.
12. Modifier buttons: hold Smooth with a thumb while the pen strokes (smooths, lifting latches nothing); tap Invert
    (latches, filled); hold Mask and stroke with a finger. Check the OEM pen does not cancel the held finger (some
    stylus drivers cancel every touch when the pen lands), and that the bottom-left buttons are not inside the
    system's home-gesture band (a swipe up from them must not leave the app, and a tap must reach the button).
13. Long press: hold a finger still on Undo or a dock brush: the ring fills and the tooltip shows,
    and lifting does not press it; a quick tap still presses. Long-press an object in the Scene tab: its menu opens.
    Note whether 0.45 s feels right and whether the ring shows round the fingertip.

## 7. Recording a failure
    Title: <what went wrong, in the user's words>
    Level: unit | desktop simulation | emulator | real device (<model, OS, finger or pen>)
    Build: <commit>, debug|release, <platform>
    Steps: <exact positions, settings, event list or scenario name>
    Expected: <what should happen>            Actual: <what happened>
    Evidence: <exit stats line, logcat lines, screenshot or recording path>
A failure seen on a device that the simulation passes means the simulation is missing something: add the missing
event sequence to a scenario before fixing the code.

## Traps
| You might expect | What happens |
|---|---|
| a scripted `down` is a finger | it is the mouse; fingers are `fdown`/`fmove`/`fup`/`fcancel`, the pen `pnear`/`pdown`/`pmove`/`pup`/`pfar` (with the stand-in finger SDL sends for a pen, which must change nothing) |
| SDL's pen and mouse send only their own events | by default SDL also sends them as fingers (`PEN_TOUCHID`, and `MOUSE_TOUCHID` on Android), which joined a real finger as a second one; `platform_hints` turns them off and `touch_event` drops them |
| an orbit of N points turns N x speed | the move that crosses the 10 point slop is not counted for fingers and the pen: use `past_slop` |
| a drag across the window starts where it is drawn | it starts on whatever is under its first point: a full turn must begin on empty space, not the model or a panel |
| a passing run means the tablet works | it means the routing does; section 6 is still owed until someone runs it on hardware |
| the settings file of one scenario carries to the next | each run starts with `--no-settings` unless it passes `--settings-file={settings_file()}`, a file of the scenario's own (`build/touch/settings/<name>.txt`, removed before it runs), so scenarios side by side never share one |
| `--frames` runs at the display's rate | it runs as fast as the build and the display allow; nothing a check reads depends on real time (`input_clock`) |
| two scenario windows can share a display | the one opening takes the focus, and `WINDOW_FOCUS_LOST` forgets the other's fingers (touch.odin): side by side runs get a private Xvfb each |
