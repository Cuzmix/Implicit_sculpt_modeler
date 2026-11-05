---
name: sculpt-android
description: Android build of the sculpt app (PR #48, 2026-10-25): how it is built, ids, versions, gaps, what Bolt must run
metadata:
  type: project
  modified: 2026-10-25T15:26:33.021Z
---

PR #48 merged into odin-sculpt 2026-10-25 (thread "Build the sculpt app for Android"). Not yet built or run by Bolt.

- android/ Gradle project: AGP 8.11.1, Gradle 8.14.3, NDK 28.2.13676358, CMake 3.22.1, compile/target SDK 36, minSdk 30 (Odin runtime needs ELF TLS + statx), arm64 only, no permissions. applicationId io.github.cuzmix.sculpt (my pick; permanent once on Play, change before first upload if Bolt wants another).
- SDLActivity (Java from deps/sdl3-src) loads libSDL3.so + libmain.so; CMake runs Odin -build-mode:obj -subtarget:android and links ImGui/stb/android_main.c (SDL_main + pthread cancel stubs).
- Windows steps: Android Studio + NDK/CMake, scripts\setup_android.bat (SDL source + empty stb .a stand-ins for Odin's #exists check), build.bat android | androidrun. Logs: adb logcat -s SDL/APP.
- Tablet input: pen sculpts; 1 finger orbits (Menu > Finger sculpts toggles); 2+ fingers pan/pinch; 2-finger tap undo, 3 redo. UI scales by content scale (also affects Windows at 125/150%), safe area respected.
- Gaps: content:// file open/save, save on background, release signing/.aab. Container can't build APKs (dl.google.com blocked, incl. maven.google.com redirect).

Related: [[cross-platform-flutter-plan]], [[sculpt-new-ui]].
