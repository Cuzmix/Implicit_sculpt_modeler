# remesh_check: 20000 vertices asked of Remesh, 2000 quads of Quad Remesh

| Fixture | Tool | Result | Quads | Four-valent | Edges | Volume | Deviation max / mean | ms (result line) | Peak MB | Check |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| sphere | remesh | 20,004 vertices, 40,004 faces | 0.0% (40004 not) | 8.9% | closed | 4.1846 | 0.05% / 0.003% | 124 | 173 | PASS, stable |
| sphere | remesh-quads | 20,006 vertices, 20,004 faces | 100.0% (0 not) | 48.7% | closed | 4.1825 | 0.02% / 0.006% | 109 | 176 | PASS, stable |
| sphere | quad-remesh | 1,534 vertices, 1,532 faces | 100.0% (0 not) | 99.2% | closed | 4.1543 | 0.06% / 0.030% | 613 | 239 | PASS, stable |
| torus | remesh | 19,176 vertices, 38,352 faces | 0.0% (38352 not) | 8.7% | closed | 3.1432 | 0.06% / 0.004% | 114 | 170 | PASS, stable |
| torus | remesh-quads | 19,176 vertices, 19,176 faces | 100.0% (0 not) | 53.2% | closed | 3.1394 | 0.05% / 0.008% | 88 | 167 | PASS, stable |
| torus | quad-remesh | 1,612 vertices, 1,612 faces | 100.0% (0 not) | 100.0% | closed | 3.1007 | 0.10% / 0.034% | 517 | 236 | PASS, stable |
| overlap | remesh | 14,160 vertices, 28,316 faces | 0.0% (28316 not) | 9.5% | closed | 6.7018 | 0.18% / 0.004% | 126 | 170 | PASS, stable |
| overlap | remesh-quads | 14,162 vertices, 14,160 faces | 100.0% (0 not) | 50.1% | closed | 6.6967 | 0.23% / 0.010% | 121 | 169 | PASS, stable |
| overlap | quad-remesh | 1,610 vertices, 1,606 faces | 100.0% (0 not) | 99.0% | closed | 8.2373 | 0.12% / 0.062% | 564 | 238 | PASS, stable |
| gap | remesh | 19,986 vertices, 39,972 faces | 0.0% (39972 not) | 8.8% | closed | 8.3657 | 0.13% / 0.003% | 134 | 171 | PASS, stable |
| gap | remesh-quads | 19,986 vertices, 19,986 faces | 100.0% (0 not) | 49.0% | closed | 8.3576 | 0.23% / 0.007% | 147 | 176 | PASS, stable |
| gap | quad-remesh | 1,538 vertices, 1,534 faces | 100.0% (0 not) | 99.0% | closed | 8.2337 | 0.09% / 0.047% | 548 | 239 | PASS, stable |
| rod | remesh | 19,400 vertices, 38,796 faces | 0.0% (38796 not) | 8.8% | closed | 4.1859 | 0.13% / 0.003% | 157 | 170 | PASS, stable |
| rod | remesh-quads | 19,402 vertices, 19,400 faces | 100.0% (0 not) | 48.9% | closed | 4.1836 | 0.23% / 0.006% | 129 | 169 | PASS, stable |
| rod | quad-remesh | 2,002 quads (built-in, as AutoRemesher said 48 faces are turned inside out), not exported since the run warned | | | | | | 821 | 220 | FAIL (built-in, as AutoRemesher said 48 faces are turned inside out) |
| cylinder | remesh | 20,256 vertices, 40,508 faces | 0.0% (40508 not) | 0.2% | closed | 1.5652 | 19.80% / 1.118% | 129 | 171 | PASS, stable |
| cylinder | remesh-quads | 20,258 vertices, 20,256 faces | 100.0% (0 not) | 98.9% | closed | 1.5643 | 20.32% / 1.122% | 105 | 171 | PASS, stable |
| cylinder | quad-remesh | 2,340 vertices, 2,250 faces | 100.0% (0 not) | 92.3% | 180 boundary, 0 non-manifold, 0 inconsistent | -1.0417 | 0.08% / 0.011% | 667 | 239 | PASS |
| pieces | remesh | 20,064 vertices, 40,116 faces | 0.0% (40116 not) | 9.0% | closed | 4.7631 | 0.05% / 0.003% | 156 | 171 | PASS, stable |
| pieces | remesh-quads | 20,070 vertices, 20,064 faces | 100.0% (0 not) | 48.1% | closed | 4.7583 | 0.04% / 0.007% | 100 | 169 | PASS, stable |
| pieces | quad-remesh | 1,511 vertices, 1,505 faces | 100.0% (0 not) | 98.4% | closed | 4.6913 | 0.22% / 0.035% | 370 | 228 | PASS, stable |
| nonmanifold | remesh | 12,806 vertices, 25,604 faces | 0.0% (25604 not) | 0.0% | closed | 1.9970 | 0.12% / 0.003% | 62 | 159 | PASS, stable |
| nonmanifold | remesh-quads | 12,810 vertices, 12,806 faces | 100.0% (0 not) | 99.9% | closed | 1.9943 | 0.42% / 0.011% | 54 | 159 | PASS, stable |
| nonmanifold | quad-remesh | refused: quad remesh: nonmanifold has too few triangles for 2000 quads | | | | | |  | 152 | PASS |
| bumpy | remesh | 20,028 vertices, 40,052 faces | 0.0% (40052 not) | 8.2% | closed | 4.1646 | 0.08% / 0.004% | 168 | 181 | PASS, stable |
| bumpy | remesh-quads | 20,030 vertices, 20,028 faces | 100.0% (0 not) | 49.3% | closed | 4.1622 | 0.05% / 0.009% | 153 | 181 | PASS, stable |
| bumpy | quad-remesh | 1,494 vertices, 1,492 faces | 100.0% (0 not) | 99.5% | closed | 4.1306 | 0.30% / 0.058% | 748 | 253 | FAIL (1492 faces for 2000 asked), stable |
| nan | remesh | not imported: a number that does not parse | | | | | |  | 0 | PASS (the import refused it) |
| nan | remesh-quads | not imported: a number that does not parse | | | | | |  | 0 | PASS (the import refused it) |
| nan | quad-remesh | not imported: a number that does not parse | | | | | |  | 0 | PASS (the import refused it) |
| duplicate | remesh | 19,998 vertices, 39,992 faces | 0.0% (39992 not) | 8.8% | closed | 4.1508 | 0.05% / 0.004% | 114 | 170 | PASS, stable |
| duplicate | remesh-quads | 20,000 vertices, 19,998 faces | 100.0% (0 not) | 48.9% | closed | 4.1487 | 0.05% / 0.006% | 94 | 171 | PASS, stable |
| duplicate | quad-remesh | 2,125 quads (built-in, as AutoRemesher said 1 triangles lie over another), not exported since the run warned | | | | | | 554 | 210 | PASS |
| flipped | remesh | 20,004 vertices, 40,004 faces | 0.0% (40004 not) | 8.8% | closed | 4.1508 | 0.05% / 0.004% | 120 | 170 | PASS, stable |
| flipped | remesh-quads | 20,006 vertices, 20,004 faces | 100.0% (0 not) | 48.8% | closed | 4.1487 | 0.05% / 0.006% | 83 | 170 | PASS, stable |
| flipped | quad-remesh | 2,128 quads (built-in, as AutoRemesher said 3 faces are turned inside out), not exported since the run warned | | | | | | 546 | 211 | PASS |
