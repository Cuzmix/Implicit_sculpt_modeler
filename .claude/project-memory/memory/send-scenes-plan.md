---
name: send-scenes-plan
description: 2026-11-03 plan for GoZ-like Send of the whole scene tablet <-> PC over the LAN (8 PRs, src/send), built 2026-11-03, awaiting device run
metadata:
  type: project
  modified: 2026-11-03T08:24:40.405Z
---

Bolt 2026-11-03: "send my scene over the network and open it from computer seamlessly similar to GoZ, let's plan".
Plan doc: https://claude.ai/artifact/2KC4kvCGQ4uj6bLZGjPpbC (thread "Plan sending scenes between devices").

Not the vetoed "LAN collaboration" (that was live co-editing, see [[bolt-preferences]]); this is one-shot send/receive.

Design: whole `.sculpt` v36 file written to an Outbox on a worker (like autosave), streamed over TCP (port 47820) in
FastCDC chunks with BLAKE2b hashes; receiver keeps last file per scene token per device as base, so later sends are deltas.
Desktops listen, tablets connect (Bonjour `_sculptsend._tcp` via dns_sd on Apple, dnsapi on Windows, NsdManager on
Android, own mDNS on Linux; typed-address fallback). X25519 pairing with 6-digit code + Allow; ChaCha20-Poly1305 frames
(Bolt chose encrypt 2026-11-03; flips ITSAppUsesNonExemptEncryption to true). hello refuses another build. Received scene
opens through Open path (no new Scene_Command, no undo change); same token unchanged -> opens in place; changed both
sides -> conflict card; Save goes to path this device last saved token to. Web: hidden.
Compared: GoZ, ZBrush iPad GoZ (LAN, whole .ZPR, flaky w/ big files), Nomad Link v2.9.24 (TCP 48312, Bonjour
`_nomadlink._tcp`, pair tokens, mesh_delta), LocalSend, Live Link Face, Shapr3D cloud, Procreate, own Blender link.
PRs: 1 src/send core, 2 pairing+sealing, 3 desktop receive + send by address (+ sm-store rewrite, permissions),
4 discovery, 5 Send card + pairing UI, 6 deltas+resume, 7 round trips, 8 measure LZ4 compression.
Status: Bolt approved plan + encryption 2026-11-03 08:36. #531 PR1 core, #532 PR2 pairing/sealing, #538 PR3 merged
(--receive/--send-to/--send-allow/--send-folder/--send-port/--exit-after-receive, src/app/send.odin + send_net.odin,
scripts/send_check.py two processes over loopback: resend = 1 of 25 chunks). Gotcha: Odin chacha20 Simd256 wrong in
-debug without AVX2, so seal.odin forces Simd128. #541 PR4 discovery merged: --send-to=@ / @NAME; dns_sd on Darwin, own mDNS responder UDP 5353 on Win/Linux, tablets ask by legacy unicast (never join group). #545 PR5 merged: Send = Export sheet preset (one UI per thing, no separate card), Menu > Send to..., Send_Scene command, pill under top bar (phases, code, Allow/Decline), Settings > Files > Send scenes (send_receive, send_last lines). Touch: 9 scenarios fail on base too (symmetry, pen_response, polyframe, fov, twist x2...), not Send's. #549 PR6 merged: resume (.partial + .partial.list kept on a cut, read back as 2nd Base), .list chunk list beside each copy, Rebuild takes []Base, --send-cut-after=N hook, bench --send (25M: stroke = 93/3021 chunks, 27 of 859 MB; cut 1.7 s serial). Scene header holds write time, so chunk 0 always differs. #551 PR7a merged: send_arrive.odin rules (In_Place/Open/Ask/Conflict by token + exchanged fingerprint), pill Open/Keep, kept/ folder, saved.txt token->path (Save goes back; never-saved asks), --send-arrived=open|keep. Gotcha: setup-script changes count as saved, so conflict tested only by unit test. #555 PR7b merged: not a kept connection but tablets listen while open once paired (refuse pairing as listener, no mDNS answer); Hello.port, PROTOCOL 2; PC keeps sh.backs (addr:port of senders that receive) -> send_last + Export list 'sent here'; iOS background task held while send_busy. #556 PR8 merged: own LZ4 + shuffle4 in src/send/lz4.odin, chunk frame packing byte (kept if <= 7/8), PROTOCOL 3; shuffled LZ4 leaves 42-46% at ~350-420 MB/s. ALL 8 PRs DONE 2026-11-03; awaits Bolt's device run (iPad/OnePlus <-> PC, real Wi-Fi numbers, iPad background task untested).
