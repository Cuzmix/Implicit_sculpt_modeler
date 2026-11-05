threads: 1, node triangles: 1024
| Voxels across | Bricks | Field MB | Fill ms | First mesh ms | Vertices | Triangles | Raycast ms | Add dab ms | Bricks/dab | Flush ms | Flush ms max | Upload KB/frame | Regrows | Mesh MB | Stroke end ms | Undo MB | Undo ms | Redo ms | Smooth dab ms | Inflate dab ms | To mesh ms |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 256 | 7k | 9.4 | 48 | 142 | 347k | 617k | 0.005 | 0.49 | 52 | 2.44 | 3.64 | 540 | 0 | 23 | 136 | 1.2 | 27.0 | 38.1 | 0.40 | 0.58 | 280 |
| 512 | 29k | 36.0 | 179 | 555 | 1.39M | 2.47M | 0.009 | 1.78 | 172 | 7.91 | 10.05 | 1646 | 0 | 91 | 441 | 6.6 | 69.9 | 76.2 | 1.25 | 0.57 | 1041 |
| 1024 | 119k | 145.5 | 763 | 2552 | 5.57M | 9.88M | 0.012 | 10.63 | 720 | 39.22 | 70.20 | 26773 | 1 | 414 | 3020 | 61.5 | 300.8 | 473.1 | 3.84 | 2.27 | 5772 |
peak RSS: 1277 MB
threads: 4, node triangles: 1024
| Voxels across | Bricks | Field MB | Fill ms | First mesh ms | Vertices | Triangles | Raycast ms | Add dab ms | Bricks/dab | Flush ms | Flush ms max | Upload KB/frame | Regrows | Mesh MB | Stroke end ms | Undo MB | Undo ms | Redo ms | Smooth dab ms | Inflate dab ms | To mesh ms |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 256 | 7k | 9.4 | 23 | 66 | 347k | 617k | 0.005 | 0.20 | 52 | 0.93 | 1.77 | 540 | 0 | 23 | 41 | 1.2 | 7.7 | 7.5 | 0.25 | 0.14 | 234 |
| 512 | 29k | 36.0 | 124 | 254 | 1.39M | 2.47M | 0.008 | 0.70 | 172 | 2.39 | 2.95 | 1646 | 0 | 91 | 131 | 6.6 | 23.0 | 30.8 | 0.63 | 0.36 | 1156 |
| 1024 | 119k | 145.5 | 350 | 817 | 5.57M | 9.88M | 0.012 | 3.95 | 720 | 12.16 | 48.37 | 26773 | 1 | 414 | 869 | 61.5 | 119.5 | 141.9 | 1.77 | 1.22 | 6837 |
peak RSS: 1425 MB

## 2026-10-27 stage 3 (Convert to voxels), 4 threads, release
| Voxels across | To mesh ms | From mesh ms (clay_from_mesh at the same across) |
| --- | --- | --- |
| 256 | 249 | 277 |
| 512 | 1112 | 1220 |
| 1024 | 6667 | 5942 |
peak RSS 1824 MB (the mesh and both clays alive at once at 1024).

## 2026-10-27 stage 4 (Res+/Res−), 4 threads, release
| Voxels across | Res− ms (→ half) | Res+ ms (→ back) |
| --- | --- | --- |
| 256 | 98 | 61 |
| 512 | 396 | 251 |
| 1024 | 1642 | 1197 |
Before the gather + no-repair-at-×2 + grow-in-rounds changes: 349–6750 / 369–6187 ms.

## 2026-10-27 stage 5 (manifold surface), 4 threads, release (machine noisier this run, ~20%)
| Voxels across | Fill ms | First mesh ms | Add dab ms | Flush ms | Stroke end ms | To mesh ms |
| --- | --- | --- | --- | --- | --- | --- |
| 256 | 43 | 76 | 0.35 | 1.15 | 42 | 252 |
| 512 | 164 | 344 | 0.97 | 4.11 | 190 | 1172 |
| 1024 | 657 | 1108 | 4.45 | 15.2 | 1190 | 7058 |
A/B at 1024 with the saddle scan per dab: Add dab 6.4 vs 5.0–5.5 ms without → moved the scan to the stroke's end.
