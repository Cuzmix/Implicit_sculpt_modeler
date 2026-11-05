# Nomad Sculpt official manual crawl (UX research notes)
Crawled 2026-10-25 via WebFetch (content is passed through a summarizing model that refuses verbatim reproduction, so entries are dense paraphrased facts, not quotes).

---
## PAGE: Overview (Manual index)
URL: https://nomadsculpt.com/manual/
- FEATURES / MENU MAP: Files (projects, import/export), Scene (primitives, scene objects), Topology (mesh topology edits), Material (per-object materials), Shading (lighting), Post Process (screen-space effects), Background (background + reference images), Camera, Stroke (tool settings, stroke, falloff), Pressure (pencil pressure), Painting (paint tool settings), Symmetry (mirror plane), Layers (current object's layers), Settings (3D viewport), Interface (customize UI), Tools (brushes/tools list), History (undo/redo stack), FAQ, Tips.
- NAVIGATION PATTERN of the manual: the sidebar lists Overview, Getting Started, Files, Scene, Topology, Material, Shading, Post process, Background, Camera, Stroke, Painting, Symmetry, Layers, Settings, Interface Menu, Tools, History, FAQ, Tips. Note: "Pressure" is in the menu-overview text but NOT in the sidebar (see crawl log). Many language translations exist.
- Community video tutorials are embedded (Dave Reed, Glen Southern, ProcreateFX, Laurent Briere, Small Robot Studio, DM Art classes): the docs lean on external video for learning.
- DATA STRUCTURES implied by the menu layout: scene of objects -> per-object material, layers, topology; global shading/postprocess/background/camera; tool-level stroke/pressure/painting.

---
## PAGE: Getting Started
URL: https://nomadsculpt.com/manual/gettingstarted
- FEATURES: 3D sculpting app for many devices. Works best on a tablet with a pressure-sensitive stylus. Inspired by ZBrush/Blender but with a simpler interface.
- FIRST-RUN WORKFLOW: the app opens with a sphere already present. Drag the stylus on it to sculpt. Symmetry is ON by default. Default tool = Clay (adds material). The left-toolbar "Sub" button switches to subtract; tap again to go back to add. The "Smooth" button toggles smoothing.
- Painting: pick the Paint tool from the right-side tool menu, tap the colored sphere on the left toolbar to choose a color. The left-toolbar Erase button removes paint; tap again to return to painting.
- Toolbox also has Move, Crease, Inflate, Split, Trim etc. Smooth has its own left-toolbar shortcut because it is used so often.
- GESTURES (touch):
  - Rotate camera: one-finger drag in empty space (off the model).
  - Zoom: two-finger pinch.
  - Pan: two fingers down and drag.
  - Undo: two-finger tap (or the undo button lower-left).
- SHORTCUTS (desktop / pen without touch, Alt/Option key):
  - Rotate: pen-tip drag in empty space.
  - Pan: Alt + tip drag.
  - Zoom: Alt + tip drag, then release Alt and keep dragging.
- Wacom setup recommended: tip = left click, lower rocker = middle click, upper rocker = right click. Upper rocker + hover move = rotate camera; lower rocker + hover move = pan.
- UI LAYOUT (where things sit):
  - Top-left: scene/object menus (Files, Scene, Topology, Material, Shading...). Top-right: tool-related menus (Stroke, Painting, etc.). These collapse on small screens.
  - Stats readout: scene, object, mask, memory info.
  - Nav Cube: shows the view side; tap a face to snap to that view, drag to rotate, small icons beside it frame the object / reset view.
  - Toolbox (right side): scrollable grid of all tools.
  - Left toolbar: Radius and Intensity sliders + context buttons (symmetry, sub/add, mask, smooth, gizmo, paint color).
  - Bottom toolbar: Undo, Redo, History, Solo (show only current object vs all), X-Ray (others drawn x-ray; long-press or swipe-up for color/opacity), Voxel (Voxel Remesher shortcut; long-press/swipe-up for quality), Grid (long-press/swipe-up options), Wire (wireframe overlay; long-press/swipe-up options), Inspect (shows mesh data, UVs by default; long-press/swipe-up for other properties).
  - UX PATTERN: "long-press or swipe-up on a bottom-bar button opens its options popup" = tap toggles, long-press configures.
  - Left-handed mode: mirror the toolbar layout in settings.
- BEGINNER PATH: sculpt the default sphere -> Sub/Smooth toggles -> paint -> then read Tools, Files, Topology, Scene.
- HELP: forum.nomadsculpt.com, Discord server, direct developer contact.

---
## PAGE: Interface Menu
URL: https://nomadsculpt.com/manual/interface
- Note: the page covers the Interface *menu* (customization), not the layout (that is in Getting Started). Four sections: Interface, Gesture, Bindings, Debug.
- INTERFACE section / CUSTOMISATION:
  - Bottom toolbar shortcuts, enabled by default: Undo, Redo, Solo, X-ray, Voxel remesh, Grid, Wireframe, Inspector, Face Group. Voxel/Grid/Wireframe have extra options via long tap or swipe up.
  - "Bindings" button opens a searchable list of functions; tap to add to toolbar, tap again to remove. "Order": long-press and drag to reorder. "Reset" restores defaults.
  - Floating toolbars ("+"): user can create several; each has Visible, Bindings, Order, Reset, Resize corner, Collapsable, Delete.
  - Toolbox: resize corner, hide toolbox, color-code icons by category, auto row layout, reset tool order.
  - Appearance/presets: high-contrast button style, base colors, transparent panels (color + blur), mirror top & side bars, mirror bottom bar, material color preview, hover help popups, sliders for scale/width/font/spacing. Edge offset (only change if buttons near screen edges are hard to hit); docs advise resetting edge options when moving to a new device.
- GESTURE section:
  - Input modes: Camera, Sculpt, Gizmo, material picking (long press), object selection can each be assigned to any combination of finger / stylus / mouse. Option "Finger always smooths" (finger drag = smooth, stylus = sculpt).
  - Mask one-tap shortcuts (optional): tap background = invert mask; tap masked area = blur mask; tap unmasked area = sharpen mask.
  - Mask/SelMask toggle via long press: either by starting a new stroke or by switching tools without moving.
  - Hide one-tap shortcuts: tap to hide a face group; tap empty space to invert hidden polygons.
  - Three-finger gestures (if device supports): vertical and horizontal drags assignable to rotate lighting, tool radius, or tool intensity. Assigning the same gesture to two functions disables one.
  - History: two-finger tap = undo; three-finger tap = redo; long press with 2 or 3 fingers = repeat undo/redo rapidly.
  - Accessibility: "assistive window" floating toolbar for drag, pinch, roll, and camera controls (for users who can't do multi-touch).
  - Some options moved to the Camera menu and the Bindings section.
- BINDINGS section:
  - Most functions bindable to keyboard keys, stylus buttons, or gamepad controls: click the field next to a function, press the input.
  - Category icons + search bar. Each binding has an enable checkbox; context menu: Clone, Reset, Delete, "toggle shortcut on key tap" (distinguishes tap vs hold).
  - Advanced: sticky-key style toggling for mask, smooth, gizmo, hide, sub (hold vs toggle); toggle between two tools sharing a hotkey; invert zoom on Y axis; reset all bindings.
  - iOS with keyboard: hold Cmd to show the shortcut list. Android keyboard support is "experimental".
- DEBUG section (docs: leave at defaults unless support advises):
  - UV: normalize UVs into 0–1 tile. Quad Remesh: Instant Mesh vs Quadriflow backends. Render: heightmap view, refraction backface depth write, flip normal-map Y, angle-weighted smooth normals.
  - Target FPS: sync to display refresh or fixed.
  - Interface: top bar layout (collapse / scroll / multiline), draggable bottom popups, show all tools, colored toolbox, drop shadows, blending, hover dot for stylus users.
  - GIF turntable: duration, rotation center, transparent background, max frame sampling, export. PAIN POINT admitted: GIF quality is low; screen recording usually better.
  - Partial Drawing is experimental; do not use with wireframe on. Join merge radius = automatic vertex weld distance.
  - Dev: logs, app-review popup, FPS counter.
- PAIN POINTS: Android keyboard experimental; three-finger gestures device-dependent; gesture conflicts silently disable one binding; many debug options exposed to users.

---
## PAGE: Tools
URL: https://nomadsculpt.com/manual/tools  (page complete; ends with Toolbox context menu; pager prev=Interface Menu, next=History)
### UI ELEMENTS / LAYOUT
- Tools picked from the Toolbox on the RIGHT; tool controls on the LEFT toolbar. Tool Settings menu = first icon in the top-right menu bar (many tools have extra settings there). Stroke menu customizes brush behavior, pressure, textures (alphas).
- Left toolbar top: Radius + Intensity sliders (intensity on many tools can exceed 100%), then tool-specific controls. Under intensity: the "Sub" button whose label/function changes per tool (usually the inverse action).
- STICKY BUTTON PATTERN: hold Sub = temporary (momentary); tap = latch on. Same for bottom-of-left-toolbar shortcut buttons: Smooth, Mask, Hide, Gizmo, Color, Alpha.
- Tool-specific contextual TOP TOOLBAR appears in the viewport for Mask, Tube, Lathe, Hide, Quad Remesher: tap title to collapse/expand; arrow at top-right moves it to top or bottom of screen.
- Toolbox color categories: Brush (Clay, Brush, Smooth, Layer, Inflate, Nudge, Stamp, DelLayer); Move (Move, Drag); Mask (Mask, SelMask); Paint (Paint, Smudge); Flatten (Flatten, Planar); Pinch (Crease, Pinch); Selection-based "draw 2D shape then operate" (Trim, Split, Project); Creation (Tube, Lathe, Insert); Transform (Transform, Gizmo); Misc (FaceGroup, Hide, Measure, Select); View. (Quad Remesher is also documented as a tool.)
- Toolbox context menu (right-click or long-press a tool): Save (persist tool changes), Clone (duplicate tool as new shortcut/preset), Last save (revert), Icon (change icon), Reset (defaults). => tools are user-editable presets.

### SELECTION CONTROLS (shared by SelMask, Trim, Split, Project, FaceGroup, Hide)
- Lasso (freehand), Polygon (curves and/or straight lines), Curve (Project only, freehand curve), Path (Project only, points), Line (drag a planar segment; auto-validate on by default; long-press/swipe icon to disable), Rect (drag diagonal; long-press/swipe for auto-validate, force square, "first click is center"), Ellipse (same options, force circle), Flip (invert shape mask or Project direction).
- Auto-validate: op runs as soon as the shape is finished. When off, a green button appears next to the shape; user can orbit/adjust view then press it to execute. (Two-phase "draw, then confirm" pattern.)
- Shape editing (polygon/curve/path): drag a line to make 2 points, drag from its middle to create polygon/curve; tap point to toggle smooth/sharp; drag on a segment to add points; delete a point by dragging it onto a neighbor until it turns red; trash icon at the corner of the polygon/path icon deletes the shape.

### TOOLS (every tool, purpose, Sub action, key settings)
- Clay: builds up material. Sub = remove.
- Brush: standard brush. Sub = remove.
- Move: area under brush sticks to it (elastic grab); selection persists during the stroke (moving back to start = no deformation). Sub = Normal (move along normal). Settings: Radius (Background) = how far off the model silhouette you can start grabbing; Same-side vertex only (ignore back-facing verts).
- Drag: like Move but selection continuously updates; long snake-like shapes esp. with Dynamic Topology. Sub = Normal. Same settings as Move.
- Smooth: averages positions; effectiveness depends on density (dense meshes need more). Sub = Relax (smooth wireframe, keep detail). Settings: Facegroup>Relax (smooth facegroup borders; >100% fast; Auto/Off/On); Vertex>Sticky vertex on border (lock open edges); Vertex>Relax; Vertex>Stable smoothing (less density-dependent, best at high intensity); Painting>Screen Smoothing (topology-independent); Painting>Screen samples. Tip: 300–500% intensity acts like a "mallet".
- Mask: masked verts protected from sculpt & paint. Sub = Unmask. Painted, from shapes, blurred, sharpened; can come from facegroups; drives extract/split/carve. Top toolbar: Clear, Invert, Sharpen, Blur, Blur-> (drag left/right interactive blur), Front (front-facing only), Convert (mask -> facegroup), On tap (facegroup: tap group to mask it), On tap (mask: flood-fill island), Connected (stroke affects only connected topology). Quick gestures while HOLDING the lower-left Mask shortcut (ZBrush-style): tap background = invert; drag background = clear; tap masked = blur; tap unmasked = sharpen. Mask settings (geometry from mask): Preview (none/extract/split, show in X-ray); Thickness Height (+/- cycles outward/inward/centered), Height vs Height+Mask (blurred mask modulates height); Smoothness + Iterations, All/Sharp border/Borders only; Auto Edge-loop (side) or slider; Extract with Closing action None (duplicate polys)/Fill (patch back)/Shell (default, extrude by thickness); Split (both regions, separate closing actions, Sync border to avoid gap); Carve (cut into surface by thickness, "orange peel"). CAVEAT: Extract preview + X-ray can give "Nothing to Extract!" because the new shape has no mask; close mask settings and reselect original.
- Selection Mask (SelMask): mask via selection shapes; Sub = Unmask; same settings as Mask.
- Paint: color + material properties (see Painting). Sub = Erase. Setting: Layer filtering (= alpha lock: on a layer only already-painted areas change).
- Smudge: smudge color/material. Quality slider (lower = faster).
- Flatten: project onto average plane. Sub = Fill (plane from highest point). Lock plane direction / Lock plane origin (both off by default). CAVEAT: without locks, long strokes drift deeper or change angle. Tip: mask to protect high-curvature neighbors.
- Planar: like Flatten with less buildup; cleaner hard surfaces; = Flatten with Lock plane direction on. Slow strokes from planar areas keep plane. Sub = Fill.
- Crease: small cuts. Sub = Invert (raised crease). Pinch factor and Offset factor (offset 1/pinch 0 = deep but jagged).
- Pinch: sharpen edges. Sub = spread.
- Trim: remove mesh chunk using selection shape; fill options. CAVEAT: projects from camera; perspective mode triggers a warning and cuts unevenly; use orthographic. Settings: Stroke painting (fill patch with color), Boolean (quad fill, flat), Legacy (triangulated flat), Fill (curved "soap film"), None; Boolean Detail Shape/Hole, Legacy Detail, Legacy Hole smoothing, Legacy Threshold epsilon, Fill Detail.
- Split: like Trim but keeps the cut part as a new object; same settings applied to both pieces.
- Project: like Trim but doesn't add/remove geometry; moves verts to conform to the shape. Inside a layer, layer slider blends original/projected.
- Layer: raises surface but caps height per stroke (new stroke builds from new height). For a constant cap across strokes, create a Layer (layers system) and use this tool; max height comes from the layer. Sub = grooves (min depth). Settings: Use layer data, Inflate, Relax (Normal).
- Inflate: move verts along own normals. Sub = inverse normals. Relax (Normal).
- Nudge: smear points in stroke direction.
- Stamp: click-drag to raise area shaped by the selected Alpha (= Brush with stroke type Lock + radius). Sub = push in. Lock + radius (fixed height; drag changes width + rotation; skin) vs Lock + intensity (fixed width; drag changes rotation + height; rivets). Best on high-res geometry.
- DelLayer: reset layers locally; needs active layer or does nothing.
- Tube: draw a curve to create a tube; path editable in 3D. Left toolbar: Sync (instanced tubes), Snap (snap onto other objects; else first point snaps and rest drawn at that depth) + Offset; Curve mode (Auto-validate, Closed, Screen = pin path to screen while orbiting [only when auto-validate off], Accuracy); Path mode (click points, green circle validates; B-spline, Closed, Screen). Top toolbar when tube selected: Validate (bake to polygons), Edit, Mirror (adds mirror repeater parent), Snap, Closed, B-spline (vs Catmull-Rom), Cap (both/start/end/none), Hole (pipe), Radius (uniform/start-end/per-point orange handles), Twist (pink handles), Profile (circle/uniform/start-end/per-point), Profile edit (2D/3D editor with presets), Spiral (Twist Angle, Offset, Scale, Angle offset), X Divisions, Constant density (else Y divisions), "..." settings. Curve point delete toggle below toolbar (drag point onto neighbor turns red = delete; toggle off to avoid accidents). Settings: Primitive (UVs, validate), Post subdivision (multires level before validate), Linear subdivision, Division X/Y, Curve (Repeater) conversion. Tip: Divisions 4 + Post subdivision 3 = smooth round tubes (worms, limbs).
- Lathe: revolution surface from drawn profile (vases, glasses). Left: Sync, Fixed (fixed center shown on screen vs center from curve endpoints), Curve/Path modes like Tube. Top: Validate, Edit, Mirror, Snap, Stable (profile parented to center line), Focus (rotate view so profile is flat to camera), Closed, Cap, Hole, B-spline, X Divisions, Constant density, settings. Settings like Tube + Curve (Repeater).
- Insert: place an object on another's surface (3D stamp). Pick primitive on left toolbar, click-drag on surface: click = position, drag = size; then auto-switches to Transform. Instance mode: dragging slides new instances over surface copying size. Any outliner shape can be inserted; Instance or Clone mode. Custom pivot = anchor.
- Transform: move/rotate/scale with 1 or 2 fingers, usually over another surface. Left (5 buttons): Snap, Group, Move, Rotate, Scale. TWO-FINGER GESTURES: drag with first finger to place; keep it down and add second finger; dragging second finger scales; lift second and keep dragging first = back to move; tap second finger (holding first) = toggle move/rotate. Clone workflow: place rock, press clone on left toolbar, move copy, repeat.
- Gizmo: move/rotate/scale objects and pivots. Handles: arrows for X/Y/Z, peach dot free screen move, RGB squares plane move; RGB circles axis rotate, inner sphere free rotate; outer dots axis scale, outer cones plane scale, outer peach circle uniform scale. Concept: NODE (transform matrix: translation/rotation/scale) vs VERTICES (positions + paint). Left: Clone (independent copy), Instance (linked copy; sculpting one changes all), Group/Object/Vertex/Auto (what gizmo affects; Object moves only current object leaving children; respects mask + symmetry), Pin, Align (object vs world), Snap rotation, Snap translation (editable increments), Pivot (move gizmo without object). Pivot menu: Reset (Center/Bottom/Align/Mask-center of unmasked) and On Tap (None/Normal align/First/Medial). Settings: Matrix (Move origin, Bake = freeze transforms, Bake Pivot, Reset), numeric Translation/Rotation/Scale, Uniform scale, display (Compact, size, thickness, opacity, hide on interaction), Tangent roll threshold (0 dial vs 90 yo-yo), Numerical input: single tap on a widget pops exact value entry. WARNING: Gizmo/Translate/Rotate/Scale have their own symmetry checkbox, OFF by default.
- FaceGroup: colored face groups for quick masking, hide/show, organizing without splitting, UV regions, guiding quad remesher, Smooth control. Left: Patch (list patches; delete unused, tap to rename/recolor, + to create), Dot (paint groups; "+ Face Group" = each stroke new group; tap = flood fill), Relax (smooth borders), Shape selector (Lock+Radius, Lasso, Polygon, Rect, Ellipse), Auto-pick (patch where stroke starts is used for whole stroke).
- Hide: hide/isolate parts. Left: Dot, shape selector (Lasso/Polygon/Line/Rect/Ellipse), Show (invert op). Top: Clear, Invert, Facegroup (tap hides group), Mask (hide masked), Delete (delete hidden), Split (hidden part -> new object).
- Measure: drag to measure distance between two points.
- Quad Remesher (Exoside): clean quads with density, edge flow, symmetry. iOS in-app purchase one-time $16 USD; desktop license from Exoside (Nomad-only or cross-license); NOT on Android (use free open-source "Quad Remesh - Instant" in Topology > Misc, very limited). Left: Dot density paint (100% red = 2x, 0% cyan = half, 50% gray default), Smooth density, Curve/Path/Rect/Ellipse guides (tap to delete). Top: <Count> starts remesh, Quads target (a guide not exact), Half, Same, Guides (count / delete all), Density X, Density toggle, Face Group toggle, Relax toggle + slider, Hard Edges, Reproject Vertex, Symmetry (world X; keep model at origin), settings (Adaptive quad count, Adaptive size, Auto-Detect Hard Edges). Recipe: facegroup -> relax facegroups -> decimate with facegroup on -> remesh with Relax disabled.
- Select: shape modes select scene objects; Unselect removes.
- View: navigate without changing scene.

### GESTURES / SHORTCUTS (this page)
- Hold vs tap for sticky buttons (Sub, Smooth, Mask, Hide, Gizmo, Color, Alpha). Long-press/swipe on selection icons for options. Long-press/right-click toolbox tool for context menu. Holding Mask shortcut + tap/drag gestures (above). Transform two-finger scale/rotate gestures. Single tap on gizmo widget = numeric entry.
### DATA STRUCTURES
- Node (transform) vs vertex data; instances (linked) vs clones; repeaters (mirror repeater, curve repeater) as parent nodes; tubes/lathes remain editable procedural primitives until "Validate" bakes to polygons; facegroups; masks (per-vertex, blurred values); layers (sculpt/paint deltas with max height data); multiresolution "post subdivision".
### BEGINNER vs ADVANCED
- Beginner: Clay, Brush, Smooth, Move, Paint, Mask, Sub toggle. Advanced: Mask extract/split/carve, Boolean trim details, tube profiles/twist/spiral, gizmo pivot baking, instance sync, quad remesher guides & density.
### PAIN POINTS / CAVEATS (admitted)
- Perspective camera breaks Trim/Split/Project (warning). "Nothing to Extract!" quirk. Layer tool height per-stroke only. Gizmo symmetry separately off by default. Flatten drift without locks. Crease jagged at high offset. Smooth weak on dense meshes. Quad Remesher paid and missing on Android. Accidental curve-point deletion (hence toggle). Page has typos / copy-paste errors (doc quality).
### BEST PRACTICES
- Use orthographic for selection-based cuts; high smooth intensity as mallet; mask to protect areas when flattening; Stamp on high-res mesh; Tube Div4+PostSub3; quad remesh recipe above; save tool presets via context menu.

---
## PAGE: Files
URL: https://nomadsculpt.com/manual/files  (complete; ends at Render "Export png")
- FEATURES: save/load Nomad projects (.nom), import/export 3D models, render images.
- UI: top of Files menu shows thumbnail of last save; tap thumbnail = mini project browser; double-tap another project = mini menu (Open, Add, Save, Clone, Rename, Delete). Presets: demos + character components (select, select again -> Open / Add to Scene / Clone into projects folder).
- Commands: Save, Save As (browser), Rename, Open, Add to scene (merge project into current scene), Delete (from file system), New (prompts to save if unsaved).
- AUTO SAVE: optional timer POPUP prompting the user to save (Timer pop up interval, Popup timeout). Discard autosave (an existing autosave loads instead of the original; this deletes it). PAIN POINT/RATIONALE admitted: Nomad does NOT save in the background because 3D files are large and background saving would lag sculpting; scenes are compressed before save to avoid out-of-memory, which slows saving.
- IMPORT: Import = new project; Add = merge into current scene. Formats: .nom, glTF (.glb/.gltf), OBJ, STL, PLY, FBX (experimental). Advanced toggle: Keep topology (disable auto-fixes: reordering, duplicate removal, unused verts), Skip textures, Keep gui settings (stored in .nom/glTF), OBJ Split by groups, Color Space Linear/sRGB/Auto (OBJ, PLY, FBX).
- EXPORT formats: NOM, GLTF/GLB, OBJ, USD, PLY, STL, FBX. Support matrix: vertex colors all; vertex PBR NOM/glTF(Nomad yes, others partial)/USD/PLY; quads all except STL (glTF partial for others); layers NOM/glTF/USD/FBX; objects NOM/glTF/OBJ/USD/FBX; facegroups NOM/glTF/OBJ/USD/FBX; hierarchy NOM/glTF/USD/FBX; lights NOM/glTF/USD/FBX; textures NOM/glTF/OBJ/USD (FBX import only); primitives/postprocess only NOM (and glTF when re-read by Nomad).
- Export options: All / Visible / Selected (with object counts), Vertex colors, PBR Paint as secondary vertex color (R=roughness, G=metalness, B=masking), Layers as glTF morph targets (per-layer paint exported but ignored by others), Layer painting, Face Group (may interfere with other software), Normals (Nomad recomputes normals on import anyway), Tangents, Textures (no baking here; baking is in Topology).
- TIPS: Blender glTF import doesn't auto-read metal/rough vertex attributes: Vertex Color node (Col.001) -> Separate XYZ -> X roughness, Y metallic. USD support varies (OSX/iOS don't support vertex color); USD presets for OpenUSD, Apple, Procreate, ZBrush.
- RENDER: image with all lights/materials/post. Preview button beside menu title dims toolbars. Transparent background (no partial transparency), Show interface, Render ratio multiplier, Final size (Custom -> width/height sliders). Dashed overlay shows render region when File menu open (accurate only in landscape). Export png -> OS save/share.
- DATA STRUCTURES: project = scene with objects, hierarchy, layers, facegroups, vertex color + vertex PBR (roughness/metalness) paint, lights, primitives (parametric), postprocess, optional gui settings.
- PAIN POINTS: no background autosave; slow compressed saves; FBX experimental; interop quirks (Blender PBR, USD vertex color); doc typos.
- BEST PRACTICES: save manually often / enable autosave reminder; glTF for richest interop.

---
## PAGE: Scene
URL: https://nomadsculpt.com/manual/scene  (complete; ends with Bottom toolbar)
- PURPOSE: manage objects, lights, cameras, repeaters; tree view hierarchy; create/combine/split objects.
- SHORTCUT BAR (top of Scene menu): Add..., Delete, Lock (unselectable in viewport, still selectable in tree), Join (combine, no geometry change), Separate (split disconnected shells), Boolean..., Clone (independent), Instance (linked: modelling changes apply to all), Un-instance, Sync (instances share child hierarchy).
- TREE VIEW: columns Select toggle, Visible toggle, "..." object menu. GESTURES: tap select icon toggles one; DRAG VERTICALLY down the select column to select many; same on visible column to hide/show many. Long-press an item until it turns yellow, then drag up/down to reorder or onto another item to parent. Multi-selected: dark yellow + one lighter yellow (primary); long-press-drag the lighter one moves all. Selecting parent selects children by default; tapping parent's select icon toggles parent-only vs parent+children. Double-click list item = focus camera on it.
- Object menu: Instance, Clone, Name, Delete, Delete+ (with children), Un-instance, Separate Topology, Separate Face Group, Separate Layers (each layer -> object; blendshape export), Join -> Layers (matching-topology objects become layers on primary; others deleted; layers disabled by default).
- MULTISELECTION: enable "Multiselection" checkbox then tap objects; viewport shortcut = HOLD the Smooth shortcut and tap another mesh; tap again to deselect (only when >1 selected). LIMITS: gizmo ignores mask; X/Y/Z non-uniform scaling removed (multiselect transforms whole meshes only; "might improve later").
- BOOLEAN: Voxel Merge (keeps volume, new even polygons; robust; loses detail at low resolution) vs Boolean (keeps original polygons, stitches; cleaner/sharper; needs WATERTIGHT meshes; fall back to Voxel Merge if it fails). OPERATION CHOSEN BY VISIBILITY: Union = both visible; Subtract = one invisible (invisible subtracted from visible); Intersect = both invisible. (Implicit / non-obvious UX.) Controls: Voxel Merge button (on single object = retopo to even polys), Resolution (checkerboard preview overlay of poly size), Build multiresolution (e.g. res 400 with 3 levels ≈ 296k polys + 74k/18k/4k lower levels), Keep sharp edges, Boolean button (Manifold library by Emmett Lalish).
- ADD MENU: primitives, groups, cameras, repeaters, lights. Primitives are parametric until "Validate" bakes them to editable mesh (irreversible). Settings: On gizmo (place at selection/gizmo vs scene center), Select gizmo (auto-switch to gizmo after creation), Advanced placement (selected object / world origin / gizmo), UVs (more memory; matters ~10M+ polys).
- PRIMITIVES: Box (X/Y/Z divisions), Sphere (subdivided box with "Project on sphere" forced), Cylinder (optional hole), Torus, Cone, Icosahedron, UV-sphere (poles bad for sculpting; OK at low division then Overall Subdivision; good for eyes with pole at pupil), Plane (only open primitive), Tube, Lathe, Triplanar, Shadow Catcher, Head (with layer blending male/female). Default launch mesh = subdivided box without Project on sphere (not perfectly round).
- PRIMITIVE TOOLBAR (after creation): Validate, Edit (primitive parameter gizmo e.g. width, hole radius), Mirror (adds mirror repeater above), "..." menu; extras Project, Cap, Hole, Radius, Disk (plane square/circle). Small toolbar below switches primitive gizmo vs transform gizmo. Tap toolbar title to dock top/bottom; corner arrow collapses.
- TRIPLANAR: shaped with Mask tool; mask on 3 planes fills a voxel grid polygonized by voxel remesher; each plane has its own symmetry; double-tap a plane to focus camera on it (not after gizmo rotation). WARNING: resizing degrades mask painting quality; cannot lock painting to one plane (Connected Topology helps).
- Primitive parameters: UVs, Validate, Max faces (cap to avoid crashing device), Post subdivision (multires smooth levels; box div 2 + post 4 = rounded box), Linear subdivision (sharpness of corners), Topology divisions (linked sliders; unlink button for X/Y/Z), Geometry size/radius.
- GROUP (empty parent for organizing/collapsing/transforming many), Add view (camera).
- REPEATERS (nodes that instance their children; nestable; multiple children): Array (Fit inside toggle, Count X/Y/Z, Offset X/Y/Z, Size X/Y/Z), Curve (Edit points, Snap, Align, Count, Closed, Radius per point, Twist per point, B-spline), Radial (Radial X/Y/Z axis + count; move child to change radius), Mirror (gizmo for center; X/Y/Z plane). Validate (any repeater): Join children / Keep instances / Un-instances. TIP: repeaters auto-pivot children; insert a Group between repeater and child to move child freely.
- LIGHTS: Directional, Spot (cone width/softness), Point.
- ADVANCED: Focus on item (double-click), Sync visibility (eye affects all selected), Instance: Show (color capsule marking instances), viewport icon size/opacity, Hierarchy lines.
- BOTTOM TOOLBAR (scene menu): toggle viewport display of Groups, Lights, Cameras, Repeaters, Hierarchy lines.
- DATA STRUCTURES: scene graph tree of nodes (mesh objects, groups, cameras, lights, repeaters); instances share mesh; primitives parametric until validated; layers per object; booleans via visibility state.
- PAIN POINTS: boolean needs watertight; multiselection gizmo limits; triplanar resize degradation; repeater pivot surprise; validate irreversible; broken anchor link ("Simple Merging").

---
## PAGE: Topology
URL: https://nomadsculpt.com/manual/topology  (main content complete; ends at thin "Primitive" section; "Vertex extrapolation" heading has no body; booleans are on Scene page, not here)
- Polygon-based, triangles + quads. Check topology via Wireframe or disabling Smooth Shading (Settings). Sections: Multiresolution, Voxel Remesher, Dynamic Topology, Misc, Primitive. Polygon stats at top (verts/tris/quads for object and scene; tap = per-object list).
- MULTIRESOLUTION: smooth subdivision + multiple levels; workflow: drop to low level, big edit, return up; high-res detail reprojected automatically. WARNING: topology-altering tools destroy other levels: Voxel Remesher, Dynamic Topology, Trim, Split (Nomad warns first). Controls: multires slider (one vertical bar per level, circle = current), Reverse (create lower level; works only if mesh came from subdivision), Subdivide (x4 polys per press; Linear subdivision checkbox = no smoothing), Delete lower, Delete higher, Sharp border (per level; keeps facegroup borders sharp; icon on slider), Keep triangles, Lock (LV0) (protect base mesh from big upper-level edits). TIP: semi-sharp edges = Linear subdivision or Sharp border on first 2 levels then off.
- VOXEL REMESHER: uniform polygon size, free-form sculpting without managing topology; block out low-res, hit Remesh whenever stretched. Self-intersections resolved; open meshes holes auto-filled. Controls: Remesh, Resolution (checkerboard preview while dragging), Build multiresolution (levels below), Keep sharp edges (may distort). TIP: Build multires can make "loops" causing pimples; enable Stable smoothing in Smooth tool.
- DYNTOPO: adaptive local add/remove during strokes; TRIANGLES only (ignore messy wireframe, remesh later). Controls: Enabled (then a DynTopo icon appears under radius/intensity sliders for per-tool toggling), Detail, Detail based on Screen (on-screen size; 100%+ fine, 1% coarse) / Radius (brush radius sets detail; slider multiplies) / Constant; TIP: in Radius mode move detail slider with one finger while changing radius with another to see link; Prefer Speed vs Quality (refine before sculpt until converged); Use pressure on radius; Use stroke falloff; Method Uniformisation (add+remove) / Subdivision (add only) / Decimation (remove only), per brush or global; Protect masked area; Vertex extrapolation (undocumented); Remesh global via DynTopo (voxel recommended for full remesh; DynTopo advantage = respects mask so you control density).
- MISC (gear icon beside each section title holds extra options):
  - Decimation: keeps detail, triangles; for 3D print; not for continued sculpting (uneven tris). Masked areas not decimated. Toggle icons: Preserve Painting, Uniform Faces, Preserve Geometry/Facegroup/UV Borders. Target default 50% (toggle percent vs exact count). Quadremesh prep recipe: facegroup -> relax -> decimate preserving facegroups -> quadremesh with relax off.
  - UV Unwrap UVAtlas (many islands, low distortion; eye icon preview; Unwrap; Delete UVs; gear: Face Group cuts, Max Stretch, Island spacing). WARNING: slow; keep < 100k vertices. Nomad paints without UVs (vertex color); UVs needed to bake to textures for Procreate etc.
  - UV Unwrap BFF (fewer cuts, more distortion; Face Group, Cone count, Seamless patches).
  - Bake -> Texture: project other visible objects into selected object's UVs. Workflow: detailed painted mesh -> clone -> decimate (Preserve painting 0) -> unwrap -> bake. Solo mode to limit sources. Vertex colors moved to a new disabled layer after bake. Modes From itself (highest multires -> lowest) / From high-res (N). Resolution square 512/1024/4096. Gear: Normal, Roughness, Metalness, Color, Emissive, Opacity maps; Backup; Cage radius; Ray offset (default 5%).
  - Reproject to Vertex (inverse; textures -> vertex). From itself (needs UVs + active textures); texture-painting workaround: low-poly UV mesh -> load textures -> subdivide -> reproject -> paint -> bake from itself. From high-res (N) (e.g. bandages onto character). Options Vertices, Roughness, Metalness, Color, Opacity, Opacity->Mask, Mask, Layers, Face Group; Relax Smooth/Relax/Auto; Iterations; Cage radius; Ray bias; Ray offset 5%.
  - Quad Remesh Instant (Instant Meshes; Target quads; Crease angle; Max fill hole). Quad Remesher tool better on iOS/desktop.
  - Holes: Close holes (naive; can't weld two borders); Detail (checkerboard; or use existing points -> long thin tris); Fill non-manifold; Face Group Auto/Off/On. Voxel remesher closes holes automatically.
  - Force Manifold: Clean (edges shared by >2 faces), small-face threshold.
  - Triplanar convert: big detail loss; Force cubic; Resolution.
- PRIMITIVE section: same params as primitive toolbar.
- DATA STRUCTURES: multires level stack (with LV0 lock, per-level sharp border), voxel remesh (uniform, watertight), dyntopo triangles, UVs, baked textures, vertex colors/PBR, facegroups as guides.
- BEGINNER vs ADVANCED: beginner = voxel remesh blockout + subdivide; advanced = multires reverse, dyntopo modes, baking/reprojection, quad remesh prep.
- PAIN POINTS: destructive topology ops wipe multires; dyntopo triangles messy; slow UV; decimation not sculptable; several remeshers with overlapping roles (voxel, dyntopo remesh, instant quads, Quad Remesher, voxel merge) = conceptual load.

---
## PAGE: Material
URL: https://nomadsculpt.com/manual/material  (complete; ends with Uniform scale)
- FEATURES: per-object material, render props, textures. Appearance props: Material type, Color, Roughness, Metalness, Opacity, Reflectance, Emissive/unlit. Color/Roughness/Metalness/Opacity are PAINTABLE (vertex paint). Copy/paste buttons at top of menu transfer materials between objects. Realtime renderer favors speed over accuracy.
- MATERIAL TYPES: Opaque (default; painted color/rough/metal/opacity); Subsurface (skin/wax/jade; best in PBR with >=1 directional/spot light and dim env; Depth, Translucency); Blending (single opacity slider; WARNING flicker/popping on complex or intersecting shapes); Additive (always brighter; fire/light rays; opacity >1 + Bloom threshold = glow; order-independent transparency, fewer artifacts); Refraction (glass; self/multi-layer refraction limited; blur from painted roughness; new objects default ~25% roughness; "paint glossy" button sets rough 0/metal 0; Surface glossiness + Interior roughness override because only one roughness channel); Dithering (random pixel discard transparency); Shadow Catcher (invisible but receives shadows, for compositing).
- CONTROLS: Always unlit (painted color only; with Additive black = transparent), Opacity, Reflectance (default ~4% F0; raise for eye highlights), Inverse culling (flip normals for inside-out models; with Two sided off can hide nearest interior wall), Smooth Shading (Auto = global), Two sided (Auto), Coloured backface (Auto), Casts shadows (Auto=On; transparent objects cast dithered shadows; disable for big floors), Receive shadows (Auto=On), Wireframe (Auto). PATTERN: per-object "Auto" inherits global setting.
- TEXTURES: need UVs; supplement vertex paint. Slots Color, Normal, Roughness, Metalness, Opacity, Emissive. Click empty slot = selector; assigned slot = texture panel (Open, None, Opacity from alpha, chain/link icon to share settings among slots, Projection Auto/UV/Triplanar). Triplanar ("six projectors"): Method Local/World, Hardness (default 90%; 100% sharp, 0% wide blend), Uniform checkbox (else X/Y/Z hardness). Parameter: Filtering Auto/Nearest/Linear/Mipmap; Tiling-X/Y None/Repeat/Mirror. Transform (UV-space): reset, link to color texture, Translation, Rotation, Scale (larger = smaller texture), Uniform scale.
- DATA: per-vertex color/roughness/metalness/opacity + optional UV textures multiplied.
- PAIN POINTS: Blending flicker; refraction limits; single roughness channel.

---
## PAGE: Shading
URL: https://nomadsculpt.com/manual/shading  (complete; ends with Instance ID Randomise id)
- RENDER MODES: Lit (PBR) (paint uses metalness/roughness), Matcap (cheaper GPU/CPU while sculpting), Unlit (color only), Object Id (random flat color per object, for selection in 2D paint apps; also shown in Scene tree), Instance Id (instances share a color).
- DISPLAY TOGGLES: Face Group overlay (most primitives auto-create facegroups; some tools auto-filter by facegroup when visible), Show paint (vertex color/rough/metal; multiplied with textures), Show mask (disabling also disables mask but keeps it), Use Hide (CAVEAT: only works when NOT in Hide tool), Use textures.
- LIGHTING: lighting fully separate from material. Lights only in PBR mode. LIMIT 4 lights (performance); glTF with >4 loads all but slower. Fake many lights via unlit/emissive objects + GI.
- LIGHT TYPES: Directional (sun; orientation only; shadows; tip attach to camera for rim light), Environment (auto-rotates to HDR's brightest area; separate intensity and angle; HDR sharp light alone gives too-soft shadows), Spot (cone; shadows), Point (table says screen-space shadows only; section says no shadows — doc contradiction).
- SHADOWS: Normal bias (acne / peter-panning); quality depends on object size relative to scene; disable cast shadow on big planes.
- LIGHTS PANEL: Lights checkbox (all direct lights), Add light (max 4; opens lister + adds LIGHT TOOLBAR at top of viewport), lister row: name/brightness, eye, pencil rename, trash, copy, "..." editor; Icons toggle. Light toolbar: Show, Type (tap cycles, long-press menu), Intensity (>1 allowed), Color swatch (incl. Kelvin), Shadow, Size, "...". Extra: Clone, Recenter, Delete, Type, Attachment world/camera (directional), Angle (directional/env), Softness (spot; blue dot in viewport adjusts interactively), Cone angle (spot; orange dot handle; up to 170), Shadow, Shadow map vs screenspace, Contact (auto-pick most important light vs user), Tolerance.
- ENVIRONMENT: built-in indoor/outdoor HDRs; tap image to browse; Import... custom .hdr/.exr latlong (Polyhaven 1k recommended); Exposure, Rotation, Attached to camera.
- MATCAP: lighting+material in one sphere image; ignores rough/metal; paint color multiplied (black matcap can't be brightened). Tap sphere to browse; custom matcap = any cropped sphere image (nidorx library). Use global Matcap (off = per-object matcap; eyeball image for eyes). GESTURE: rotate matcap by THREE-FINGER drag left/right in viewport.
- Unlit (flat/cartoon or color check). Object ID / Instance ID with Randomise id.
- PAIN POINTS: 4-light limit; doc contradiction on point shadows; shadow quality scene-scale dependent; Hide toggle quirk.

---
## PAGE: Post process
URL: https://nomadsculpt.com/manual/postprocess  (complete; ends with Dithering)
- GENERAL: global checkbox disables all post (settings kept). Performance varies a lot by device. For PBR enable AO, Reflection, Tone Mapping. BEST PRACTICE: disable post while sculpting; focus on form.
- QUALITY: Max frame sampling (frames accumulated; GI may need hundreds; viewport refines progressively while idle then stops; same value used for Files > Render export png), Resolution multiplier (x0.5 fast, x1 device, >1 supersample), Max samples ("Full resolution" more impactful), Denoiser OIDN (only with Full Resolution; runs after sampling; CPU heavy).
- PRESET BROWSER: tap preset image; clone to create; tap image, tap again in browser, "save".
- EFFECTS: Reflection SSR (on-screen objects only; PBR only), Global Illumination SSGI (Strength), Ambient Occlusion SSAO (Strength, Size, Curvature bias, Color; most visible under environment light), Depth of Field (TAP THE MODEL to set focus; Far blur, Near blur), Bloom (Intensity, Radius, Threshold, Color), Tone Mapping (None/Neutral/AgX/ACES; Exposure, Saturation, Contrast), Color Grading (curves: Main/R/G/B), Curvature (Factor, Bump color default white, Cavity default black), Chromatic Aberration, Vignette (Size, Hardness), Grain, Sharpness, Pixel Art (pixel size; Allow frame sampling if many black pixels), Scanline (Factor, Spacing), Dithering (reduces banding; keep on except when exporting data/depth).
- PAIN POINTS: screen-space limits (SSR only reflects on-screen), device-dependent performance, doc image captions swapped (DOF).

---
## PAGE: Background
URL: https://nomadsculpt.com/manual/background  (complete; ends with camera-linking tip + video)
- BACKGROUND TYPE: Environment (shading env map; Blur, Exposure), Color (flat), Gradient (top-to-bottom ramp; Factor = midpoint).
- REFERENCE IMAGE: user image as reference; position/scale (e.g. to a screen corner). "Transform" button = interactive placement with TWO-FINGER pan/scale/rotate; result reflected in sliders. Sliders: Overlay (0% behind sculpt, 100% in front), Opacity, Position X/Y, Rotation, Scale.
- WORKFLOW TIP: reference image transform is saved with a camera created in the Camera menu; turning the reference off and re-entering that camera re-activates it; different cameras can hold different references (front/side reference setup).
- GAPS: no formats, defaults, mouse equivalents documented; typos.

---
## PAGE: Camera
URL: https://nomadsculpt.com/manual/camera  (complete; ends with Double tap on background)
- USES: precise sculpting views, photo framing, first-person scene navigation, orthographic for isometric/industrial renders.
- TOUCH GESTURES (exact): Rotate = ONE-finger drag on background (one finger on model = sculpt stroke). Rotate when no background visible = put TWO fingers down then lift ONE (continue with the remaining finger). Double tap on model = focus/pivot on tapped point. Double tap on background = focus on selected mesh. Pan = move TWO fingers. Zoom = pinch. Roll = rotate TWO fingers (Trackball mode only).
- DESKTOP: rotate = tip/mouse drag in empty space; pan = Alt/Opt + drag; zoom = Alt/Opt + drag then release Alt/Opt (ZBrush-like). Wacom: tip=left, lower rocker=middle, upper rocker=right; upper rocker+hover = rotate, lower rocker+hover = pan.
- VIEWS: Add View saves a named camera; tap name to restore; stores projection settings AND linked reference image (front/left/back references). Per-view: Visibility (hidden cameras skipped by prev/next buttons), Name select, Image thumbnail, Update View (overwrite), Edit Name, Delete. Icons toggle (selected camera icon always visible).
- PROJECTION: FOV/focal length (low FOV recommended for sculpting proportions); Orthographic (~FOV 0).
- FIRST PERSON: pivot moves onto the camera; one-finger background drag rotates in place (environments).
- ROTATION TYPE: Turntable (default, 2 DOF, "more intuitive"); Trackball (allows roll by two-finger rotate); desktop alternate trackball mode.
- ORTHOGRAPHIC SNAP: hold SHIFT while rotating = snap to nearest axis view + switch to ortho. Clicking a nav/view-cube face also snaps + ortho.
- Reset View (front + fit scene). Snap View (nearest axis view; again = flip 180° to opposite). Speed multipliers for rotation, translation, zoom (for huge/tiny sculpts).
- PIVOT: shown as small PINK DOT while rotating. Default updates: double tap model; double tap background (mesh center); two-finger pan/zoom/roll (pivot moves to center between fingers). "Update pivot..." options: when camera starts moving, allow air pivot (unexplained), when double tapping, during sculpt stroke. Double tap on object (requires Focus enabled). Double tap on background: pivot to Selection / Scene / toggle. Pink dot can be hidden in Settings once familiar. Docs: understanding pivot is important to avoid "getting lost".
- PAIN POINTS: getting lost with pivot (docs admit); roll only in trackball; Shift-snap needs keyboard; undocumented "air pivot".

---
## PAGE: Stroke
URL: https://nomadsculpt.com/manual/stroke  (complete; ends with Pressure smoothing)
- Five sub-menus: Stroke, Alpha, Falloff, Filter, Pressure. Options not used by current tool are disabled/hidden.
- STROKE: Share radius (off by default = per-tool radius). Size mode Screen (pixels, constant on zoom) vs Constant (3D units). Stroke types: Dot (standard), Roll (alpha follows direction, stitches), Lock + radius (fixed height, drag = scale+rotation), Lock + intensity (fixed radius, drag = height+rotation). Move/Drag modes: Drag (default for Drag tool; continuous; snakes with DynTopo), Grab (default for Move; selection fixed at stroke start), Lock + radius (drag) (radius set by drag distance; intensity shapes falloff; rubbery blocking). Adjust spacing intensity (compensate <50% spacing), Stroke spacing (<100% continuous, >100% gaps for stitches/zippers), Lazy rope stabilizer (stroke trails pointer), Stroke smoothing (average positions; lags then catches up), Snap radius (new stroke starts at previous stroke end). Silhouette (project through entire model; direction default Closest). Randomize intensity/translation/rotation/scale. STROKE OFFSET: constant offset so finger doesn't cover the stroke on small screens (touch occlusion fix).
- ALPHA: grayscale modulation (black none, white full). Tap alpha image to change; tap material preview for material preset; presets saveable; textures embeddable in tool. CAVEAT: textures never resized -> large ones hurt performance. Invert pixels (not for built-ins), Scaling (0.7 fits square in circle, 1 fills/clips), Scaling-Y, Rotation (follow stroke + offset; lock to screen), Tiling (single/repeat/mirror), Mid value (0.5 = gray neutral, push+pull).
- FALLOFF: one intensity curve = brush tip cross-section; bottom preview shows single stamp with alpha. Modes Preset (tap curve; Sub reverses), Catmull-Rom (tap add point, drag move, tap toggles sharp/smooth, drag onto neighbor deletes), B-spline (smoother). Buttons Maximize, Reset, Symmetry. Influence: Sphere (3D), Circle (2D plane-projected), Cylinder (used by Silhouette). Silhouette.
- FILTER: Accumulate stroke (Clay on, Brush off), Front-facing vertex only (may artifact for sculpt), Allow dynamic topology (per tool), Connected topology (only linked verts; move intersecting parts). Protect Area: Auto protects hidden/masked/facegroup only when visible in Shading menu; All (global vs per-tool), Hide, Mask, Facegroup (restrict to first touched group). Keep Sharp Edges (exclude points with deviating normals; clean flatten/paint without spill). Area Sampling (plane from % of radius; 100% all points, 0% nearest; Normal radius and Position radius link/unlink). Depth Masking (Height offset, Top area, Bottom area; recipes: paint cavities -100%; paint bumps ~+90%; first click sets reference depth).
- PRESSURE (within Stroke): Use global settings (on by default), Pressure-Radius curve (linear default; presets like "out-pow3"; Catmull-Rom/B-spline; disable for constant), Pressure-Intensity, Pressure smoothing.
- BEGINNER vs ADVANCED: beginner = radius/intensity/falloff presets/alpha; advanced = area sampling, depth masking, protect area, silhouette influence, mid value.
- PAIN POINTS: huge option count; per-tool vs shared settings confusion; Protect "Auto" depends on Shading toggles (hidden coupling).

---
## PAGE: Pressure
URL: https://nomadsculpt.com/manual/pressure  (exists, short; not linked in sidebar)
- Pressure menu customizes tablet pencil behavior (Apple Pencil, Samsung S Pen). Default: pressure affects Radius and Intensity; falloff of the pressure impact is customizable (details on Stroke page).
- Option "Allow unrecognized pressure": some Android devices report a fixed arbitrary pressure for finger touches, which is frustrating (esp. low values); disable it to sculpt with a finger. Defaults: iOS enabled, Android disabled.
- PAIN POINT: Android finger pressure reporting inconsistent.

---
## PAGE: Painting
URL: https://nomadsculpt.com/manual/painting  (complete; ends with Global material)
- CONCEPT: PBR VERTEX painting (color, roughness, metalness [+ opacity]) stored per vertex, no UVs needed; Nomad handles millions of verts so paint detail matches sculpt detail. Textures only from import or by baking (needs UVs; auto-UV has limited quality control). Workflow: sculpt -> UV unwrap -> bake vertex paint to textures -> export to Procreate -> texture -> back to Nomad for render.
- STROKE PAINTING: "Paint" checkbox on any sculpt tool = sculpt and paint simultaneously (not shown for Paint/Smudge/Mask). Separate Paint intensity slider; Alpha/Falloff/Randomize checkboxes decide if those affect painting.
- MATERIAL SECTION: 3D material preview (drag to rotate), stroke preview, Preview mode button (None / Material on model / Triplanar), Eyedropper (samples all properties from scene objects).
- MATERIAL PRESETS: tap 3D preview to open preset menu; clone to create own; Embed Textures and Alpha toggles (explanation promised but missing).
- PBR SLIDERS: Color (eyedropper also from reference images), Roughness, Metalness (usually 0 or 100%), Opacity (not strict PBR; distinct from Refraction). Presets paint three channels at once (opacity often excluded). Per property: texture slot square, brush icon = flood-fill property over object, enable checkbox (paint only selected channels). WARNING: Matcap mode shows color only.
- TIPS: with textures, use Stamp or a non-dot stroke (dot smears); enable Smooth Shading for metallic paint on low-poly.
- PAINT ALL: fill whole object (standard or triplanar); respects disabled channels; option buttons: skip masked, skip hidden, apply tool paint factor, skip unpainted areas of layer, triplanar indicator/settings (with persistent preview checkbox).
- GLOBAL MATERIAL: selected material shared across tools (roughness, metalness, color).
- GAPS: color picker UI not described; Embed textures explanation missing; typos.

---
## PAGE: Symmetry
URL: https://nomadsculpt.com/manual/symmetry  (complete; ends with Show options)
- MODES: Mirror (X left/right, Y top/bottom, Z back/front, combinations), Radial (around X/Y/Z with count; starfish), Origin mode World (world origin) vs Local (object center), Restore (force symmetrical).
- UI: "Sym" button on the LEFT quick panel toggles symmetry; small "L/W" label shows Local/World. LONG-PRESS or SWIPE toward screen center on it opens the Symmetry menu (same long-press/swipe-for-options pattern).
- GLOBAL STATE: symmetry shared across tools, EXCEPT transform tools (Move/Translate, Rotate, Scale, Gizmo) which each keep their own state. Stroke symmetry only; mirror whole objects with Scene repeaters.
- Planes: 1, 2 or 3 at once; radial axis + count, combinable with planes; total repeats capped at 150.
- Method: Local (mirror moves with object/gizmo) vs World (fixed; object slides through). Plane/radial indicators overlaid on object.
- MIRRORING (restore): Direction << / >> chosen relative to current VIEWPORT (e.g. << copies screen-right to screen-left). Mask: masking destination protects it; masking source excludes it. Hide: hidden source areas not mirrored. Mirror (requires matching topology; moves verts) vs Split & Mirror (cut, copy, mirror, weld seam; DESTRUCTIVE: deletes multires; for very asymmetric topology). Flip Object (swap sides, like scale -1 X).
- Reset/Edit: editing plane location/orientation possible but DISCOURAGED; Gizmo (Edit) intentionally grayed out as deterrent; World center / Orientation / Object center reset buttons; behavior depends on Local/World.
- Show line / Show plane overlays (take effect only after closing the menu).
- PAIN POINTS: local/world confusion (docs: check space if results unexpected); destructive Split & Mirror; separate symmetry for transform tools surprises users.

---
## PAGE: Layers
URL: https://nomadsculpt.com/manual/layers  (complete; ends with Advanced)
- CONCEPT: non-destructive edits preserving base mesh. Paint layers (Color, Roughness, Metalness, Opacity; order-dependent; blend modes). Sculpt layers (like blendshapes/shape keys/morph targets; purely ADDITIVE so order irrelevant for sculpt). Partial erase via DelLayer tool. Layers can generate masks.
- TIP: topology changes do NOT discard layers (unlike most sculpt apps): Voxel Remesher (layer quality affected), Multiresolution, Trim/Split. Blendshape round-trip via Scene object menu (Separate Layers / Join -> Layers).
- LAYER STACK UI: "Add layer"; each row = name, strength/factor slider, option buttons: Visible, Blend Mode (4 icons for Color/Roughness/Metalness/Opacity), Edit Name, Delete, Duplicate, Merge Down (into layer below or base mesh), More. Reorder: PRESS-AND-HOLD layer name then drag.
- MORE...: Channel factors (sculpt, color, roughness, metalness, opacity; multiply main factor). Offset = sculpt strength, unclamped +/- (bump->cavity, smile->frown; >1 for extreme; negative baked into empty layers). Clone symmetrical layer + DelLayer to split left/right shapes. WARNING: single shared opacity channel for color/metal/rough; merging non-full channel intensities can change result (future per-channel alpha "might" come). Mask button per channel = selection from layer. Preview (extraction preview; with X-ray only extracted solid). Extract (closing action None / Fill (not on flat surfaces) / Shell / Layer difference), Thickness (− / + / ±), Smoothness, Edge loop (side) Auto or Division.
- ADVANCED: Keep top layers details (upper-layer details float over big lower changes), UI: Expand list (default shows only visibility + opacity), Sync transform (Auto = visible layers only).
- GAPS: no layer limit/memory cost documented; no dyntopo mention; no shortcuts.

---
## PAGE: Settings
URL: https://nomadsculpt.com/manual/settings  (complete; "Primitive/Repeaters" heading empty)
- QUICK DISPLAY TOGGLES: Smooth Shading (faceted reveals topology; suggested faceted for sculpting, smooth for rendering; off = small perf gain), Outline (selection outline; Darken Unselected performs much better), Grid, Two Sided (color backfaces to reveal topology issues; off = small perf gain), Wireframe (costs performance), Snap Cube, Show Painting (default paint white, non-metal, 25% roughness), Use Hide (disabled while in hide tool), Show Mask (off keeps mask inactive; trick: set mask color white to hide yet keep active; disabled during mask tool), Mask -> Opaque, Highlight (selected objects flash hot pink 500 ms), Stats (memory, scene verts, selection verts).
- Darken Unselected Objects; Mask color (mid gray multiplied).
- CURSOR: Show circle while sculpting, Show small dot (brush center / pivot change), Show rope stabilizer line.
- INDICATOR (for tutorials/screen capture): Finger / Stylus / Mouse icons, color, size/icon/circle.
- WIREFRAME: Target (unselected/selected/all), Hide, Multires Level 0 only (levels shown progressively lighter), Color.
- GRID: color, Snap (curve tools snap to grid). TWO SIDED: Backface color. OUTLINE: color/thickness. HIGHLIGHT: color, duration.
- SNAP CUBE: shape Cube / Sphere / Gnomon; Restrict alignment (drag locks to horizontal/vertical); Size; Flip 180 (tap cube center when snapped); Position corner. Tapping sides -> ortho views.
- STATS position. NUMERICAL INPUT: Gizmo input (tap gizmo widget for numbers).
- MULTIRESOLUTION: Max vertices count (default 10 million; blocks subdivision that would likely crash); Low resolution threshold (lower res displayed during camera move; LOD for navigation).
- Reset to default.
- PERFORMANCE PATTERN: many display features traded vs perf on mobile; LOD while orbiting; hard vertex cap.

---
## PAGE: History
URL: https://nomadsculpt.com/manual/history  (complete; Memory stats section has no detail)
- Nearly all edits undoable; limited number, adjustable.
- GESTURES: undo = 2-finger tap; redo = 3-finger tap. (Bottom toolbar Undo/Redo/History buttons per Getting Started; long-press 2/3 fingers repeats per Interface.)
- HISTORY PANEL: list of steps with number, operation name, memory used per step (tap to jump implied by stack display).
- SETTINGS: History limit (MB; oldest dropped when exceeded), Maximum undoable (count). Restore camera (camera viewpoint saved per op; undo/redo restores view). Include actions: Lights (gizmo moves still recorded), Matcaps & HDRIs, PostProcess (exclude from history).
- Memory stats breakdown (unspecified).
- DATA: memory-budgeted undo stack with per-op camera snapshot.
- GAPS: no defaults, no location of panel described.

---
## PAGE: FAQ
URL: https://nomadsculpt.com/manual/faq  (complete)
- PLATFORM: projects in Nomad folder "projects" (iOS Files app; Android Android/data/com.stephaneginier.nomad/files/, inaccessible directly on Android 10/11 -> third-party file explorer). Beta: Win/macOS beta on homepage; iOS TestFlight via Discord #beta-ios; Web Demo has latest features. Free trial on Android only (weak old devices; paid Android apps uncommon); free version has save disabled.
- BEST TABLET: "an iPad" (newest affordable); else newest Samsung; test other Android. Newer iPads: Quad Remesher plugin, barrel-roll pencil support (twist in certain tools), M-series speed. Perf: 2023 iPad Pro ~5M polys responsive, final render ~5 s; 2015 iPad Pro ~1.2M with some lag, ~20 s render. Most sculpts < 500k polys. Android: Galaxy Tab S9 "an order of magnitude slower" than iPad Air. Files usually ≤100 MB.
- PURCHASES: per app store (iOS<->iOS, Play<->Play; no cross-platform; no license server/subscription). Restore via About menu (Nomad icon, TOP LEFT) "restore purchase"; Huawei w/o Google services must rebuy on AppGallery. Translations AI-based, public GitHub repo.
- FEATURES: Gizmo not moving -> Pin option enabled in left toolbar (common confusion). Animation: no (layer timeline not planned); rigging/skinning maybe later (hard with sculpt tools); rigging "planned"; workaround parent shapes + pivots for posable sculpts. Low-poly modeling: no (out of scope). UV/texturing: indirect workflows (vertex PBR paint, high vertex counts, textures as stamps, import textured objects, UV unwrap, reproject textures->vertices, bake vertices->textures incl. normals, multires high->low, OBJ export includes textures for Procreate). Turntable video: not planned; use iOS screen recording (steps given). Favorite feature as top-level button: yes via Interface menu bottom toolbar + floating toolbars. Roadmap: no firm plan; bug fixes prioritized. >4 lights: no (realtime engine limit); fake with emissive + GI. ZBrush tools import: no (proprietary); extract alphas.
- COLORS DON'T MATCH / NO WHITE IN RENDER (PBR darkens): non-PBR fixes Unlit mode or bright white matcap; PBR fixes neutral outdoor/studio env, boost env exposure or lights, Post Process tone mapping + exposure, emissive + GI, unlit material.
- CRASHES: crash on save/remesh = out of RAM (not storage) -> reduce polys. Crash on load -> close apps, new project, device with more memory, Squash Layers; desktop demo can import/export. Crash on startup -> rename settings.json (stops last project autoload), move recent files out of projects/matcaps/environments; Nomad temporarily moves a file into can_be_deleted/ during load and skips it after a crash.
- PAIN POINTS ADMITTED: no animation/rigging, no low-poly modeling, 4-light cap, no cross-store licensing, Android performance, RAM crashes, color mismatch under PBR, license sync issues "outside developer's control".

---
## PAGE: Tips
URL: https://nomadsculpt.com/manual/tips  (complete; ends with Daylight lighting)
- HOW TO START A MODEL (no single best): (1) Sphere + multires (Move, Clay, Crease; low levels for big forms) — drawback polygons run out where needed (fingers) and pile up elsewhere; suits spherical forms. (2) Dyntopo — messy triangles; enable smooth shading + disable wireframe for clay feel; large/smooth brushes remove polys; then clone -> Quad Remesher -> reproject details onto high subdivision. (3) Voxel remesh — even mostly-quad; iterate head -> stretch neck -> remesh -> add body -> remesh... (4) Multiple objects blockout (spheres/cylinders/cubes, parenting, gizmo, pivots) then voxel remesh/boolean to one surface; tip: sausage sphere, set pivot "bottom", clone/translate/rotate to lay out body. (5) Tubes for tails/limbs/fingers/eyebrows + profile edits, validate, sculpt or remesh. (6) Other apps (Blender, Valence low-poly) then import. (7) Built-in presets: Project menu "Preset..." (top right), Blender Foundation head/body presets; tap, tap again, add. (8) Online models (Polyhaven, Sketchfab, TurboSquid). (9) No rules: combine (tubes -> dyntopo -> downloaded foot -> quad remesh -> multires).
- FACEGROUPS: organize/select faces by color (not vertex color; "map countries" analogy); zones (eye sockets, nose, lips) and hard-surface panels. Dot with auto-pick enabled: each drag = new group, tap = flood-fill new group; auto-pick disabled ("sub" mode): extend group under cursor. Mask tool + facegroup button: tap group to mask. Hide tool + facegroup: tap to hide. Use instead of splitting objects. UV Atlas uses facegroup borders as seams. Quad Remesher edge flow. Smooth >100% inside group keeps border. Relax borders before quad remesh.
- MOBILE LIMITATIONS: no active cooling -> PBR/materials/post can overheat & drain battery -> use matcap + lower render multiplier. Limited memory: ~1M polys easy on capable devices; M2 iPad Pro 8M comfortable; only most detailed need >4M; simple objects past 500K/1M/4M = too many polys. OS less forgiving: may kill app on slow save/load/task switch; keep files small (37M polys reported but not recommended).
- SMALL SCREENS: FOUR-FINGER TAP toggles the entire UI; THREE-FINGER DRAG up/down changes brush radius; adjust UI scale; transparent non-blurred menus to see sculpt underneath; finger sculpting -> stroke offset option to shift brush center away from finger; more in Interface menu.
- INFLATE DEFORMER EMULATION (no deformers yet): Inflate brush, stroke method Lock + Radius, radius larger than sculpt, click-drag -> whole shape inflates evenly; intensity controls amount; mask to protect.
- VOXEL PIMPLES: voxel remesh + build multires + strong smooth -> lumps; fix with Stable smoothing, or new topology (primitive/quad remesh/external) then Topology > Misc > Reproject.
- DAYLIGHT LIGHTING: default PBR looks washed out/flat; tone mapping; reduce/rotate env light; add strong direct light; subsurface for characters with spotlight behind ears; GI + AO realism, Curvature + Sharpen detail, camera effects CA/DOF/Grain/Bloom/Vignette.
- PAIN POINTS: no deformers; device thermal/memory/OS limits; default renders flat.

---
## FORUM: forum.nomadsculpt.com (pain points, requests, complaints)
URLs: https://forum.nomadsculpt.com (categories), /top?period=all, /c/feature-request/7 (+ ?page=1, /l/top?period=all), /c/bug-report/5 (+ /l/top?period=all), /c/tips-tutorials/10, plus threads listed in crawl log.
- CATEGORY SIZES (topics): Feature Request 2141, Artwork 1567, Tips/Tutorials/Help 1376, Bug Report 1340, Lounge 920. Feature requests are the largest category.
- ALL-TIME TOP (mostly Artwork); notable non-art: "Nomad Change Log" (110,903 views), "Free alpha brushes" (73,777), "Nomad Sculpt Brush Tools free downloads v1.82" (64,065; community brush presets are hugely popular), "ZBrush Brushes + Tips! (How to make Nomad feel like ZBrush)" (11,324), "Free Base Mesh ... posable" (20,692), "ZRemesher with Nomad (iOS)?" (6,076), "Low poly modeling" (12,878).
- TOP FEATURE REQUESTS (all time, replies/views): Low poly modeling 70/12878; Linux version 27/3135; Grouping - folders for objects 11/2913; 3Dconnexion SpaceMouse 56/2100; Nomad for PC? 16/45277 (+ "Nomad on PC in 2024" 25/17784, desktop/web-assembly 25/15955, Mac version 26/4853 — since shipped); Manual retopology tool 57/7730; Retopology Flow Tool 13/3332; Tube Tool customisation 16/1698; Tube armature 14/2693; Folders for brushes 10/768; Posing and poly modeling 18/4501; Rulers and unit measurements 9/2666 (+ "Meter (mm, cm, m) in Grid"); Pose Brush 12/2313; Mask blur slider 26/3998; Time lapse recording 16/8309; "Half a year since last update" 21/2879; Kitbashing / Insert Mesh Brush 19/2936; Chisel brush; Object Alignment Tool 21/4093; Procreate export / UV issue 54/10253; Rig (move body parts without gizmo or mask) 10/3834; Fast way for adjusting Dynamic topology value 11/1055; Hardsurface tools; Render turntable 10/3589 (+ "Turntable Video Export"); UV mapping (two threads ~6.2k views each); Surface noise like ZBrush; Retopology; FBX export; Wireframe by individual mesh; IK bones for posing; Projection painting; Ray tracing 24/2475; Selmask gradient; "Community collection of tiny but badly missed features" 27/1936; Boolean operation 11/9116; Bevel edge; Infinite ground plane; MIDI controller sliders; Texture wrapping for mask/stamp; Poly editor; "Enter numbers for scaling and sizing" 15/8572; Fly-through mode; Screen space refraction; "Curve repeater and tube UX ... AKA TUBE NEEDS TO DIE" 32/1764; Moving objects together in hierarchy 18/2290. Recent: IMM brushes, Dynamic Subdivision (ZBrush term), ZModeler-like, plugin API, smudge mask, batch delete projects, put user alphas first, add invert option back to alphas, reset intensity to 100%, allow keybinding of menus, bindings for floating windows under cursor, blank space for customization, assets reordering, pivot aligned to view, gizmo rotate snap 22.5°.
- "BASIC DEFORMERS" request (t/24072): Bend, Twist, Taper, Skew, Lattice wanted; users round-trip to Blender. (Docs Tips page confirms "Nomad has no deformers yet"; changelog 2.9 mentions improved Lattice.)
- "TINY BUT BADLY MISSED" (t/4754): hold-to-move/tap-to-stamp grab brush; stylus-radius multi-object selection; select by material; object freeze; auto-mask unpainted; mask grow/shrink; mask border -> 2D polygon for tube/trim/split; lock zoom/perspective (rotation only); multiple background reference layers with Z and camera lock; DRAG LEFT/RIGHT ON VOXEL BUTTON TO CHANGE DENSITY with preview; adjustable grid size, ortho-view grids, corner/line snapping for selection/curve tools; long-press to reopen last shape; save shapes; Shift for 45° constraint; separate "execute & close" vs "execute & stay"; versioned "+/-" filenames. DEV (stephomi): bugs top priority (often fixed same day); UI/UX feature requests "largely ignored unless many users ask"; focuses on underlying problem; shape tool rework "someday"; holding clone icon = continuous cloning (hidden feature).
- PALM REJECTION (t/1515): resting palm triggers accidental undo (repeated), selections, camera moves, tool switches; worse than Procreate/Forger per some. Workarounds: lower palm rejection threshold in pressure menu, Auto-hide toolbox, disable quick gestures, remove palm-triggered tools, drawing glove. DEV: palm rejection is iOS system function; real bug was stylus counted in multi-touch gestures (finger + stylus double tap = undo) — fixed Dec 2021 (stylus+finger ignored for undo).
- LOW POLY (t/1415): want box modeling, crease/edge-stop for hard plates/armor; pain: subdividing low-poly plates smooths unevenly, CAD (Onshape) OBJ imports split into unwelded parts. Workarounds: Onshape/Shapr3D/3ds Max base then import; triplanar with smoothness 0 then remesh. DEV: traditional low-poly "not planned for now"; hard-surface helpers (curve/tube, polish) wanted.
- ZBRUSH SWITCHERS (t/23039): community ports of DamStandard, ClayBuildup, Orb brushes, pinch; tuned for PC tablets (iPad Pencil needs intensity changes); SmoothAlt via rebinding Shift; desktop draggable custom shortcut window for ZBrush-style layout; "ZBrush was hardcoded in my brain" (muscle memory barrier); DEV: platforms converge except Web/Android lack Quad Remesher, Web/Windows lack OpenUSD.
- TUBE / CURVE UX (t/11461 "TUBE NEEDS TO DIE"): two overlapping curve systems (Tube vs Curve repeater) with no clear rationale; editing shared paths means rebuilding copies; lathe profiles 2D only; off-center twist skews; tube menu missing inside hierarchy/multiselect; Insert tool collides with curve point editing. Proposals: unify into curve nodes + profile primitives, linked curves, override indicators (press-and-hold). DEV: repeaters' strength is nesting/repeating hierarchies; profiles maybe like a material selector; wants more feedback. Community caution: fuller UI could confuse; current curve UI intuitive.
- SAVE / DATA LOSS (t/4507, t/208, t/24571, also "Unsaved project disappeared", "Lost my work renaming file"): Save As didn't prompt for a name (must tap "+"); selecting another project in Save As OVERWRITES it; rename confusion; repeated confirmations cause reflexive tapping; iOS backgrounding kills autosave ("Auto save has some limitation"; "no magic way" to save 3D as fast as 2D); stray images converted into empty projects (fixed); dev added periodic save reminder rather than save-on-quit; failed loads moved to import_failed. 2025 report: week of work lost after overwrite via Save As (unreproduced). DEV calls first case a "UX misunderstanding".
- SYMMETRY (t/3815): off-axis symmetry after moving parts/not aligned; fix: World mode + reset world center, gizmo reset transform/rotation 0, per-object reset symmetry, use "show plane". DEV: Local mirroring should be used "exceptionally"; admitted adding Local symmetry "may have been a mistake".
- DOCS/DISCOVERABILITY (t/246): users want glossary/cheat sheet; in-app "(i)" popup descriptions not in manual.
- TOP BUG REPORTS (all time): crash exporting on iPadOS 2.10 (41 replies); "Import picture reference" 20/8130; Paint All only default color; iPad screen dimming 18/6833; Android pen issues 59/4661; "How to invert mask?" 10/10424 (discoverability); Wacom MovinkPad pen; "Project disappeared! Argh!" 24/3462; loading references from Photos; crashing after update; Palm detection 27/4173; Off axis symmetry 15/5036; "I totally lost mesh visibility"; alphas import problems; Confused about Save/Save as; voxel merge + smooth; "Matcap 360° rotatable?" 26/2537; iPadOS 27 beta memory drop; antialiasing halo; iPad Pro hover; exporting to Blender; "Can't adjust radius of Move brush"; objects won't change material; tube tool not drawing; non-manifold holes; "Brush stroke spacing changes when lagging" 23/1660; hollow print issues; Layer brush not working; rotation snap; stamps import; Simple Merge; outline/deselect; boolean broken (beta); shadow flicker; S8 Ultra crash after 1.5M polys; gizmo world size; streaky shadows; ChromeOS; Procreate rough/metal loss; voxel merge intersection; slow after masking & transforming; S-Pen button. Recent: system-wide lag, PC crash, "So many bugs", nudge off, VSync re-enabling, Insert instance can't press Snap, Blender Link topology/UV, file size too large, saving directory choice on PC, grid+perspective display bug, missing turntable/camera controls in corner, textures lost on Join.
- MANUAL LAG vs APP (from Change Log t/139, v2.9 Dec 20 2025): app has features the manual pages do not document: Elastic & Polish brushes; Arrange tool (line/circle/sphere distribution); VDM brushes (capture/generate/repair); Text primitive with Google Fonts; Link (live sync with Blender, ZBrush GoZ, other Nomad devices); stroke trail; hold stroke to snap to a shape; tiled symmetry & symmetry from pivot; Move tool for curves, curve IK/bevel/warp, spiral presets (rope, braid, ribbon, strands); Surface repeater (scatter on faces/edges); Lattice with point selection, soft radius, rigidity; mask grow/shrink/border/cavity; face groups from UVs/normals/parts/mask; Measure shortest-path + cross-section; new Autoremesher & UV unwrap; voxel remesh edge length + thicken thin parts; extract bevel/gap/wall profile; multi-object trim/split/project; DynTopo keeps UVs; 25 layer blend modes; texture curves; material picker; volumetric fog; Poly Haven integration; radial/sky gradients; DOF aperture; project history saved with REPLAY; export with embedded assets/history; customizable UI colors/glass/accents; reorderable top menus; HSB/RGB sliders; snap to grid/points; reorderable cameras/lights; gamepad, SpaceMouse on Mac, trackpad gestures; Apple Pencil precise lift and tap-while-hovering. Forum also mentions 2.10, 2.12 versions and "Preserve volume".

---
## CRAWL LOG
Tool: WebFetch (summarizing model; declines verbatim reproduction, so notes are dense paraphrase). WebSearch used to discover forum thread URLs. curl not used.
Manual pages fetched successfully (each reported complete by fetcher; single fetch each, no offset needed as content returned full-page structured notes):
- https://nomadsculpt.com/manual/ (Overview)
- https://nomadsculpt.com/manual/gettingstarted
- https://nomadsculpt.com/manual/interface
- https://nomadsculpt.com/manual/tools
- https://nomadsculpt.com/manual/files
- https://nomadsculpt.com/manual/scene
- https://nomadsculpt.com/manual/topology
- https://nomadsculpt.com/manual/material
- https://nomadsculpt.com/manual/shading
- https://nomadsculpt.com/manual/postprocess
- https://nomadsculpt.com/manual/background
- https://nomadsculpt.com/manual/camera
- https://nomadsculpt.com/manual/stroke
- https://nomadsculpt.com/manual/pressure (exists but is NOT in sidebar; very short)
- https://nomadsculpt.com/manual/painting
- https://nomadsculpt.com/manual/symmetry
- https://nomadsculpt.com/manual/layers
- https://nomadsculpt.com/manual/settings
- https://nomadsculpt.com/manual/history
- https://nomadsculpt.com/manual/faq
- https://nomadsculpt.com/manual/tips
Child pages: none discovered beyond the sidebar list (manual is flat; sections are in-page anchors). WebSearch site:nomadsculpt.com manual found no extra manual pages. Translated manuals exist but were not fetched.
Forum fetched:
- https://forum.nomadsculpt.com (categories)
- https://forum.nomadsculpt.com/top?period=all
- https://forum.nomadsculpt.com/c/feature-request/7 , ?page=1 , /l/top?period=all
- https://forum.nomadsculpt.com/c/bug-report/5 , /l/top?period=all
- https://forum.nomadsculpt.com/c/tips-tutorials/10
- https://forum.nomadsculpt.com/t/basic-deformers-feature-request/24072
- https://forum.nomadsculpt.com/t/community-collection-of-tiny-but-badly-missed-features/4754
- https://forum.nomadsculpt.com/t/palm-detection/1515
- https://forum.nomadsculpt.com/t/low-poly-modeling/1415
- https://forum.nomadsculpt.com/t/zbrush-brushes-tips-how-to-make-nomad-feel-like-zbrush/23039 (and /18, which returned only a truncated excerpt)
- https://forum.nomadsculpt.com/t/curve-repeater-and-tube-ux-integration-ideas-aka-tube-needs-to-die/11461
- https://forum.nomadsculpt.com/t/confused-about-save-and-save-as/4507
- https://forum.nomadsculpt.com/t/project-disappeared-argh/208
- https://forum.nomadsculpt.com/t/oh-my-god-this-is-terrible/24571
- https://forum.nomadsculpt.com/t/off-axis-symmetry-no-way-to-fix-it/3815
- https://forum.nomadsculpt.com/t/glossary-or-cheat-sheet-for-nomad/246
- https://forum.nomadsculpt.com/t/nomad-change-log/139/83
Failures / limits: no fetch failed. Limits: (1) WebFetch returns model-summarized content, not raw text, so tiny details may be omitted and nothing is verbatim; (2) images/videos in manual not viewable (icon appearance unknown); (3) only page 1 of forum top lists read; individual threads only first page; (4) manual appears to lag app v2.9+ features (see above) — those features documented only via changelog summary, not manual.
