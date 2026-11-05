# Contextual action bar (UX roadmap phase 3): design

Base: odin-sculpt b319681 (PR #65).
Sources:
- 08_Information_Architecture.md §4 ("the IA's now layer");
- 12_Product_Roadmap.md phase 3 ("Contextual action bar", done when its states match 08 §4);
- Nomad N004 (per-tool top toolbar) and 3DCoat C002 (contextual top bar).

**Problem:** the follow-ups after masking or hiding (invert, blur, show all) live on the Object tab's Select page or behind shortcuts. A tablet user has to open the inspector, pick Object, pick Select and scroll, for the commonest next step.

## What exists when done
**The bar:** a single floating bar, centred just above the brush dock. It shows the actions that apply to what is active now, and only while something is active. Each action is a `command_button` (label, shortcut and gesture tooltip, enabled state from the registry), so it runs exactly what the menus, the palette and the inspector run.

**Groups:** the bar shows these groups in this order, each with a small leading caption, separated by dividers. A group is shown only while its state holds.

| State | Test (cheap, see Cost) | Buttons |
|---|---|---|
| HD window open | `object_in_hd(obj)` | Leave HD (`.Hd_Leave`) |
| Something masked | `object_has_mask` (cached) | Invert, Blur, Sharpen, Grow, Shrink, Clear (`.Mask` with its argument) |
| Something hidden | `sculptor_hidden_count(s) > 0` | Show all, Invert hidden |
| Dynamic topology on | `object_dynamic(obj)` | Turn off (`.Dyntopo_Toggle`) |

**Left out of 08 §4, because the app has no such state:**
- "Shape drawn, auto-confirm off": shapes apply on release.
- "Curve in progress" and "Insert placed": both tools act within one drag.
- "Object rebuilt → Adjust…": adjust-last is phase 6. The toast already offers Undo.

Extract and Make group, which 08 lists under Mask, stay on the Select page so the mask group is at most six buttons.

**Selected object only:** all of this is about the selected object. With nothing selected there is no bar.

**When it hides:** the bar is hidden while a stroke, an orbit or any viewport drag is in progress, while the pie or the S/U adjust is open, and while the History panel is open, since that panel sits over the dock in the same place. It fades in and out with the panel motion token, and reduced motion makes it appear at once.

**Narrow windows:** buttons are text-only ("Invert", "Blur"…) at the compact control height, but each keeps a full 48 pt touch target. When the groups are wider than the safe area less two margins, the bar shows the first groups that fit and a "More" button. "More" opens the rest in a popover above the bar, so nothing is cut off.
- At 1600 pt, the HD, Mask and Hidden groups together are about 8 buttons × ~72 pt, roughly 620 pt, which fits.
- At 820 pt, Mask alone fits, and Hidden goes under More.

**Space it takes:** the bar must stay clear of the sliders, the modifier rail, the status chip and the inspector.
- It is centred over the dock, as the History panel is, and as wide as fits between the left column (sliders and rail) and the right (inspector, status), using the same `side` arithmetic as the History panel (timeline.odin).
- The modifier rail's `rail_reach` already moves the rail above the dock on narrow windows. The bar sits above whichever of those is higher, so the touch_check layout scenarios (`rail_clear`) gain "action bar" as one more rect that must not overlap.

**Setting:** Settings > Interface > "Action bar" switch, on by default, remembered (SETTINGS row `action_bar`). Some people want a clean screen.

## Cost
- `sculptor_has_mask` scans the mask bytes: 10 MB at 10M vertices, about 1 ms. It is not run every frame. `object_has_mask(app, obj)` caches its answer per object, keyed on `(object id, level, len(history.done), len(history.undone), at of the last done entry)`.
- Every mask change is a history step: mask strokes, mask commands, undo and redo. Level changes are covered by the level in the key, and a rebuild by the swap entry. So the scan runs at most once after each step, and never during a stroke.
- With `s.mask == nil`, the answer is false at no cost.
- HD: an HD window's sculptor is `object_sculptor(obj)`, so the same check applies.
- The bar's layout and tessellation are a few hundred vertices. The exit stat `ui_vertices` at 1600×900 is reported in the PR.

## Code
- New `src/app/kit_action_bar.odin`, about 200 lines:
  - `Action_Group` enum and an `ACTION_GROUPS` table of `{caption, commands: []Action}`, with `Action{id, arg, label}`;
  - `action_groups_now(app) -> bit_set[Action_Group]`, a pure proc that the tests call;
  - `kit_action_bar(app)`, the bar and the More popover;
  - `object_has_mask` with its cache in `App` (or `Kit_State`, since the interface reads it).
    - Architect question: should the cache live on `Object` instead? The interface must not own sculpt state, but a derived, rebuildable flag keyed on the history is not state.
- `kit_layout`: call it after the dock and before the windows, so the windows draw over it.
- Exit stats: `action_bar=<groups shown, comma separated or none>` and `layout_action_bar` in the layout list.
- touch_check UI entries for the bar's first buttons, computed from the layout at 1600×900.

## Tests
- **Unit (app):**
  - `action_groups_now` for a scene with no mask, with a mask, with hidden triangles, with HD open and with dynamic topology, built with the existing test helpers for objects (check `scene_test` patterns);
  - the cache key changes after a mask command and after undo, and does not change when nothing happened (count the scans);
  - every Action is a valid command and argument (`command_label` does not assert).
- **touch_check (desktop simulation):**
  - Alt+M then Ctrl+I masks everything: the bar shows Mask, and a finger tap on Invert empties the mask, after which the bar has no Mask group (`action_bar=none`);
  - a hide rectangle (Ctrl+Shift drag) shows the Hidden group, and Show all clears it;
  - during a stroke the bar is hidden (`action_bar` read mid-run is not possible, so check that the dab count is unchanged by a stroke that passes over where the bar would be: the bar takes no press while hidden);
  - at 820×640 the bar, rail, sliders, dock and status do not overlap (`rail_clear`).
- **Screenshots:** 1600×900 with a mask and hidden parts; 820×640 with More.

## Not in this step
- Adjust-last (phase 6).
- Curve and Insert states.
- A user-editable bar (phase 4 favourites).

## Size
- About 350 lines with tests, which is over 300, hence this design.
- No History, Scene_Command, GPU, file-format or package change. The settings file gains one plain row.
