---
name: apple-target
description: 2026-10-29/30 thread "Rebuild the stack" Apple work: iPad store basics #356, Mac build #357, app icon pick (F graphite ring), Metal stage 1 built (--gpu=metal, unverified on Apple)
metadata:
  type: project
  modified: 2026-10-30T07:24:49.084Z
---

Bolt 2026-10-29: Apple (iPad + Mac) is a real target; Bolt's iPad build (GitHub ipad.yml IPA) runs fine on a real iPad. Bolt chose "Also plan a Metal backend": store basics + Mac build + a Metal backend design first, no Metal code until reviewed.

- App icon: Bolt picked "F, the graphite ring" 2026-10-30 (clay bump with a teal brush ring on #14161a). Source assets/icon/sculpt.svg, render assets/icon/sculpt-1024.png (opaque RGB, rendered with playwright + PIL). Options page: https://claude.ai/artifact/M61uBXdjSKB6Vz9K3Z6Nas. Bolt disliked the first (brown/clay) colours.
- #356 merged: privacy manifest, autosave excluded from backups, actool icon, App Store signing, `build.sh iosupload`, ipad.yml `testflight` option (6 repo secrets, README "iPad").
- Bolt 2026-10-30: is sideloading the app now; Apple CI runs and store secrets come later, when the app is complete.
- #357: Mac build (`build.sh maccheck|mac|macnotarize`, mac.yml, mac/Info.plist, MAC_MIN 14.4, Cmd counts as Ctrl on Darwin). Nothing Apple-side has been run: all unverified until Bolt or CI runs it (never start the workflows unless Bolt asks: [[no-github-actions]]).
- Metal backend design doc: https://claude.ai/artifact/3FYi4euehYFJzKfS3NrAy8 (5 stages; Bolt approved stage 1 ONLY on 2026-10-30 07:34 ("don't do 2"): 1 = mirror draws a frame behind --gpu=metal in 2 PRs; stage 2 (compute/copies/mipmaps/readback/timing + Graphics menu lists Metal) waits for Bolt; stages 3-5 wait for the iPad verdict). SDL_GPU Metal compiles MSL with fast maths, so GPU Smooth all is off on Darwin.
- Metal stage 1 (2026-10-30): src/render/mtl_*.odin + backend.odin, behind `--gpu=metal` only (not in the menu), compiled for Mac and iPad, never run on Apple hardware. It includes copies, mipmaps and readback (a frame and dumps need them) but no compute: compute features stay off under it. Pinned Odin bug: any objc msgSend asserts "missing procedure objc_lookUpClass" unless the package implements an objc class; `Mtl_Objc_Anchor` is the workaround, keep it.
- 2026-10-30 Bolt said yes to a menu entry: #375 adds Settings > Graphics "Metal (trial)" on Darwin, guarded by a `settings-metal-trial` marker (a crashed start falls back to Automatic). Bolt will sideload and try it on the iPad; stages 2-5 still wait for Bolt.
- #357's merge pulled in Quad Remesh (src/quadmesh, AVAILABLE on the Mac): `build.sh mac` now builds/links deps/autoremesher with -lc++. Fresh container also needs `scripts/build_autoremesher.py` before gate tests.
- agents_sync gotcha: a skill may not name `assets/...` paths (nested two deep / resolved against the skill dir); name the file only.
- Fresh container: `scripts/build_ufbx.py` is needed before `gate.py` tests (FBX since #329).

Related: [[pencil-pro-plan]], [[stack-rebuild-question]], [[gate-per-pr]].

2026-10-31: SDL_GPU is retired (Bolt approved; thread "Digest pain points and cleanup needs"). Render draws only with its own Metal (Darwin) and Vulkan (elsewhere) backends; no --gpu flag, no Graphics menu, no Metal start guard. Where this file mentions an SDL_GPU fallback or choice, that is history. See [[pain-points-digest]].
