---
name: pain-points-digest
description: 2026-10-31 review of pain points, structural debt, refactor order and "if we started over" lessons; doc link and top findings
metadata:
  type: project
  modified: 2026-10-31T09:37:49.461Z
---

Thread "Digest pain points and cleanup needs" (2026-10-31, review only, no code changed). Doc: https://claude.ai/artifact/TNxWG76HJuZK9drKDMfdYu (measured at odin-sculpt a12e74f).

Top findings:
- ~15 series await a Windows/tablet try; only iPad build, Metal render on iPad and the Clay fix confirmed on devices.
- Touch scenarios (755, scripts/touch_check.py 13.4k lines) tap pixel positions, so layout changes keep breaking them; gate.py's touch step forces x11 and cannot run in the container.
- Hot files: main.odin changed in 340 commits, its `run` proc is ~1,700 lines; App 311 field lines, Kit_State 369.
- src/app = 100.6k of ~187k Odin lines (54%); exr.odin and pure retopo code belong outside app; 48 app files import SDL (mostly key codes).
- `Command_Id :: enum u8` has 246/256 values: widen to u16 before adding ~10 more commands.
- SCENE_VERSION 34 in 7 days; suggested tagged chunks + a pre-release format baseline (needs Bolt's yes: changes an AGENTS.md hard rule).

Suggested order: quick wins (u16, delete dart_trial/sdf_trial) -> touch by name (--ui-map) + offscreen touch in gate + gate --changed -> hardware week with try_it script -> split frame loop/App -> move code out of app -> settle GPU backends after device runs -> format baseline -> knowledge cleanup.

**Why:** Bolt asked for a digest of what to clean up, and what we'd do differently from scratch.
**How to apply:** check this before starting refactors so the order and evidence are reused; wait for Bolt's pick of which steps to build. Related: [[gate-per-pr]], [[touch-check-offscreen]], [[stack-rebuild-question]].

2026-10-31 09:55 Bolt: "do all the clean up and recommendation right now", tested the app on Windows, tablet and Apple ("works fine"), "we can retire SDL gpu too". So every step of the refactor order is approved, including the format baseline (dropping pre-release readers) and retiring SDL_GPU. Built in thread "Digest pain points and cleanup needs".

2026-10-31 build status (thread "Digest pain points and cleanup needs"): merged #428 (u16 ids, trials gone), #429 (headless touch + gate --changed), #431 (touch taps by name, --ui-map), #432 (hdri + retopo packages, Key enum, platform.odin, SDL only in APP_SDL_FILES), #433 (scripts/try_it.py), #434 (frame.odin frame_step/settle/events, exit_stats.odin), #435 (scene v36 chunks). Then Cleanup 4 retires SDL_GPU: hal.odin is Metal on Darwin / Vulkan elsewhere at compile time, no --gpu flag, no Graphics menu or Metal start guard, gpu_* procs require_results, failed start = system message box + exit, Android manifest Vulkan 1.3 (0x403000). Cleanup 8: stroke tests on fixed clock (busy-machine flake); autosave_crash_then_recover 6/6. Cleanup 10: README headless, parity_check headless, sm-render/sm-ui split into references/. All merged #436 (SDL_GPU retired), #437 (8+10); full gate green 2026-10-31 (758/758 scenarios, 1231 tests, all platform compiles). App struct split deliberately not done (churn vs parallel threads).
