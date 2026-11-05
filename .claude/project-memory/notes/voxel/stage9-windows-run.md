# Voxel roadmap stage 9: the Windows and tablet run (Bolt's)

Stages 3 to 8 are merged into `odin-sculpt` (#157, #159, #162, #165, #168, #171, #176, #181). Every
number so far is from the Linux VM with a software GPU and 4 threads; stage 9 is the same measurements on the RTX
3060 Ti and the tablet. Build first: `scripts\setup_deps.bat` (Luau is needed since #161), then `build.bat release`.

## 1. The CPU bench (one command, paste the three rows)
    build\bench.exe --voxel 256 512 1024 > build\voxel_bench.md
The README's "Voxel sculpting" table has the VM rows to put yours beside. The columns that matter and the VM values:

| Across | Dab ms | Flush ms | Stroke end ms | To mesh ms | From mesh ms | Res+ ms | Res− ms | Union ms |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 256 | 0.26 | 11.1 | 39 | 23 | 236 | 73 | 74 | 335 |
| 512 | 0.65 | 31.4 | 127 | 78 | 922 | 273 | 323 | 1235 |
| 1024 | 1.82 | 168.8 | 788 | 401 | 4755 | 1420 | 1676 | 6174 |

Targets from the design: stroke end under 200 ms and To mesh under 1 s at 1024 (To mesh is met on the VM, stroke end
is not: the band repair's 8 sweeps over 24k bricks are the floor there; a desktop with 8+ threads should land near).
Add `--threads=N` to see how it scales.

## 2. The app on the GPU (the exit stats print on close)
    build\sculpt.exe --voxels=512 --frames=600 --orbit --no-simplify --time-gpu
    build\sculpt.exe --voxels=512 --frames=600 --orbit --no-simplify --time-gpu --no-cull
Read `cull=... culled_back=...` and the GPU ms lines: the second run draws every node, the first skips the ones facing
away (about 55 % on a sphere), so the viewport GPU time should drop by about that share. Then a real stroke:
    build\sculpt.exe --voxels=1024 --bench-stroke=120
gives dab, flush and upload ms a frame and the stroke end; compare with a 5M mesh sphere's `--bench-stroke`.

## 3. By hand, with the pen (what to feel for)
- Add object with As voxels at the largest size preset, Draw and Clay strokes: the brush should follow the pen with no
  lag beyond a mesh's; the stroke's end (band repair + remesh) is the one pause, say how long it feels at 512 and 1024.
- Res+ and Res− in the Voxels section at 512: a pause of about a second on the VM at 1024.
- Convert to voxels on a 1M mesh and Convert to mesh back; Make boolean with a voxel base (Blend slider) and the live
  preview while moving the cutter (it previews on a copy at most 256 across, then applies at full size on Make).
- Mask on clay: Ctrl-paint, the rectangle, Ctrl+I, Alt+M; a Draw stroke across a masked patch must leave it still.
- Save and reopen a sculpted 512 clay (scene file about half the raw size now); the Objects card picture of the clay.
- On the tablet: the same at 256 and 512 (1024 is 146 MB of field plus the surface, likely too much for the APK's
  memory), and whether the stroke end at 512 is tolerable with fingers.

## 4. What to send back
The three bench rows, the two orbit runs' GPU ms and cull lines, the `--bench-stroke` lines, and one sentence each
for the hand tests above. Anything that crashes: the exit stats and the autosave folder's last file.
