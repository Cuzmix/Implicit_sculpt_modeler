---
name: local-machine-real-gpu
description: "This Linux machine has a real GPU and CPU (Radeon 890M, Ryzen AI 9 HX 470): run the app, smoke, touch scenarios and bench here, not just check"
metadata:
  node_type: memory
  type: project
  originSessionId: 78639bbd-96eb-4ad2-a435-1ac4fdfdbac1
  modified: 2026-11-06T12:10:56.919Z
---

Since 2026-11-06 Claude Code also runs on Bolt's Linux laptop (Fedora, GNOME on Wayland): AMD Ryzen AI 9 HX 470 (24 threads, 27 GB), Radeon 890M (RDNA 3.5) on Mesa RADV 26.2 (`GPU: AMD Radeon 890M Graphics (RADV STRIX1)`). deps/ is set up, so every `./build.sh` mode works: check, test, debug, release, smoke (passes under the Vulkan validation layer, installed 2026-11-06 with `dnf install vulkan-validation-layers`; before that it ran unvalidated and logged "validation layer is not installed", so check for that line), bench, gpubench, androidcheck. The project-memory snapshot's "cloud cannot run the app" and "don't run gate.py, Bolt runs it" were about the cloud container; here the app, smoke, touch_check and gate.py can all run.

Gotchas on this machine:
- The screen is 1536x864 points (2560x1440 at 167%), smaller than the 1600x900 window touch scenarios and ui_shots ask for; on the desktop display GNOME shrinks the window and scripted taps miss. `scripts/headless.py` `exact=True` (touch_check, ui_shots) now uses SDL's offscreen driver on a Linux desktop (still the real GPU); `SCULPT_ON_DISPLAY=1` keeps them on screen.
- Frames are far faster than SwiftShader's, so touch scenarios that wait a number of frames for a thread (long jobs, Quad Remesh) can end before the thread does: a failure here that passed in the cloud may be a frame-counted wait, not a bug.
- `python scripts/touch_check.py --jobs=12`: 810 scenarios in about 2 minutes offscreen.

- try_it.py 2026-11-06 here: 12/12 after renaming its shading_mode to `full`; GPU 0.7-2.6 ms/frame up to 10M, peak 2.4 GB at 10M. The open question of ribs on the scripted stroke is real on RADV: evenly spaced cross-ridges along the stroke at 1M and 10M (dab spacing), and at 10M dark creases at the S-bend tops where it folds back. Not yet investigated.
- Under --gpu-debug with the layer: 1M CPU stroke, 1M --gpu-sculpt stroke (125 dabs, 118 dispatches), 256 voxel stroke and the Rendered look (studio_samples=256) all exit 0, no validation errors. The Rendered look's samples are `studio_samples`, not `render_samples` (that is the Render space's).

**Why:** Bolt said on 2026-11-06 that the app can now be run and tested here on a real GPU and CPU.
**How to apply:** run it and look (smoke, touch, dumps, bench) instead of reporting "unverified on a GPU"; Windows/RTX, iPad and Android runs are still Bolt's. Related: [[touch-check-offscreen]] (cloud), [[gate-on-bolts-pc]].
