---
name: one-ui-per-card
description: Bolt 2026-11-06: one implementation per thing, as many places to reach it as help (replaces the 2026-11-02 "one UI per thing, one place" rule)
metadata:
  type: feedback
  modified: 2026-11-06T12:00:00.000Z
---

Bolt 2026-11-06: "one implementation per thing, as many places to reach it as help." Replaces the 2026-11-02 rule ("not have two different ui for the same thing"), which had come to mean a feature may appear in only one place.

- Kept: each feature has one source of truth and one piece of UI code. Any shortcut to it (a top-bar chip, a shelf slider, a pie item, a row in another card) is that same control, drawn by the same proc, so it can never show different values or behave differently. Never a second, different panel for the same feature (the 2026-11-02 audit's four twins, Layers, Material, Lights and Scene, stay folded into their cards).
- Dropped: "a feature may appear in only one place". Putting the same control where the hand already is, is good design, especially on a tablet.

**Why:** Bolt felt the one-place reading held the app back; on a tablet the controls need to be where the hand is, and a shortcut that is the same control cannot drift the way twin panels did.
**How to apply:** for any new shortcut ask two things: is it the same control (the same proc, the same state, no copy), and does it save a real reach or tap? Both yes: add it. A second panel with its own drawing code for an existing feature: fold it into the one implementation instead. See [[rail-groups-lights-plan]], [[lens-panel-model]], [[best-of-all-worlds]].
