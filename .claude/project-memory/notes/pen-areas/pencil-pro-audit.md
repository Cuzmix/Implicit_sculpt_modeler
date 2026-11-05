# Apple Pencil Pro: every feature, and where the app has it (2026-11-03)

| Feature | In the app | Where |
|---|---|---|
| Pressure | Yes: pressure curve, size and strength | brush Pen page |
| Tilt (altitude) | Yes: lean grows size, lean softens; SDL's iPad tilt bug fixed in app | Lean page, pencil.odin |
| Azimuth | Yes: tilt push direction, and the new **Pen lean** alpha mode (#517) | Alpha section |
| Barrel roll | Yes: every slider, Pen roll alpha, view twist on hover, twist during Grab/Elastic, shelf pages, History scrub, choices, Disc hue | Settings > Pen > Where the pen points |
| Hover | Yes: ring fades with height, alpha outline previews roll/lean, tooltips, highlights | Settings > Touch |
| Double-tap | Yes: follows the iPad setting or any command, separately per place | Where the pen points |
| Squeeze | Yes: same, plus ignored mid-stroke; brush pie at the tip by default | Where the pen points |
| Haptics | Yes: snapping, pie, roll steps, shapes finished | pencil.odin haptic |
| Low latency | Yes: 240 Hz coalesced samples, predicted touch leads the ring | pen_samples.odin |
| Only Draw with Apple Pencil | Yes: finger turns the view | iPad Settings |
| Scribble | Yes, in text fields | sculpt_ios.m |
| Undo shortcuts | Double-tap or squeeze can map to Undo/Redo; roll over Undo scrubs History | Where the pen points |
| Find My | Not applicable (system feature) | |
| Estimated pressure refined later | Not used: UIKit corrects the first samples' force a moment late; dabs already laid aren't redone | |

## Try on the iPad
1. Pick an alpha (Star), set its mode to **Pen lean**, and hover: the outline's tick should point where the pencil's top leans. Shade with it laid on its side.
2. Hold the pencil upright: the outline keeps its last direction.
3. Then run the earlier list: /mnt/project-files/notes/pen-areas/try-it.md
