---
name: sculpt-frame-rate
description: Frame rate setting (Match display / Limit / Unlimited), why Bolt saw 60 fps, Android 120 Hz request, and the planned idle-sleep battery work
metadata:
  type: project
  modified: 2026-10-27T10:37:47.338Z
---

Thread "Unlock frame rate past 60 Hz" (2026-10-27). Bolt saw 60 fps; their tablet is 120 Hz (Android).
- Cause: no frame limiter existed; VSync (FIFO) follows the display. Android runs an app's surface at 60 Hz unless the app votes for more, and SDL3 never votes.
- Fix (src/app/frame_rate.odin, android/app/jni/android_main.c): Settings > System > Frame rate = Match display (default, vsync) / Limit (30-240, mailbox + SDL_DelayPrecise limiter placed before input read, so latency unchanged) / Unlimited. Settings keys `frame_rate`, `frame_limit`; old `vsync 0` lines read as Unlimited. Flags `--no-vsync`, `--frame-limit=N`. Panel shows the detected display Hz. Android: JNI Display.getSupportedModes -> top rate at current resolution, then ANativeWindow_setFrameRate(WithChangeStrategy ALWAYS); re-voted when the surface changes / on foreground.
- Not verifiable here: no NDK build in the container (only androidcheck), no real vsync display. Bolt to confirm 120 Hz on the tablet.
- Merged as PR #170. Bolt asked (2026-10-27) whether the immediate-mode UI hurts battery; answer: the cost is the loop never sleeping, not immediate mode. PR #173 merged: Settings > System > Rest when idle (src/app/idle.odin, key idle_sleep, default on): after 1 s of frames that change nothing (judged by UI draw-list hash + viewport partial redraw + held input/busy flags), SDL_WaitEventTimeout(100 ms) before each frame; scripted runs never rest unless --idle-sleep. ~30x less CPU idle on the VM. Wake latency on real input untested (Bolt to try). See [[sculpt-perf-work]], [[sculpt-touch-camera]].
