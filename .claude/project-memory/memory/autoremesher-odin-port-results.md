---
name: autoremesher-odin-port-results
description: Results, bench numbers and gotchas of each merged PR of the AutoRemesher-to-Odin port (PR 1-10, 2026-11-04/05)
metadata:
  type: project
  modified: 2026-11-05T09:53:54.935Z
---

C++ bench (cloud VM, release, 4 threads, 20k quads): ~12-16 s at 500k-1M vertices.
PR 1 #629 driver byte-identical to C++. PR 2 #630 extraction (QEx from the paper): fixed point 2^24, lattice_patch for folds.
PR 3 #636 thin + own isotropic: min angle 33-42 vs C++ 24-37. PR 4 #637 src/sparse (AMD, LDLT, beats Eigen; inner loop needs raw_data pointers).
PR 5 #639 field + complex LDL^H, matches C++ to the bit. PR 6 #640 cover on supernodal Cholesky (same bits any pool); #641 peak memory <= C++ at every size.
PR 7 #642 symmetry without caps. PR 8a #643 guides. PR 8b #644 C++ deleted, web runs it single-threaded. Bench 500k/1M 2.46/2.57 s.
PR 9 #645 low counts: folds exist in the relaxed cover before rounding, so QGP quantization was dropped; singular_simplify on scaled fields, fold-triggered rounding, density-weighted island share, landing counts quads_kept (+3 covers when off >2 %). Picking among covers didn't help (folds structural).
PR 9b #646 Keep borders (Params.frozen, frozen.odin, retopo Options.keep_borders): per-cover regrade, curl stretch held on border faces, FROZEN_GRADE 0.15, landing picks fewest frozen_misses; border sets the count.
PR 9c #648 extraction mends: extract_twins (part 2 quads round, edge of 4 faces) and extract_bridges (annular hole capped twice cut a tail off). Creature one piece Euler 2 at 300-3000.
PR 9d #661 (2026-11-05) shapes at low counts: the cause was NOT the field (tail tip holds +1, poles sum to 8 quarters) but the isotropic mesh at ~2 tris/quad: thin parts' density leaves a tail a tube of 3-4 tris, the cover folds it flat, extraction caps it. Fix in driver.odin: ISOTROPIC_LEAST 8000 tris, ISOTROPIC_FINEST 2 (edge >= half plain), never more than half the input's tris (low-poly spheres' facets read as curvature -> 336 poles), frozen islands keep voxel_plain. Creature max loss 500: 21.7->5.0 %, 700: 18.3->4.9, 1200: 35.7->2.3; 4000+ unchanged; bench unchanged; engine 500 1.15->1.81 s, 1000 1.12->2.79 s. Test driver_keeps_thin_parts_at_low_counts (tailed ball).
Dead ends in 9d: cover weights, curl stretch limits, count nudging, THIN_AROUND 4/5, THIN_DENSITY_MAX caps, pair-hop reach x2, curvature scale 0.5, Taubin-smoothed field.
Open after 9d: finer mesh has more poles (500: 110->160 singular, 74->66 % four-valent; 2000 92->88 %); 300/400 still lose ears (11.5 %), 300 lands 16 % over.
PR 10 #673 (2026-11-05) corpus+polish: fixtures spikes/slit/horns/fingers (horns, fingers = parts united by Remesh first), loss column (input->quads), QUAD_* acceptance raised; 48 rows pass at 2000. quad_onto_surface (onto.odin, 0.5 quad edge): corners were up to 0.67 % off on isotropic chords. THIN_SAMPLES_MAX 120k: 20k quads 5.5->4.9 s. Built-in kept (2.4x ours at 20k). Symmetry: open_seam_bridges before slivers, dissolve_doublets until none (needed 5 rounds); creature mirrors 1000-10000 one piece.
Open after 10: mirrored creature 2000 loses centre horn (~3 %): the half gets ISOTROPIC_LEAST whole, so is meshed like the whole at 1000; sharing it by copies fixed 2000 but broke 1500 (fallback) and 6000 (pinch), reverted. Mirrored 1000 lands 5 % short. Remesh's count on the hand 9 % short. Check pieces with Euler, not just open/non-manifold edges.
Known: 3 app tests fail on odin-sculpt itself (kit_more x2, textured_export), not ours. Scratch tools (exp.sh, lost.py, topo.py, index.py) live only in the container.
