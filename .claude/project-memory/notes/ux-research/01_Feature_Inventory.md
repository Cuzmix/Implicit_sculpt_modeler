# 01 · Feature Inventory

Every feature found in the crawl, grouped by the 40 analysis categories of the brief, with its purpose, the workflow it lives in, the problem it solves and its UX profile. Sources are IDs from `00_Sources.md`; the full page notes are in `raw/`.

**Columns.** Z = ZBrush (desktop + iPad), N = Nomad Sculpt, C = 3DCoat, **Us** = our app at `922f797` (see 13). ✓ has it, ◐ partial, – absent.
**LC** learning curve, **Disc** discoverability, **Eff** efficiency impact for an expert: L / M / H.

How to read the profile columns: a feature with LC=H and Disc=L is a "power tool behind a wall"; a feature with Eff=H that we lack is a roadmap candidate (see 12).

---

## 1-3. Navigation, camera, input

| Feature | Z | N | C | Us | Purpose / problem solved | Workflow + UX implications | LC | Disc | Eff | Evidence |
|---|---|---|---|---|---|---|---|---|---|---|
| Drag on empty space orbits | ✓ | ✓ | ✓ | ✓ | Navigate without leaving the drawing tool | Pen never changes mode; fails when the model fills the screen (needs a fallback) | L | M | H | Z018, Z021, N012, C005 |
| Right-drag navigation (orbit over the model) | ✓ pref | – | ✓ | ✓ | Orbit when there is no empty space | Desktop-only; ZBrush hides it behind a preference | L | L | H | Z018, Z074, C005 |
| Alt + drag pan, Alt-release zoom chord | ✓ | ✓ | ✓ Alt+RMB | ✓ | Pen-only navigation | Mid-drag modifier release is undiscoverable | H | L | M | Z018, N002, C005 |
| Shift snaps to axis views (+ ortho) | ✓ | ✓ | ✓ | ✓ | Fast orthographic checks | Needs a keyboard; Nomad also snaps when the nav cube is tapped | L | M | H | Z019, N012, C005 |
| Two-finger pan / pinch zoom / twist roll | ✓ | ✓ | – | ✓ | Touch navigation | Roll on by default in ZBrush iPad is a documented annoyance | L | H | H | Z021, Z020, N012 |
| "Two fingers down, lift one" orbit when no background | – | ✓ | – | – | Orbit when the model fills the screen on touch | Clever but hidden; only in the camera page | M | L | M | N012 |
| Double-tap model = set pivot; background = frame selection | – | ✓ | F key | ◐ F frames | Recentre orbit where you work | Removes the main "getting lost" cause | L | M | H | N012, C005 |
| Pivot dot shown while orbiting | – | ✓ | ◐ | – | Explains orbit behaviour | Cheap feedback, can be hidden later | L | H | M | N012, N018 |
| Turntable vs trackball / Rot Y vs Rot XYZ | ✓ | ✓ | ✓ | ✓ | Match artist habit | Setting, not a mode switch | L | M | M | Z020, N012, C007 |
| Navigation presets (ZBrush / Maya / Blender style) | – | – | ✓ | – | Lower switching cost | Full remap panel; Blender needs manual remap | M | M | H | C005, C006 |
| Named camera views + reference image per view | ✓ | ✓ | ✓ | ◐ axis views | Repeatable framing; front/side reference setups | Nomad ties a reference image to each saved camera | L | M | M | Z110, N012, N011, C005 |
| Camera undo separate from model undo | ✓ (14 steps) | ◐ restore camera per undo | – | – | Recover the view without undoing work | ZBrush: separate stack; Nomad: each undo restores its view | L | L | M | Z110, N019 |
| Lock camera (stroke off-mesh doesn't orbit) | ✓ | ◐ setting | ✓ nav zones | ✓ "waits for the model" | Prevent accidental orbit | Matters most on touch | L | L | M | Z110, N003, C005 |
| View cube / CamView / snap cube | ✓ | ✓ | ✓ | – | Orientation + one-tap axis views | Touch-friendly; ZBrush draws a sprite figure | L | H | M | Z125, N018, C007 |
| Universal camera: focal length, auto-crop | ✓ | ✓ FOV | ✓ FOV | ◐ ortho only | Correct proportions; avoid near-plane distortion | Low FOV recommended for sculpting | M | M | M | Z110, N012, C007 |
| 3D mouse (3Dconnexion) | ✓ | ✓ (2.9 Mac) | ✓ | – | Two-handed navigation | Desktop power users | M | M | H | Z111, N022, C078 |
| Stylus side buttons mapped | ◐ | ✓ | ✓ | – | Navigate without keyboard | Rocker = pan/orbit (Nomad), size/depth (3DCoat) | L | L | H | N002, C007 |
| Gamepad / MIDI bindings | – | ✓ | – | – | Off-hand controller | Nomad bindings accept gamepad | M | L | M | N003 |
| Three-finger drag = size / strength (or focal) | ✓ | ✓ | – | ✓ | Brush params without UI | Conflicts with iPadOS zoom accessibility | L | L | H | Z021, N003 |
| Two/three-finger tap undo/redo (hold to repeat) | ✓ | ✓ | – | ✓ (no repeat) | One-hand undo | Palm false positives are a top Nomad complaint | L | M | H | Z022, N019, N022 |
| Four-finger tap hides all UI | – | ✓ | Tab | Tab | Maximise canvas on small screens | Hidden gesture | L | L | M | N021 |
| Assignable 1-4 finger taps | ✓ | ◐ | – | – | Personal shortcuts | Defaults only in images (ZBrush docs) | M | L | M | Z022 |
| Stroke offset (brush away from finger) | – | ✓ | – | – | Finger occlusion on phones | Simple fix for touch occlusion | L | L | M | N013 |
| Palm/hand rejection while pen near | ◐ OS | ◐ OS + threshold | n/a | ✓ | Avoid accidental gestures | Nomad users lost work to palm undo | L | L | H | N022, Z022 |

## 4-6. Tablet, touch and mouse workflows

| Feature | Z | N | C | Us | Purpose | UX implications | LC | Disc | Eff | Evidence |
|---|---|---|---|---|---|---|---|---|---|---|
| On-screen modifier wheel (Shift/Ctrl/Alt/Space) | ✓ iPad | – | – | – | Desktop modifier model on touch | Hold-and-slide chords; colour-coded cursor confirms mode | M | M | H | Z023 |
| Sticky buttons: tap = latch, hold = momentary | – | ✓ | ✓ sticky keys | – | Temporary tool without mode errors | Nomad Sub/Smooth/Mask/Hide/Gizmo all work this way | L | M | H | N004, N003, C004 |
| Long press = options / secondary action | ✓ | ✓ | – | ◐ | Secondary actions without right-click | Consistent in Nomad and ZBrush iPad; haptic on press | L | M | H | Z032, N002, Z151 |
| Long press + drag on slider icon scrubs value | ✓ | – | – | ✓ (sliders follow motion) | Fast param change | Ours already moves relative to finger | L | L | H | Z032 |
| Pencil hover tooltips + shortcut | ✓ | ✓ hover dot | n/a | – | Discoverability on tablets | Requires hover-capable pen | L | H | M | Z031, N003 |
| Pencil double-tap / squeeze / barrel roll actions | ✓ | ✓ | n/a | – | Off-canvas shortcut | Pen-specific | L | M | M | Z017, Z029, N020 |
| Pressure attributes (size / depth / colour) | ✓ | ✓ curves | ✓ curves | ✓ curves | Expressive strokes | Nomad/3DCoat expose curves; ZBrush iPad sliders only | M | M | H | Z030, N013, C025 |
| Finger pressure handling ("allow unrecognized pressure") | – | ✓ | – | – | Android fingers report fake pressure | Android-specific trap we will hit | L | L | M | N014 |
| Touch strength / finger sculpt toggle | ✓ | ✓ "finger always smooths" | – | ✓ one finger sculpts/turns | Separate finger and pen roles | Nomad's finger-smooths is a neat role split | L | M | M | Z022, N003 |
| Wintab vs Windows Ink selection | – | – | ✓ | ◐ SDL | Windows tablet compatibility | 3DCoat support's #1 fix | M | L | M | C031, C032 |
| Accessibility assistive window (drag, pinch, roll buttons) | – | ✓ | – | – | Users who can't multitouch | Rare and valuable | L | L | M | N003 |
| Mouse: Ctrl+hover help, Ctrl+Alt+click assign key | ✓ | – | END key | – | In-place help + binding | Fast for experts, invisible for others | M | L | H | Z070, C004 |

## 7-8. Brush systems and stroke engines

| Feature | Z | N | C | Us | Purpose | UX implications | LC | Disc | Eff | Evidence |
|---|---|---|---|---|---|---|---|---|---|---|
| Large brush library | 200-500+ | ~30 tools | 100+ | 14 | Coverage of marks | Library size helps experts, overwhelms beginners | H | L | H | Z001, N004, C015 |
| Brush = preset (save, clone, revert, icon) | ✓ | ✓ | ✓ | – | Personal kits | Nomad: context menu on any tool (Save, Clone, Last save, Reset) | L | M | H | N004, C086, Z084 |
| Brush as modifier stack | ◐ modifiers | – | ✓ | – | Compose behaviours | 3DCoat brush = stack of Smooth/Pinch/Rotate/... blocks | H | L | H | C019 |
| 3-key brush chord (B, S, T) | ✓ | – | – | – | Pick any brush by name | Fast for experts, memorisation | H | L | H | Z070 |
| Space quick menu / pie with search | ✓ | – | ✓ | ✓ pie | Tools at the cursor | 3DCoat: searchable, 1-9 slots; ours: brush pie | L | M | H | Z070, C008 |
| Shift = smooth (bound brush, own settings) | ✓ | ✓ button | ✓ | ✓ | Most-used secondary brush | ZBrush remembers smooth settings separately | L | M | H | Z121, N002, C020 |
| Ctrl/Alt/Sub = invert | ✓ Alt | ✓ Sub | ✓ Ctrl | ✓ Ctrl | Add vs subtract | Sub button on touch | L | M | H | Z070, N004, C020 |
| RMB drag = size (horiz) / depth (vert) | – | – | ✓ | – | One-gesture brush params | Same grammar scales placed primitives | L | M | H | C020, C081 |
| Alphas (greyscale, 16-bit, multi-channel) | ✓ | ✓ | ✓ | ✓ | Shape of the stamp | 3DCoat alphas carry colour/height/spec channels | M | M | H | Z086, N013, C024 |
| Stroke types: dots, drag-rect, spray, roll, lock+radius | ✓ | ✓ | ✓ 20 modes (E) | ◐ dots, drag-rect | Marks, stamps, stitches | 3DCoat E-panel = 20 modes in one popup | M | M | H | Z087, N013, C021 |
| Lazy mouse / rope / steady stroke / smoothing | ✓ | ✓ | ✓ | ✓ lazy | Clean lines | Nomad separates rope vs smoothing | L | M | H | Z085, N013, C069 |
| LazySnap / snap radius (continue last stroke) | ✓ | ✓ | – | – | Join strokes | Pressure seam issue documented | M | L | M | Z085, N013 |
| Straight line (Shift mid-stroke) | ✓ | ◐ 2.9 | ✓ | – | Straight marks | Modifier timing changes meaning | M | L | M | Z085, C024 |
| Stroke pause (Space while held) | ✓ | – | – | – | Reposition mid-stroke | Hidden | M | L | L | Z085 |
| Curve mode (stroke along editable curve) | ✓ | ✓ tube | ✓ | ◐ curve tool | Stitches, belts, seams | Only current curve editable (ZBrush) | M | M | H | Z139, N004, C101 |
| Replay last stroke / record strokes | ✓ 1/2/3 keys | ✓ 2.9 history replay | ✓ record strokes | ✓ stroke recorder | Repeat marks | We already have this | M | L | M | Z070, N022, C101 |
| Adjust last stroke strength after the fact | ✓ | – | – | – | Fix intensity without undo | "Adjust last operation" pattern | L | L | H | Z123 |
| History brush (local undo by painting) | ✓ | ✓ DelLayer local | – | – | Undo a region only | Spatial undo | M | L | H | Z004, Z140, N004 |
| Falloff curve editor + presets | ✓ | ✓ | ✓ | ✓ | Brush profile | All four have it | M | M | M | N013, C025 |
| Front-faces only / connected only / protect masks | ✓ | ✓ | ✓ | ◐ front only | Avoid spill-through | Nomad Filter section is the richest | M | L | H | N013 |
| Area sampling / plane locks (flatten drift) | ✓ | ✓ | ✓ on plane | – | Predictable flatten | Nomad admits drift without locks | M | L | M | N004, N013, C069 |
| Depth masking / conditions (cavity, convex, top) | ◐ masking by cavity | ✓ depth masking | ✓ conditions | – | Paint/sculpt only into cavities etc. | 3DCoat conditions must be reset or they keep limiting | H | L | H | N013, C023 |
| Paint while sculpting (one stroke, both channels) | ✓ Mrgb | ✓ | ✓ | ◐ separate Paint brush | Fewer passes | Channel toggles instead of separate tools | M | M | H | Z091, N015, C025 |
| Dual alpha / texture blended by pressure | ✓ | – | – | – | Varied marks | Niche | H | L | M | Z013 |
| VDM / 3D stamps (undercuts) | ✓ | ✓ 2.9 | ✓ early | – | Ears, noses, scales in one stamp | Industry trend | M | M | H | Z004, N022, C090 |
| Insert mesh / IMM along curve | ✓ | ✓ Insert | ✓ primitives/kitbash | ✓ insert | Kitbash | Click-drag places and scales | M | M | H | Z120, N004, C087 |

## 9-15. Sculpt workflows, topology, remeshing, voxels

| Feature | Z | N | C | Us | Purpose | UX implications | LC | Disc | Eff | Evidence |
|---|---|---|---|---|---|---|---|---|---|---|
| Subdivision levels (multires) | ✓ | ✓ | ✓ surface only | ✓ | Big forms low, detail high | Topology ops wipe levels in Nomad (warns first) | M | M | H | Z059, N007, C043 |
| Reverse / add lower level | ◐ | ✓ | ✓ decimation | – | Recover a base after import | Needs subdivision-born mesh (Nomad) | M | L | M | N007, C043 |
| Lock base level (LV0) | – | ✓ | – | – | Protect cage | Simple safety | L | L | M | N007 |
| HD geometry (regional windows, 1B polys) | ✓ | – | – | ✓ | Beyond-RAM detail | `A` key over region | H | L | H | Z060 |
| Dynamic subdivision (smooth preview of cage) | ✓ | ◐ post-subdivision | ✓ modeling room | – | Low-poly modelling with smooth result | ZBrush D key changes meaning by mesh state | M | L | H | Z068, Z069, C054 |
| Voxel remesh (DynaMesh) | ✓ | ✓ | ✓ native voxels | ✓ | Uniform topology while blocking | Ctrl+drag on empty canvas re-meshes (ZBrush) | M | M | H | Z075, N007, C012 |
| Remesh on a gesture (Ctrl-drag background) | ✓ | – | ✓ Enter | ◐ Ctrl+R | Remesh without leaving the canvas | Gesture collides with mask-clear meaning | M | L | H | Z075, C013 |
| Remesh resolution preview (checkerboard) | – | ✓ | – | – | See density before committing | Excellent feedback | L | H | M | N007, N006 |
| Dynamic tessellation (Sculptris Pro / dyntopo / auto-subdivide) | ✓ | ✓ | ✓ | ✓ | Add detail where needed | Cursor colour shows compatibility (ZBrush) | M | M | H | Z077, N007, C013 |
| Dyntopo detail by screen / radius / constant | ◐ | ✓ | ✓ screen-space subdivide | ◐ px | Predictable density | Nomad's radius mode ties detail to brush size | M | L | M | N007, C046 |
| True voxel volumes (0..1 field, iso 0.5) | – | ◐ triplanar | ✓ | – (SDF spike) | Topology-free volume, booleans | Thin parts jaggy, no layers, memory heavy | M | M | H | C074, C012 |
| Voxel ⇄ surface per object (V/S) | – | – | ✓ | – | Pick the right representation per part | Switching loses sculpt layers/masks | H | M | H | C010, C013, C075 |
| Density vs resolution (per volume) | ◐ | ◐ | ✓ | ◐ vertex target | Detail budget | "Trial and error" admitted | H | L | M | C018 |
| Auto-retopology (ZRemesher / Quad Remesher / Autopo) | ✓ | ✓ paid iOS/desktop | ✓ | ✓ basic | Clean quads for animation | Guides + density paint across all three | M | M | H | Z078, N004, C035 |
| Retopo guide curves + density paint | ✓ | ✓ | ✓ | – | Steer edge flow | Over-guiding admitted by 3DCoat | H | L | H | Z127, N004, C035 |
| Manual retopo (topology brush, strokes, ZSphere, quads) | ✓ | – (top request) | ✓ room | – | Animation-grade topology | Nomad's #6 feature request | H | M | H | Z007, N022, C036 |
| Decimation preserving paint/borders | ✓ plugin | ✓ | ✓ | ✓ | Print, export, LOD | ZBrush needs preprocess step | L | M | M | Z101, N007 |
| Proxy pose (temporary low-res to pose) | ✓ | – | ✓ proxy | – | Pose heavy meshes | Settings must be set before entering | M | L | M | Z155, C046 |
| Project detail / history projection | ✓ | ✓ reproject | ✓ reproject | ✓ project | Transfer detail between topologies | ZBrush can project from any undo point | M | M | H | Z117, N007, C044 |

## 16-18. Layers, hierarchy, scene

| Feature | Z | N | C | Us | Purpose | UX implications | LC | Disc | Eff | Evidence |
|---|---|---|---|---|---|---|---|---|---|---|
| Sculpt layers (record, strength, bake) | ✓ | ✓ (survive topology change) | ✓ surface only | ✓ | Non-destructive detail, expressions | ZBrush: must create at top level, Record toggle; Nomad: always on, survives remesh | M | M | H | Z089, N017, C011 |
| Paint layers with blend modes | ◐ | ✓ 25 modes | ✓ PS-style | – | Non-destructive colour | 3DCoat layers are scene-wide, not per object | M | M | H | N017, C040 |
| Layer channel factors / per-channel opacity | – | ✓ | ✓ | – | Mix sculpt vs colour per layer | Nomad: one shared opacity channel (admitted limit) | H | L | M | N017, C040 |
| Morph target + Morph brush | ✓ | ◐ via layers | ✓ hide SL | ✓ | Restore base locally | One per subtool (ZBrush) | M | L | M | Z090, C076 |
| Object list / SubTools | ✓ flat + 1 folder level | ✓ tree | ✓ tree | ✓ flat | Many parts | ZBrush: no nesting, many folder ops not undoable | M | M | H | Z057, Z058, N006, C010 |
| Groups / folders / parenting | ◐ | ✓ | ✓ | – | Organise 50+ parts | Nomad: long-press to reorder/parent; drag down column to multi-select/hide | L | M | H | N006, C010 |
| Instances / clones / sync | ◐ NanoMesh/Array | ✓ | ✓ instancer | – | Repeat parts, edit once | Nomad colour capsule marks instances | M | M | H | N006, C044 |
| Repeaters (array, radial, curve, mirror nodes) | ✓ ArrayMesh | ✓ | ✓ array | – | Procedural repetition | Non-destructive until validated | M | M | H | Z100, N006, C044 |
| Ghost objects (visible, unpickable) | ✓ transparency | ✓ x-ray | ✓ ghost | – | Context without interference | 3DCoat ghost protects from edits | L | M | M | Z026, N002, C010 |
| Solo / isolate | ✓ | ✓ | ✓ Alt+LMB | – | Focus | Bottom-bar toggle in Nomad | L | H | H | Z026, N002, C046 |
| Stager (home/target placement) | ✓ | – | – | – | Sculpt symmetric, view posed | Niche | M | L | M | Z113 |
| Apply last action to all visible / repeat to similar | ✓ | – | – | – | Batch | Skips hidden subtools | M | L | H | Z005, Z057 |
| Lights / cameras as scene nodes | ◐ | ✓ (4 lights) | ✓ | – | Presentation | Nomad caps 4 lights | L | M | L | N009 |

## 19-22. Materials, texturing, painting, UV

| Feature | Z | N | C | Us | Purpose | UX implications | LC | Disc | Eff | Evidence |
|---|---|---|---|---|---|---|---|---|---|---|
| MatCaps | ✓ | ✓ (3-finger rotate) | ✓ (not recommended) | ✓ presets | Read form fast | 3DCoat says use PBR for accuracy | L | H | H | Z093, N009, C007 |
| PBR viewport + HDRI | ◐ | ✓ | ✓ | ✓ | Final look while sculpting | Nomad: post-process off while sculpting | M | M | M | N009, N010, C088 |
| Vertex paint (colour) | ✓ | ✓ +rough/metal | ✓ | ✓ | Paint without UVs | Resolution tied to vertex count | L | M | H | Z091, N015, C042 |
| Vertex PBR (roughness, metalness) | – | ✓ | ✓ | – | Full material without UVs | Nomad's signature | M | M | M | N015 |
| Per-pixel / Ptex / micro-vertex painting | ✓ maps | ✓ bake | ✓ 5 modes | ◐ bake | Game assets | Mode choice is a beginner trap (3DCoat) | H | L | H | C042, C039 |
| Smart materials (cavity/edge aware) | – | – | ✓ | – | Fast realistic texturing | 3DCoat's signature | M | M | H | C041 |
| Node texturing (GPU) | – | – | ✓ 2026 | – | Non-destructive procedural | Heavy concept | H | L | H | C066 |
| Projection texturing (SpotLight) | ✓ | – | ✓ projector | – | Paint from photos | Dial widget, Z toggles | H | L | H | Z092, C007 |
| UV auto-unwrap | ✓ UV Master | ✓ UVAtlas/BFF | ✓ ABF/LSCM/GU | ✓ | Maps for export | Slow above 100k (Nomad) | M | M | M | Z102, N007, C037 |
| UV editor (seams, islands, packing) | ✓ 2027 desktop | – | ✓ room | – | Control | ZBrush editor uses C4D conventions, conflicts (W/E/R) | H | M | H | Z098, C037 |
| Baking (normal, displacement, colour) | ✓ | ✓ | ✓ | ✓ | Low-poly delivery | Nomad: cage radius, ray offset | M | M | H | N007, C035 |

## 23-27. Masking, selection, polygroups, visibility, booleans

| Feature | Z | N | C | Us | Purpose | UX implications | LC | Disc | Eff | Evidence |
|---|---|---|---|---|---|---|---|---|---|---|
| Paint mask (graded 0..1) | ✓ Ctrl | ✓ Mask tool | ✓ Freeze | ✓ | Protect areas | Same idea, three names (mask/freeze) | L | M | H | Z061, N004, C026 |
| Mask shapes: rect / lasso / ellipse / polygon / curve | ✓ | ✓ | ✓ 20 E modes | ◐ rect, lasso | Precise regions | Nomad auto-validate vs confirm button | M | M | H | Z040, N004, C021 |
| Two-phase shape: draw then confirm (green ✓) | ◐ staged commit | ✓ | ✓ Enter | – | Adjust view before committing | Great on touch | L | M | H | N004, Z040 |
| Tap gestures on mask (invert / blur / sharpen / clear) | ✓ Ctrl+click | ✓ hold Mask + tap | – | – | Mask ops without menus | Context = where you tap | M | L | H | Z061, N004 |
| Mask grow / shrink / blur / sharpen | ✓ | ✓ 2.9 | ✓ | ✓ | Refine | Steps control | L | M | M | Z138, N022, C026 |
| Mask by cavity / curvature / AO / topology / region | ✓ | ✓ depth masking | ✓ conditions | – | Automatic selections | Huge power, low discoverability | H | L | H | Z037, Z115, Z114 |
| Mask changed points / group changed points | ✓ | – | – | – | Select what I just sculpted | History as selection | M | L | M | Z138, Z137 |
| Selection sets (named masks/groups/paint) | ✓ 2027 | – | ✓ store freeze to layer | – | Reuse selections | Break on remesh (ZBrush) | M | M | M | Z097, C026 |
| Mask ⇄ group ⇄ layer conversion | ✓ group masked | ✓ convert | ✓ freeze⇄layer⇄pose | ◐ group masked | One selection concept | 3DCoat fully interconvertible | M | L | H | N004, C026, C071 |
| Polygroups / face groups | ✓ | ✓ | ✓ retopo groups | ✓ | Part IDs on one mesh | Make at lowest level (ZBrush) | M | M | H | Z062, N004 |
| Tap a group to isolate / hide / mask | ✓ Ctrl+Shift click | ✓ on-tap | – | – | One-tap visibility | ZBrush result depends on current visibility (admitted ambiguity) | M | L | H | Z063, N003 |
| Hide by rect/lasso, show all, invert | ✓ | ✓ | ✓ | ✓ | Isolate regions | ZBrush green/red by Alt mid-drag | M | M | H | Z063, N004, C072 |
| Live booleans (preview, commit) | ✓ | – (visibility-chosen boolean) | ✓ voxel | ✓ | Hard-surface cuts | ZBrush order-sensitive, cutters hidden | M | M | H | Z154, N006, C016 |
| Boolean op chosen by visibility | – | ✓ | – | – | Quick | Implicit, non-obvious | L | L | M | N006 |
| Boolean by drag-drop in tree with modifiers | – | – | ✓ | – | Fast | Shift merge, Ctrl subtract, Ctrl+Shift intersect | M | L | H | C045 |
| Soft booleans (bevelled joins) | – | – | ✓ | – | Organic seams | Voxel only | M | L | M | C016 |
| Trim / split / clip / slice by shape | ✓ | ✓ (ortho warning) | ✓ cut off | ✓ | Hard-surface cuts | Nomad warns in perspective | M | M | H | Z143, N004, C079 |
| Extract shell from mask | ✓ | ✓ (preview, carve) | ✓ | ✓ | Clothes, armour | Nomad preview in X-ray | M | M | H | Z162, N004 |

## 28-30. Gizmos, transforms, rendering

| Feature | Z | N | C | Us | Purpose | UX implications | LC | Disc | Eff | Evidence |
|---|---|---|---|---|---|---|---|---|---|---|
| Unified gizmo (move/rotate/scale) | ✓ | ✓ | ✓ | ◐ move only | Blockout | Nomad: tap a handle for numeric entry | M | H | H | Z066, N004, C044 |
| Tap surface to place pivot | ✓ | ✓ on-tap modes | ✓ F | – | Fast pivot | Touch-friendly | L | M | H | Z066, N004 |
| Gizmo deformers (bend, twist, taper, FFD...) | ✓ 27 | ✓ lattice 2.9 | ✓ bend/twist/lattice | – | Global shape edits | Nomad users round-trip to Blender for this | M | M | H | Z067, N022, C071 |
| Transpose line / pose with topological mask | ✓ | – | ✓ pose | – | Bend limbs | Ctrl-drag gizmo for topology mask | H | L | H | Z064, Z115, C071 |
| Two-finger transform (Insert/Transform tools) | – | ✓ | – | – | Touch placement | Second finger scales/rotates | M | L | H | N004 |
| Snap translation/rotation, numeric input | ✓ | ✓ | ✓ | ◐ typed values | Precision | Gizmo symmetry off by default (Nomad surprise) | L | M | M | N004, C092 |
| Modal transform hotkeys (W/E/R + axis keys) | ✓ QWER | – | ✓ Blender-like | W move | Keyboard speed | 3DCoat copies Blender G/R/S grammar | M | L | H | C092 |
| Best preview render / studio render | ✓ BPR | ✓ post-process | ✓ render room | ✓ studio | Presentation | Nomad: progressive refine while idle | L | H | M | Z095, N010, C055 |
| Turntable / time-lapse export | ✓ movie | ◐ GIF | ✓ | ✓ time-lapse | Share | Top Nomad request | L | M | M | N022, C055 |
| Silhouette thumbnail | ✓ | – | – | – | Judge form | Classic sculpting aid | L | M | M | Z158 |

## 31-40. Workspace, customisation, shortcuts, menus, performance, scripting, pipeline

| Feature | Z | N | C | Us | Purpose | UX implications | LC | Disc | Eff | Evidence |
|---|---|---|---|---|---|---|---|---|---|---|
| Rooms / workspaces per stage | – | – | ✓ 14 rooms | – | Focus per task | Rooms hide where data moves (admitted) | M | M | H | C053, C002 |
| Curated beginner room / mode | ◐ Core/free | – | ✓ Simplest, Print | – | On-ramp | Reduced tool set, same engine | L | H | M | C056, C065 |
| Task-first start dialog | ◐ Home | ◐ presets | ✓ Quick Start | – | Start right | 3DCoat lists 15 task entries | L | H | M | C063, Z131 |
| Custom UI (drag any button anywhere) | ✓ Ctrl+Alt drag | ✓ floating toolbars | ✓ menu.cpp, windows | – | Personal layout | ZBrush prefs don't autosave (admitted) | H | L | H | Z073, N003, C029 |
| Custom toolbars / quick menus | ✓ iPad 5 | ✓ | ✓ | – | Favourites | iPad: long-press-drag palette items in | M | M | H | Z039, Z134, N003 |
| Rebind any command | ✓ | ✓ searchable | ✓ END | – | Muscle memory | Conflict prompt on iPad; stacked/sticky keys in 3DCoat | M | M | H | Z071, Z152, N003, C004 |
| Searchable command palette | ✓ iPad | ✓ bindings search | ✓ Ctrl+F, Space search | – | Find anything | ZBrush results too broad ("Poly") | L | H | H | Z033, C008, C073 |
| Context (right-click) menus | ◐ | ✓ long press | ✓ RMB everywhere | ◐ scene list | Act on the thing under the pointer | 3DCoat RMB overloaded (short vs long vs hold) | M | M | H | C045, C069 |
| Radial / pie menu | ◐ | – | ✓ paint pie | ✓ | Thumb-reach tools | Ours is brushes only | L | M | H | C099 |
| Undo history panel / timeline / markers | ✓ | ✓ list with memory | ◐ | ✓ timeline | Navigate history | ZBrush markers feed brushes | M | M | H | Z096, Z056, N019 |
| Memory-budgeted undo | ◐ | ✓ MB limit | – | ✓ | Avoid OOM | Nomad shows memory per step | L | M | M | N019 |
| Autosave / quicksave | ✓ | ◐ reminder only | ✓ (saves finish late) | – | Don't lose work | Nomad data loss threads | L | M | H | Z109, N005, C059 |
| LOD / simplified drawing while orbiting | ✓ CPU | ✓ low-res threshold | ✓ GPU quad reduce | ✓ | Fluid camera | We are already strong here | – | – | H | N018, C030 |
| Performance caps (max verts) | ✓ | ✓ 10M default | – | – | Avoid crashes | Mobile RAM is the limit | – | – | M | N018, N020 |
| Scripting (ZScript / Python / C++ Core API) | ✓ | – (plugin API requested) | ✓ | – | Automation, pipeline | 3DCoat: RMB+MMB copies command name | H | L | H | Z105, Z015, C049 |
| Macros (record UI actions) | ✓ | – | ✓ retopo record | – | Repeat sequences | Strict folder rules (ZBrush) | M | L | M | Z106, C034 |
| Plugins / extensions | ✓ ZPlugins | – | ✓ addons, packs | – | Ecosystem | Packs bundle brushes, materials, scripts | H | M | H | Z101, C083 |
| Headless CLI | – | – | ✓ `-script` | ◐ flags | Batch, CI | We have ~100 flags already | M | L | M | C050, 13 |
| Live links (GoZ, Substance, Blender, Photoshop) | ✓ | ✓ 2.9 Link | ✓ applinks, PS | – | Round trips | One-click send/return | L | M | H | Z103, Z014, N022, C039 |
| Formats (OBJ, PLY, glTF, USD, FBX, STL) | ✓ | ✓ broad | ✓ | ◐ OBJ/PLY | Interop | Nomad's export matrix is clear | L | M | M | N005 |
