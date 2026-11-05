---
name: crash-log
description: Crash log built 2026-11-01 (PR #479): where the log lives, how to read a crash, what is unverified on devices
metadata:
  type: project
  modified: 2026-11-01T09:12:15.197Z
---

Bolt asked 2026-11-01 for a log kept when the app crashes. Built and merged as PR #479 into odin-sculpt.

- Every interactive run writes `sculpt-log.txt` in the app's folder (iPad: Files > On My iPad > Sculpt; Windows %APPDATA%\Implicit\Sculpt). A crash adds `crash:` lines (what, thread, stack as module+offset). The next start keeps it as `sculpt-log-crash.txt`, shows a toast, and Settings > Files > Crash log > Save the crash log... copies it out.
- Code: src/app/crash_log.odin, crash_posix.odin, crash_windows.odin. Flags --log-file, --crash-test=panic|segv|thread; touch scenario crash_log_kept_after_a_crash.
- To read a stack: module+offset against the same build's symbols (addr2line / llvm-symbolizer / PDB).
- UNVERIFIED on devices: a real crash on Windows, Android (NDK link of _Unwind_Backtrace + dladdr via libdl), iPad.

**Why:** Bolt's crash reports need something to read on tablets without adb or a Mac.
**How to apply:** when Bolt reports a crash, ask for sculpt-log-crash.txt (Settings > Files > Crash log). Related: [[sculpt-never-lose-work]].
