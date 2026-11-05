---
name: pencil-pro-plan
description: 2026-10-29 Apple Pencil Pro / pen shortcuts research + 5-PR plan (thread "Support Apple Pencil Pro shortcuts"); SDL gaps, iPad tilt bug, defaults
metadata:
  type: project
  modified: 2026-10-29T08:41:18.481Z
---

Bolt asked 2026-10-29 08:34 to use Apple Pencil Pro shortcuts (barrel roll, squeeze, double-tap) "like ZBrush for iPad", then "don't forget tilt... support the full suite". Findings + plan doc: https://claude.ai/artifact/C8yCo9s7GAVHUstFFcr1Ew (now has a "What was built" section listing where the build differed).

Key facts found:
- SDL 3.4.18 UIKit (SDL_uikitpen.m) gives pressure, tilt, hover (+DISTANCE axis), roll (ROTATION axis, iOS 17.5) but NOT UIPencilInteraction (double-tap/squeeze) nor haptics -> own ObjC bridge in ios/sculpt_ios.m (SDL user events).
- SDL's iPad tilt conversion is wrong (xtilt = 90-|azimuth|, ignores altitude); invertible: |az| = 90-xtilt, sign(az)=sign(ytilt), alt = 90-|ytilt|. Fix in app, never deps/.
- SDL Android Java drops AXIS_TILT/AXIS_ORIENTATION (pressure, 2 buttons, eraser, hover only). Windows Ink gives everything incl. button 2, eraser, rotation.
- ZBrush iPad: Settings > Input > Pencil: Double Tap / Squeeze (both Off default, same ~25-action list as finger taps incl. "Key Press"), Palm Rejection Radius, Input Pressure Remap; roll over left-toolbar brush values (Allow Roll Gesture); hover tooltips; haptics on double-tap and long press.
- App already had: pressure curve, tilt push direction, roll over Size/Strength/Focal (kit_bars.odin bar_roll), side button = right click -> Brush pie gesture slot (gesture_map.odin).
- iOS min is 17.4; squeeze/roll/haptics gated at runtime on 17.5. ipad.yml is workflow_dispatch only (Mac compile check).

Plan defaults: squeeze/double-tap "Follow iPad setting" (contextual palette -> brush pie at tip; switch eraser -> Smooth toggle; switch previous -> previous brush; colour palette -> Colours card; ink attributes -> brush card), overridable with any gesture-map command; roll over any slider + per-brush "Roll turns the brush"; tilt to size/strength; hover ring fade + tooltips; Pencil only draws; haptics via UICanvasFeedbackGenerator. PRs: 1 app pen gestures/slots/tilt fix, 2 iPad bridge, 3 roll everywhere (strokes file version bump), 4 tilt+hover, 5 Android tilt (bonus).

Related: [[sculpt-tablet]], [[sculpt-customisation]], [[sculpt-touch-camera]], [[best-of-all-worlds]].

2026-10-29 08:43: Bolt chose "Build all five" on the decision card: build and self-merge all 5 PRs into odin-sculpt in order, then send an iPad checklist.

Progress 2026-10-29: PR1 #271 merged (pencil.odin: slots, second button, eraser end, iPad tilt fix). PR2 #272 merged (ios/sculpt_ios.m UIPencilInteraction bridge, Only Draw with Apple Pencil via finger_model_now, haptics). The ipad.yml macOS build caught a real error (UICanvasFeedbackGenerator has no initWithView:, use feedbackGeneratorForView:) — do not dispatch ipad.yml unless Bolt asks (see [[no-github-actions]]); iphonecheck does not compile the .m. Full gate takes ~45 min (touch ~25 min): run it in background with timeout 7200000.


Done 2026-10-29: PR3 #273 (roll over every slider, "Pen roll" alpha mode, strokes v13) and #274 (PR4+5: Lean page tilt_size/tilt_soften, hover ring fade, Android lean via SculptActivity.java + JNI in android_main.c, no deps change) merged. All five done; awaits Bolt's iPad/Android/Windows try.
Lessons: a BRUSH_SECTIONS section may show at most 5 controls (test sections_show_at_most_five_controls); adding a new brush tray section shifts the tray and breaks ~6 touch scenarios, so add pages inside an existing section instead. Without an NDK/SDK, check Android C with clang -fsyntax-only -D__ANDROID__ plus stub android/*.h, and Java with javac against stub SDL classes (both in the scratchpad).

- 2026-10-29 20:36 Bolt: "apple is a real target now"; Bolt has run the iPad build on an iPad and it works. Gaps listed: app icon, PrivacyInfo.xcprivacy, real signing/TestFlight, no Mac desktop build, Apple stays SDL_GPU (Metal) so Vulkan-only features need fallbacks or own Metal backend; decision card posted in thread "Prepare renderer for Vulkan and Slang".
