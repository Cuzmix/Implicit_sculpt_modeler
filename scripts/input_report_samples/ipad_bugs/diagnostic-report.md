# Input diagnostics: the reported iPad bugs (synthetic)

Sculpt 0f08584 (release) on iOS, iPadOS 26.7.2, iPad14,8.
Session 20261029-141502-3fa2, 165 s, 424 lines.

| Test | Auto | Manual |
|---|---|---|
| finger_tap | pass | - |
| finger_drag | pass | - |
| finger_cancel | pass | - |
| finger_after_pencil | fail | - |
| finger_pencil_switch | fail | - |
| pencil_tap | pass | - |
| pencil_drag | pass | - |
| pencil_hover | pass | - |
| pencil_hover_contact_lift | pass | - |
| pressure_ramp | unavailable | - |
| hover_slider | fail | - |
| hover_button | pass | - |
| hover_menu | pass | - |
| slider_ratio_finger | pass | - |
| slider_ratio_pencil | fail | - |
| text_focus_finger | pass | - |
| text_focus_pencil | pass | - |
| text_typing | pass | - |
| text_dismiss_reopen | fail | - |
| text_scribble | pass | - |
| home_swipe_baseline | inconclusive | pass |
| home_swipe_after_pencil | inconclusive | fail |
| roll_right | fail | - |
| roll_left | fail | - |
| roll_neutral | pass | - |
| roll_wrap | pass | - |

Synthetic sample for scripts/input_report.py; the field texts are made up.
