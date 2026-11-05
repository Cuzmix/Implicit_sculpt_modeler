---
name: touch-check-offscreen
description: How touch scenarios, smoke and the full gate run in the cloud container (offscreen SDL, SwiftShader), since #429 automatic
metadata:
  type: project
  modified: 2026-10-31T10:10:10.286Z
---

Since #429 (2026-10-31) `scripts/headless.py` picks the way automatically: the container's SDL has no X11 driver (setup_deps.sh now builds it offscreen-only when X11/Wayland headers are missing, #428), so with no DISPLAY every app run gets `SDL_VIDEO_DRIVER=offscreen` and `VK_ICD_FILENAMES` = Chromium's SwiftShader. Just run:

    python3 scripts/touch_check.py [names]          # side by side, one per CPU, no Xvfb
    python3 scripts/gate.py                          # smoke + touch included now
    python3 scripts/gate.py --changed                # per-PR gate

Do NOT wrap in xvfb-run and do not set DISPLAY: that would make headless pick xvfb, whose x11 driver this SDL lacks. `--dump-screen` under offscreen now gives the full window size (fixed in #631, vk_swapchain uses the window size on the offscreen driver). `touch_check.py --exe=PATH` runs a copy of the app so rebuilding during a long run is safe. 9 scenarios side by side took 39 s on 4 cores; smoke 67 s.

**Why:** the Remesh / Quad Remesh series shipped with "touch scenarios cannot run here", and four were broken for hours.
**How to apply:** run touched scenarios (or `gate.py --changed`) before every merge. Related: [[gate-per-pr]], [[pain-points-digest]].
