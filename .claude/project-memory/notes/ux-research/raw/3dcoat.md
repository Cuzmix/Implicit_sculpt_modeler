# 3DCoat Official Documentation Crawl (UX research)
Source: 3dcoat.com/documentation (Pilgway). Crawled 2026-10-25 via WebFetch (pages summarised by a fetch model; only page-stated facts recorded). Fields omitted where page said nothing.

---
## 1. 3DCoat Documentation (landing hub)
URL: https://3dcoat.com/documentation/
- FEATURES/STRUCTURE: Hub. Manual chapters: Introduction, Getting started, Interface (incl. Navigation & Applinks), Brush Components, Node System, GPU Texturing, Workspace Rooms, Scripting & Core API, Q&A (FAQ), Licensing (pilgway.com). "Library" of topic guides: Getting Started, Painting, Sculpt, Modeling, Retopology, UV, Smart Materials, Nodes, Photogrammetry, Render, Print, Learning, Training Tutorials. Blog posts (2024-2026: "2026 Key Features and Improvements", "Texturing with nodes", "Shader Nodes vs Material Nodes", UDIMs, cavity/curvature maps, normal map types, texture painting pipeline).
- Products: 3DCoat, 3DCoatTextura (paint-only), 3DCoatPrint (free, print), PBRLibrary.
- UI ELEMENTS: Built-in "AI chat (beta)" on every doc page (pilgway.com/chat) with disclaimer answers may be wrong. ~30 languages.
- Full manual sitemap captured from sidebar (see CRAWL LOG). Sculpt subtree: Sculpt Layer, Sculpt Tree, Sculpt Brush options, Top Bar, Brush engine, Geometry menu, Right-Click Menu, Shader, Voxel mode (Pure Voxel Sculpting, Density and Resolution, Clay Engine, Voxel Tools, Surface tools on Voxels, Voxel Adjust, Volumetric Painting, Voxel Objects Tools), Surface mode (Surface tools, Surface custom tools, Surface Layer, Surface adjust tools, Surface Painting, Multi Level Resolution + Multires tools/adjust/commands), Sculpt curves (Spline Curves, Splines model creation), Vector Displacement, Transform tools (Transform, Instancer, Move, Pose, Fit, Reproject, Surface Array), Primitives (Hollow Box), Live Booleans, Commands for Sculpt room, Import/Export. Rooms: Paint, Tweak, UV, Retopology, Sculpt, Modeling, Kitbash, 3DPrint, Photogrammetry, Nurbs, Nodes, Render, Factures, Simplest.

---
## 2. Interface (Interface, Navigation & Applinks)
URL: https://3dcoat.com/documentation/manual/interface-and-navigation/
- FEATURES: Each Room = "mini-application" with tools/menus for one stage of the creative process. Top menus always visible: File, Edit, View, Curves, Windows, Scripts, Addons, Capture, Help; other menus change per room. Menu sets switchable from a drop-down/tab list in the status bar (also in Preferences).
- UI ELEMENTS (13 numbered zones): 1 Main Menu (always available; used to change rooms); 2 room-specific menus; 3 Windows panel (pick panels per room); 4 Status Line (Pick and Snap, tool options); 5 Activity Bar (hover to expand palettes without changing layout; can sit top-right or vertical on viewport); 6 Tool type indicator; 7 Tool Bar Options (contextual top bar); 8 Stroke modes (click-to-release, spline, polygon drawing); 9 Camera and Navigation; 10 Tool Options panel; 11 Left Tool Panel (tools of current room); 12 Statistics line (vertex/face/triangle counts, selection); 13 Layers (sculpt, paint, Curves layers).
- TOOLS: Top Bar toggles switch mouse vs tablet (pressure) response for Depth, Smoothing, Opacity, Glossiness (Paint); Sculpt has more toggles. Stroke Panel = 5 icons changing stylus/mouse behaviour (key E). Retopo: numeric input for transform gizmos (also Voxel), Auto-Select mode, Free and Normal Extrude. Moveable Stamp draw mode. Sticky Keys. Asset panels via Activity Bar, with search.
- NAVIGATION PATTERNS (stylus): tap+drag empty space = rotate; hold RMB (pen side button) + drag in empty space = pan; hold RMB hover empty + drag = zoom; hover model + hold RMB drag left/right = brush size, up/down = depth.
- CUSTOMISATION: Windows menu > "Store this page layout" / "Restore this page layout" / "Store Workspace" / "Restore Workspace". Edit > Preferences > General: "Store Window State" to persist layout across sessions.
- PAIN POINTS: panels may reset to defaults after workspace reset/config issue; dual-monitor NOT currently supported (workaround: stretch UI across monitors); newer Wacom tablets have much higher pressure levels -> must adjust pressure sensitivity in Preferences; tutorial series targets v4, does not cover the new brush engine.
- Children: File, Edit (Bake Geometry Info, Calculate Occlusion/Curvature, Light Baking Tool, Preferences, Cavity & Curvature maps), View, Symmetry, Textures, Calculate, Layers, Freeze, Hide, Bake, Curves (editor, RMB properties, Fill with mesh layer, scale of imported curves), Windows (Windows Panels, Controls), Scripts, Addons, Capture, Help, Room Customization, Modify or Create new Room.

---
## 3. Getting started
URL: https://3dcoat.com/documentation/manual/getting-started/
- FEATURES: 3DCoat = real-time 3D creation app split into Rooms (each a connected "mini-application"). "Relatively easy to learn at the basic level".
- DATA STRUCTURES (mesh types, each native to one room): Paint Object (imported into Paint); Sculpt Object (imported into/created in Sculpt); Retopo/Modeling Object (imported into Retopo/Modeling, or produced by Auto-Retopo). UV room only works on Paint objects (companion to Paint/Tweak).
- ROOMS: Paint/Tweak (texture painting + mesh modification, poses, morph targets); Photogrammetry (Reality Capture, models from video); Retopology; UV; Sculpt (organic + mechanical detail); Modeling (low-poly, then subdivide into Sculpt mesh for detail); Factures (cover surfaces with detailed materials e.g. grass/rock/sand); Simplest (basic shapes, easy tools); Kitbash (attachable linkable parts like building blocks); Render (turntables, fly-throughs); Create new Room (user-built rooms); Node Room (non-destructive GPU node texturing).
- CUSTOMISATION/ACCESSIBILITY: enlarge UI via Edit > Preferences > Theme font scaling "Extra Large"; else OS display scaling. Asset panel icon size via three-dots menu at panel top-right.
- BEGINNER: index page, points to Typical workflows video series.

---
## 4. Hotkeys
URL: https://3dcoat.com/documentation/manual/navigation/hotkeys/
- CUSTOMISATION: Hover any tool/button/menu item, press END, then press desired key/combination (nearly every item can have a hotkey). Tooltips (short/long hints) end with "Use 'END' to define hotkey". If key taken: choose reassign (replace) or STACK. Keys can be scoped to current room or specific tool. Backspace deletes a hotkey. Hotkey to an action in one tool also triggers the same-named action in other tools (e.g. "Act as vox hide"). Save/Load via Edit > Save/Load Hotkeys. Hotkeys Manager (Help > Hotkeys Manager Panel) loads/shows *.hotkeys file; click to redefine, Backspace/Del remove, search icon.
- STACKED KEYS: one key -> several tools; repeated presses cycle (e.g. press brush key twice returns to previous brush).
- STICKY KEYS: single action per key only; HOLD key = temporary tool (e.g. Freeze), release returns to previous tool; tap again returns to previous tool. Caveat: sticky keys don't work with stacked keys.
- SPACE QUICK ACCESS: Space opens all tools; numbers 1-4... at top; Space+number selects; panel rearrangeable.
- HOTKEYS (exact):
  - File: New Ctrl+N; Open Ctrl+O; Save Ctrl+S; Save as Ctrl+Alt+S; Save incrementally Ctrl+Shift+S; Import model Ctrl+Shift+O; Import image plane Ctrl+Shift+M.
  - Edit: Undo Ctrl+Z; Redo Ctrl+Y; Edit all layers in external editor Ctrl+P; Edit projection externally Ctrl+Alt+P; Offset tool Ctrl+Shift+F.
  - View: Ortho NUM5; relief only 1; unshaded 2; only specular 3; wireframe 4; shaded 5; low-poly 6; low shaded 7; 2D grid Ctrl+'.
  - Popups: Color picker B; Pick pivot point F; Layer list L; Tools panel Space; Depth channel D; Color channel C; Specular/Glossiness channel R; List of pens T; Materials M; Types of drawing (stroke modes) E; Quick panel ~; Symmetry S.
  - Layers: New Ctrl+Shift+N; Delete Ctrl+Shift+Delete; Erase unfrozen Delete; Fill unfrozen Ins; Fill by mask Ctrl+Ins; Duplicate Ctrl+Shift+D; Merge visible Ctrl+Shift+E; Merge down Ctrl+E.
  - Freeze (mask): Toggle freeze view Alt+F; Unfreeze all Ctrl+D; Invert Ctrl+Shift+I; Show/hide freeze Ctrl+F; Smooth Ctrl+NUM*; Expand Ctrl+NUM+; Contract Ctrl+NUM-; Freeze border Ctrl+NUM/.
  - General: Copy/Cut/Paste Ctrl+C/X/V; New pen from site Ctrl+Shift+C; Pick color V; Pick layer H.
  - Hide: Unhide all Ctrl+X (doc lists, conflicts with Cut); Expand hidden NUM+; Contract hidden NUM-.
  - Splines: add point LMB; draw extruded curve Enter; pressed-in variant Ctrl+Enter; delete all points Esc; delete last Backspace; move symmetry plane Tab+LMB drag.
  - Smoothing +/-: Shift+"+"/Shift+Wheel Up, Shift+"-"/Shift+Wheel Down.
  - Camera: NumPad 1 Bottom, 2 Front, 4 Left, 5 persp/ortho, 6 Right, 7 Top, 8 Back; Ctrl+Up add camera shortcut; Ctrl+Down delete; Ctrl+Left/Right previous/next.
  - Sliders: Opacity O/P; Angle 9/0; Radius [ / ]; Degree (depth) - / +; Smooth degree Shift+- / Shift++; Glossiness opacity ; / '; Glossiness degree < / >; Swap colors X. Texture transparency O/P.
- Mouse notation: LMB, RMB, MMB, WHEEL.
- PAIN POINTS: duplicate/conflicting entries (Ctrl+X both Cut and Unhide all; specular vs glossiness R).

---
## 5. Camera and Navigation
URL: https://3dcoat.com/documentation/manual/navigation/camera-and-navigation/
- NAVIGATION (default "3DCoat" scheme): LMB drag on empty space = orbit (when no E-panel stroke mode active); Alt+LMB = orbit anywhere (required when E-panel tools/some voxel tools active); RMB drag empty = zoom; Alt+RMB = zoom; MMB drag = pan; Shift = snap rotation to regular intervals. ALT+LMB/RMB/MMB allow navigating without moving cursor off model.
- PRESETS: Camera dropdown (arrow top-right) > Custom scheme: 3DCoat, 3DCoat arrows, Maya, ZBrush style (default 3DCoat). "Customize navigation" panel = full remap of navigation commands; conventions of common 3D apps integrated.
- PIVOT: F = pick pivot for rotation; "Rotate Around..." commands (world center, pick point). Numpad * over a face = Look Along Normal. View Orient command (suggest hotkey O). Nav bar icon: switch to ortho and snap to nearest view.
- CAMERA SHORTCUTS: store camera pos/rotation PLUS 2D grid, stamp, template transform (repeatable results; used for frame-sequence rendering). Ctrl+Up/Down/Left/Right.
- UI: Camera menu: background image (default starfield); reference images per X/Y/Z axis with position/scale/rotation/opacity popup, "Edit image placement" gives a Transform widget on each image plane.
- NAV ZONES: interactive dead zones; disable via Camera > Customize Navigation: turn off LMB Navigation "Is In Nav Zone", uncheck Display Nav Zone, Navi Zone Width = 0.
- PREFS: near clip = Preferences > Viewport > Near plane modulator. Modifier+scroll wheel can drive brush size/orientation.
- CUSTOMISATION: Edit > Customize User Interface to disable unwanted UI items.
- Page has no tablet/touch notes. FAQ: if ref image controls vanish, click to hide cross gizmo.

---
## 6. Customize Navigation as Blender
URL: https://3dcoat.com/documentation/manual/navigation/camera-and-navigation/customize-navigation-as-blender/
- WORKFLOW: open navigation settings menu > "Customize Navigation". Top section of dialog controls mouse-wheel behaviour. Example screenshots "Blender settings by Michael" etc. (community, Blender Artists thread "3D Coat as a companion to Blender").
- PAIN POINT: page gives settings only as screenshots; no textual key mapping. Shows emulation is achieved by manual remap rather than a one-click Blender preset.

---
## 7. Navigation Panel
URL: https://3dcoat.com/documentation/manual/navigation/navigation-panel/
- UI: top-right of viewport; auto-hides, pops up on hover. Widgets: Ambient lighting contrast (0 = physically correct; higher = easier for sculpting; double-click toggles max contrast+locked environment for sculpting vs min contrast+unlocked for render/paint); Primary light intensity & Light angle (LMB hold+move); Blur Environment; Roll CCW/CW fixed angle (RMB sets angle); Trackball Rotation toggle (vertical-axis turntable vs free rotation); Rotate/Move/Zoom camera drag widgets (pan = Alt+LMB drag on widget); Field of view drag (RMB reset; 38 approx human vision; 10-15 headshots, 30-40 full body; low FOV approximates ortho); Frame the view (fit visible / current object in Sculpt); Focus on the brush (surface under brush, brush radius sets distance); Reset camera; persp/ortho toggle; Grid; Snap cursor to grid projection (gizmos/primitives snap; recommended in ortho); Switch to ortho and snap; Show/Hide Axis; Full Screen; Environment map popup; Show/Hide Reference Images; Viewport Projector (projects texture through scene for reference only, optional backface culling/fade); Favorites Custom Menu (room-dependent, hotkeyable).
- NAVIGATION (pen tablet): tap+drag empty = rotate; RMB+drag L/R empty = pan; hover empty, RMB drag = zoom; hover model RMB drag L/R = brush size, U/D = depth.
- BEST PRACTICES: Camera > Background > Lock environment for visible sculpt detail; use PBR shaders not MatCaps (only PBR guarantees exact baking/good color painting); View > Greyscale panorama to judge colors.
- Env maps: spherical HDRI .exr/.hdr (page inconsistent), "+" in thumbnail column.

---
## 8. Quick Access Menu (Spacebar Menu)
URL: https://3dcoat.com/documentation/manual/navigation/space-bar-menu/
- FEATURES: context-sensitive per room (Paint, Sculpt, Retopo, UV...). Opens with brushes by default; has search box (type to filter any tool). Paint room: radial wheel layout. Sculpt/VoxTree: voxel tools. Render room: generally empty.
- HOTKEYS: Space opens. Upper section = hotkey slots 1-9 filled by dragging tools from lower portion.
- CUSTOMISATION: Edit > Menu -> edits menu.cpp in Documents/3DCoat-2022/UserPrefs/Rooms/CustomRooms/. Older menu style restorable: Edit > Preferences > Themes.
- PAIN POINTS: cursor lands in search box so number keys type into search, 1-9 hotkeys don't fire; right-click in menu releases focus to re-enable them. Space's numeric-input use only while a tool active and only certain transforms.
- BEST PRACTICES: hide main toolbar and use spacebar menu as main tool caller to maximise viewport. Ctrl+F (Popups > Search in UI) searches any UI item in current room.

---
## 9. Sculpt (room overview)
URL: https://3dcoat.com/documentation/manual/workspaces-rooms/sculpt/
- FEATURES: organic + mechanical modelling; two working modes Voxels and Surfaces (polygons), switchable at any point. Voxel brushes compared to clay/wax/wood/stone; precision tools for mechanical forms. "Makes full use of graphic tablets".
- DATA STRUCTURES: Voxel = memory/CPU intensive volume. Surface = triangle mesh with dynamic subdivision built into brushes, stores Sculpt Layers; voxel edits can be projected onto a Surface copy. "Voxel volumes does not support Layers" -> convert to Surface first.
- WORKFLOWS: start voxels at lowest resolution capturing overall form -> add detail with Resample / "Res+" (duplicate layer first to keep stages) -> Surface for fine detail/performance/memory -> Retopo (Auto or Manual). Surface Re-Skin: Enter re-meshes latest revisions into consistent triangulated mesh replacing stretched polys. Layers -> PolyGroups -> Paint room for displacement/bump/color.
- BRUSHES: alpha = grayscale intensity map controlling shape; brush = alpha (Brush panel) + settings (Brush Options). RMB + horizontal/vertical drag in viewport adjusts on the fly; top-bar sliders mirror these. Strokes "E" panel: spline/polygon drawing tools editable while working. Smart Materials, Stencils, Strips, Models, Splines panels modify strokes in context.
- TOP BAR (Sculpt, changes per tool): Conform Retopo Mesh (keeps retopo mesh synced; only Pose/Transform/Move changes considered); On Plane (constrain strokes to plane, defined with RMB; Plane Opt.; Wheel / Ctrl+Wheel moves plane fore/back); Remove stretching (Surface; remesh under brush = dynamic tessellation for standard brushes); Invert Tool (= holding CTRL); Steady Stroke (trajectory smoothing); Mouse&Pen icon (pressure-dependent radius); Padlock radius (lock on-screen radius so zooming changes world size); Edit Curve (pressure->radius curve); Radius [ / ]; Setup Tapering Parameters (replace/modulate pressure with curve; taper length in multiples of radius); Focal Shift (alpha crispness); Falloff; Depth padlock (lock = absolute depth independent of radius; standard = proportional); Depth - / +; Smoothing (strength of SHIFT smoothing; pressure-dependable). Click around slider label to collapse/expand.
- ACTIVITY BAR: Photoshop-like hover-to-open: Shapes, Brushes, Panoramas, Brush Parameters, Strips, Stencils, Smart Materials, Sculpt models, 3D Splines, Joints, Presets.
- UI: Right-click on voxel layer = quick voxel functions incl. Autoretopo, Booleans; full set in Geometry menu. Statistics panel bottom-left. Autopick ON by default (sculpt a new object without selecting its layer). Export polygon + raw voxel formats (CAD/3D print).
- HOTKEYS: Enter (Re-Skin/remesh), CTRL (invert), SHIFT (smooth), [ ] radius, - + depth, Ctrl+Wheel plane.
- ADVANCED (videos): Re-Skin, Surface->Retopo, Pose/3D Stroke mode, Ghost Mode, separate VoxTree transforms.
- BEST PRACTICES: lock environment; PBR shaders not MatCap.

---
## 10. Sculpt Tree (VoxTree)
URL: https://3dcoat.com/documentation/manual/workspaces-rooms/sculpt/sculpt-tree/
- DATA STRUCTURE: hierarchy of "layers" (objects/volumes) in Sculpt room, like Maya/Max Outliner. Root = scene, not editable. + on a row adds child; + at root adds unparented. Drag to reorder, reparent (drop onto a layer's + sign), or into trash. One "layer" can hold multiple objects.
- ROW CONTROLS: Minus collapse; Eyeball visibility; Ghost Mode (half-transparent, unpickable, protected from editing); V/S icon toggles volume (voxel) vs surface mode PER LAYER; + child; double-click name to rename; resolution tag [2x]/[4x] prefix when resolution changed; Downgrade/Restore doesn't cache immediately (prevents accidents).
- BOTTOM ICONS: New layer (root); Duplicate; Shader properties (ball); "Create space with identical density/transform" (for copy tool; down-res loses detail); Symmetry copy (any axis, symmetry on); Symmetrical copy (most recently painted side -> other side); Increase resolution (grid); Clear voxels (X); Trash; Group layers into subtree.
- WORKFLOWS (videos): quick layer selection in viewport, isolate (hide others), restore hidden; split parts of a layer into child layers; multi-select layers (delete, Global Space options).
- CAVEATS: symmetry required for symmetrical copy; reducing resolution loses detail.

---
## 11. Sculpt Layer
URL: https://3dcoat.com/documentation/manual/workspaces-rooms/sculpt/sculpt-layer/
- DATA STRUCTURE: Sculpt layers = non-destructive detail stacks (texture, damage, wrinkles/pores, asymmetry) over a base; "only for surface mode object"; original object unaltered. Layers panel (bottom, Photoshop-like, multi-purpose) stores paint AND sculpt/depth information. Sculpt Tree vs Layers panel are distinct (tree = objects/Outliner; layers = Photoshop-like).
- CAVEATS: Surface->Voxel switch normally nullifies sculpt layer info (video shows workaround). "Never use layer 0" (internal). To see in Paint room enable View > "Show voxels in the painting room". Page states it is not a tutorial/best practice.
- BEST PRACTICE: make a simple model to test layers. Adjustment layers usable for terrain.

---
## 12. Voxel mode
URL: https://3dcoat.com/documentation/manual/workspaces-rooms/sculpt/voxel-mode/
- FEATURES: voxels = "volumetric pixels"; sculpting = volume building/filling, "without any topological constraints", "absolute feeling of freedom".
- DATA: default density 1 voxel/mm; printing defaults 5 voxels/mm. Voxels have no surface normals -> viewport faceting (fix by subdividing). Cannot handle single-sided/open meshes: add thickness before voxelizing. Surface->Voxel opens Voxel Conversion Dialog; can nullify sculpt layers.
- VOXEL vs SURFACE: voxels for organic + block-out; surface for hard-surface (crisp edges easier) and has viewport smoothing. Hard-surface in voxels possible with high resolution + avoid auto-smoothing ops.
- CLAY ENGINE: new voxel brush engine, "Smooth brush mode": surface-like brushes native to voxels; accurate clay, flatten, smudge, pinch; faster, more flexible. Caveat: subject to change, old voxel-engine presets may not be preserved.
- TOOL GROUPS: Voxel Tools, Surface Tools on Voxels, Adjust, Paint (2022+, same tools as Paint room), Pose (incl. Pose group), Objects, Curves, Commands, Density/Resolution, Volumetric painting, primitives.
- PAIN POINTS: rare voxel artifacts (cleanup video); faceting; open meshes.
- No hotkey for voxel/surface switching given (it's the V/S icon in tree).

---
## 13. Surface mode
URL: https://3dcoat.com/documentation/manual/workspaces-rooms/sculpt/surface-mode/
- FEATURES: triangulated mesh refined by dynamic subdivision/decimation; ignores interior volume -> speed. Voxels "require extensive hardware resources" for high detail since they always include whole volume.
- SWITCH: click [V] icon in Sculpt Tree for that layer. Enter in Surface = temporarily voxelize + remesh then return (like DynaMesh).
- OPERATIONS: Add, Subtract, Intersect, Decimate, Simplify, Smooth, Harden, Blend. Depth slider modulates sculpt-layer depth; Layers > Magnify SL (depth under brush up/down); Layers > Erase SL (erase layer info locally).
- MULTIRES: works with layers, displacement, PBR; open via Space, bottom status line, or Windows > Popups > Multiresolution; can add lower level by decimation.
- LIVE CLAY: was 3DCoat's dynamic tessellation (auto add/remove polys where needed). From 2022 new brush system REPLACED Live Clay; some LC tools remain (Snake, mesh repair). Local subdivision in new engine: Tool Options > Edit Brush Parameters, uncheck "modify connected", check "autosubdivide". "Remove Stretching" = remesh under brush.
- Other: Custom Base Brush (universal custom brush mechanism); Proxy Mode (Multi Res Proxies); Paint tools 2022+.
- DATA: sculpt layers scene-wide not per object; in Sculpt room layers store deformation not colour.
- SMOOTHING: Tangent Smoothing (cleans on the fly w/o degrading details) vs Powerful Smoothing (fixes holes/imperfections, much more aggressive).
- CAVEATS: layer loss on switch to voxels; mesh cleanup after voxel->surface; import conversion options matter for faceting.

---
## 14. Voxel Tools
URL: https://3dcoat.com/documentation/manual/workspaces-rooms/sculpt/voxel-mode/voxel-tools/
- TOOLS: Vox Clay (expand + smooth after each stroke); Grow (LMB grow, CTRL+LMB collapse; size/intensity matter, alphas don't; CTRL+RMB contracted section; "Growth power"/"Thaw power" sliders); Build (continuous growth; DEPRECATED from 4.9); Airbrush; Smooth; Fill (fills cavities; CTRL+LMB flattens protrusions; more precise than Smooth; may need very high intensity); Carve (expand with alpha; Depth = strength; CTRL scoops, SHIFT smooths; no smoothing -> sharp peaks/gouges); Blob (like 2D-Paint fewer options, "Do Filling" + Density); Sphere (click = sphere, drag = cylinder, drag in open space = pill; size = brush size, optional pressure; button navigation requires ALT); 2D-Paint (sculpt on plane parallel to screen; LMB paint; RMB sets plane; SHIFT smooth; depth lock icon; combine with Stamp Drag + alphas for ornaments; red plane preview; V4 "Double-sided"); Plane (voxel thickness along two RMB-defined axes, removes material in front, CTRL fills behind; quick RMB click = menu, long click = pick point+plane, hold RMB slides center keeping normal, CTRL moves along normal; pick modes: Point&Forward, Point only, Point&Direction(average normals), Point&Direction(local), Plane perpendicular to surface, Radius Control; params Draw Plane Size, Base, Normal, Coordinates, Auto Move Forward, Forward&Back, Movement Step, Mouse wheel usage; "Act as Vox Hide" draw to hide, CTRL+draw unhide); On Plane option (Carve, Blob, Sphere, 2D-Paint checkbox); Scrape (voxel flatten, pen pressure no effect); Pinch (CTRL+LMB expands); Smudge (drags topology; wrinkles).
- HOTKEY CONVENTIONS: CTRL = invert, SHIFT = smooth, RMB = place plane/reference, ALT = navigate.
- PAIN POINTS: V4-engine brushes being phased out (only new-engine brushes kept); doc count mismatches.
- TIP: Hybrid Mesh can be a surface for On-Plane tools (retopo -> convert to Hybrid -> sculpt).

---
## 15. Surface Tools
URL: https://3dcoat.com/documentation/manual/workspaces-rooms/sculpt/surface-mode/surface-tools/
- TOOLS: Clay (adds mass + smooths; RMB duplicate to make preset); Clay Fast (no post-relax); Draw (LMB raise, CTRL+LMB indent, SHIFT+LMB smooth); Flatten (plane averaged from cursor centre); Trim Adaptive; Flat Polish (Smoothing Degree local vs Shift global smoothing); Chisel (gentle flatten, sharp edges; CTRL invert); Lute (fills cavities; start low pressure); Fill (CTRL removes embossing); Buildup (Clay without layer limit); Extrude surface (direction: Average normal, View direction, Along X/Y/Z, Vertex normal, Initial vertex normal; Spacing places alphas along strokes; VDM alphas = 3-channel 32-bit EXR); Pick & Paste (capture surface feature as VDM, re-stamp with Extrude; export EXR; import EXR/TIFF VDMs); Expand (along vertex normals); Absolute (keeps underlying detail/topology); Rapid (very fast, ignores alphas, bridges two visible objects); Rapid Smooth Scratches / Scratches2 (clay-rake); Mud (noisy; with multiple visible objects adds volume as if one layer); Pinch (CTRL expands); Smart Pinch (two planes snap); Roof Pinch (keeps noise); Shift (drag topology in screen space = surface Vox Follow).
- SMOOTH: Smooth (+ Concave, Convex, Super Relax valence-independent grid relax, Tangent). SHIFT and CTRL+SHIFT assignable to different smoothing routines: Powerful Smoothing, Tangent Smoothing, Relax, Decimate, Reduction, Reduce, Extra Detail (incl. dynamic local subdivision/reduction). Reconstruct Smoothing dissolves stray pieces. Retopo Relax (with Conform Retopo Mesh; SHIFT/CTRL+SHIFT). Sharpen.
- MASKING: Freeze (CTRL+D clear, CTRL+SHIFT+I invert; Freeze > Layer store; Click&pick > Freeze recall from layer; Current layer > Freeze from layer opacity; SHIFT/CTRL add/subtract). Surface hide (brush or Stroke draw; CTRL+D unhide; CTRL+SHIFT+I swap; Invert hide; store hidden state to a layer).
- OTHER: Snake Clay; Copy Clay (LMB source, LMB target, Clear Data); Magnify Layers / Erase Layers (Sculpt Layer only).
- WORKFLOW (Dam Standard tutorial): Pinch + "Remove Stretching" + "Auto-Subdivide" + Magnify SL. Videos: Dissolve smoother, Subdivide brush, Angulator (pinch/crease along painted selection).
- HOTKEY: ENTER = temporary voxelize+remesh in Surface.

---
## 16. Live Booleans
URL: https://3dcoat.com/documentation/manual/workspaces-rooms/sculpt/live-booleans/
- FEATURES: non-destructive booleans via Sculpt Tree hierarchy; voxel volumes only (current stage). Live update while sculpting; complex hierarchical combinations; undo works; picking correct (retopo possible); painting correct; baking, 3D-print export, Merge visible/subtree to surface/voxels all work.
- WORKFLOW: add child volume to a volume -> RMB child in Sculpt Tree "Live.." items (or RMB model in viewport > Live Booleans). Ops: subtract, add, union. RMB boolean icon = quick menu to change op; click LB icon toggles boolean off. Finalise: drag LB layer onto parent (Shift = add, Ctrl = subtract while dragging) or RMB "Collapse boolean tree". Ghost the cutter volume: still cuts parent but visible and sculptable via ghost picking. Live boolean section in RMB menu bindable to hotkeys.
- SOFT BOOLEANS (bevels): disable live booleans (RMB LB icon) -> RMB voxel object > "soft boolean settings" -> enable for voxels or use in Surface -> bevel radius from brush radius or numeric -> shape flat/rounded -> e.g. "Subtract From" then pick target -> Resample higher if edge not smooth.
- CAVEATS: instancing doesn't mix (instancing stops once booleans used); preview shows small narrow holes but export is watertight; live booleans can't do soft edges.

---
## 17. Voxel Objects Tools
URL: https://3dcoat.com/documentation/manual/workspaces-rooms/sculpt/voxel-mode/voxel-objects-tools/
- TOOLS: Primitives (library of meshes, splines, latheable objects); Import (ENTER applies; brush/move/rotate/scale placement; must be closed & non-self-intersecting); Tree Generator (procedural non-destructive; leaves, crown sculpt, FBX export); Logo (B/W image -> voxels by grayscale; BMP/TGA/JPEG/PNG; defaults to merge tool + gizmo); Constructor (voxel-only, snapping brick presets, Place Edges/Corners, Smart Placement, Brick Size XYZ; parts merge into one solid); Sketch (paint masks on front/side/bottom planes: white add, black subtract, Ctrl+LMB paint black; Clear/Fill Current; Reset Sketch; reference image must be 512x512; use tool's own symmetry not global, they conflict); Split & Joints (Surface only; cut into parts with interlocking sockets: custom spline, cylinder, parallel pipes, flat; gizmo; for 3D print/articulation); Split (tear chunk into own Sculpt Tree layer; Border Width 1.0 clean, 0 bevels); Clone (copy selection without cutting); Cut & Clone (cut+clone voxel volume by brush; default drag-rectangle pen mode copies whole volume underneath; borders Round/Plane/Sharp); Vox Extrude (like Vox Layer w/o new layer, switches layer to Surface; Ctrl+Apply inverts); Vox Layer (thin shell around frozen area: Freeze paint -> Apply); Coat (non-destructive curve-defined coating: RMB curve > "Fill with Mesh Layer" -> SculptTree item with thickness/extrusion/smoothing); Points to Polygons (LMB add point, RMB tweak/add faces, SHIFT force triangles); Snake (LMB drag; profiles, spline presets, Tube reset, smoothing 1-5); Spikes (tapering snake); Toothpaste (respects alphas -> custom rake); Muscles (Muscle/Tendon, Conform to surface, smoothing speed); Cloth (voxel-only cloth sim drape; imports OBJ/LWO/FBX/STL/PLY/3b; Start/Pause/End/Reset; Gravity, Friction, Thickness, Rapid; slower at high res; ghost/hide source volume to avoid collisions).
- No explicit Merge section on page.

---
## 18. Density and Resolution
URL: https://3dcoat.com/documentation/manual/workspaces-rooms/sculpt/voxel-mode/density-and-resolution/
- DATA STRUCTURES: each volume/space has its own Density (= scale within space; doesn't change voxel count) vs Resolution (actual voxel count). Analogy: density~scale, resolution~subdivision ("not exactly").
- WORKFLOWS: RMB Volume in Sculpt Tree > "Decrease object 2X (increase density)" / "Increase object 2X (decrease density)". "Inc. res" button (left panel). RMB > "Clone and degrade" (lower-res copy as new volume). Geometry > Res+ before merging primitives (0.25x1 inch cylinder may need 256x). Res+ applicable before import, saved with file. Geometry > define Measurement Units: voxels per unit + units scale.
- CAVEATS: "a little bit of trial and error". Imported objects keep original scale; Edit > Scale Master Scale option to keep scale when merging; scale import up to capture details.

---
## 19. Brush engine
URL: https://3dcoat.com/documentation/manual/workspaces-rooms/sculpt/brush-engine/
- FEATURES: modify existing brushes or build new; last settings remembered per brush; "Edit brush parameters" opens tool options. Buildup vs non-buildup (non-buildup stops at height limit on repeated strokes; buildup keeps growing slowly). Voxel colour applies to Blob, Spike, Snake, Muscle, Primitives; sculpt + paint simultaneously with all Voxel Brush Engine brushes.
- INFLUENCE AREA (surface brushes): limits effect in tight areas; "Render influence area" 3D preview of affected region (can turn off); "Customized influence" scale/squash top or bottom half of influence sphere (%) to control extrusion above / extension below surface.
- OPTIONS: Camera Viewpoint (add/remove by view direction not surface); Voxel-only: Voxel Paint, Act as Vox Hide (any brush acts as hide), Modify Connected, Post-smooth. Menus: Subdivision (NOT supported while Modify Connected on), Brush Stroke, Misc Settings (buildup), Sampling (stroke position), Modifiers.
- DATA STRUCTURE: brush = stack of MODIFIERS ("building blocks"): Smooth, Smudge, Pinch, Rotate, Side shift, Angulator (two planes snap + slight pinch). Alpha: "Use current alpha" ON = library (T opens library), OFF = procedural alpha via curve editor. "Add Brush Modifier".
- HOTKEY: T alpha library.
- TIPS: two brushes closest to ZBrush Dam Standard; Remove Stretching, Auto-Subdivide (dynamic subdivision under brush), Magnify SL + Pinch.

---
## 20. Brush Components
URL: https://3dcoat.com/documentation/manual/brush-components/
- STANDARDISED BRUSH CONTROLS (all rooms): LMB drag = primary function; RMB drag L/R over object = size; RMB drag U/D = depth (both also numeric in Brush Parameters top panel); SHIFT+LMB = smooth with almost any tool (Paint & Sculpt); SHIFT+CTRL+LMB (Sculpt only) = Top Bar action, default "Powerful Smoothing" (selectable); Falloff, Smoothing, spline-based Steady Stroke via checkbox/numeric.
- COMPONENTS: Alpha (profile image affecting depth + bristle shape; can be built from 3D .obj view-based height map); Stroke Mode panel (pressure, lasso, curve modes; "one of the most versatile parts"); Brush Options panel; Top Bar (Depth, Smoothing, Opacity, Glossiness toggles; Paint: Conditions icon toggles Mouse vs Tablet response); Conditions (Height/Color limiter); Strips (repeating patterns along strokes); Stencils (mask areas, affect pen depth/transparency); Smart Materials; Stencil & Smart Material Preview panel (opens when active).
- CUSTOMISATION: Smart Materials + Stencils + settings saved together as a Brush Preset (share with team). Alphas installable singly or as packs (.abr import; free XMD pack linked).
- CAVEATS: reset Conditions to "None" when done or it keeps limiting strokes; SM/stencil settings only visible when active; OBJ alpha view-dependent.

---
## 21. Strokes (Stroke Mode / E panel)
URL: https://3dcoat.com/documentation/manual/brush-components/strokes/
- OPEN: hover "Stroke Mode" menu or press E -> 20 drawing modes. First six (yellow rectangle) = standard brush modes requiring pressure tablet.
- PRESSURE MODES: Radius&Depth Pressure; Depth&Opacity Pressure; Radius,Depth&Opacity; Droplet (more pressure -> smaller radius, more depth/opacity); Constant; Dotted Stroke (dot spacing depends on stroke speed).
- LINE/CURVE: Vertex Lines (click vertices; click start closes; ESC new line; Shift on first click); Vertex Curves (interpolated); Curve Stroke (spline, per-point radius; ESC ends chunk; RMB point = sharp/smooth; LMB assigns radius; extend from ends; split; drag points; DEL delete; ENTER/double-click draw); Stamp (click impression; LMB drag resizes+rotates; release places); Stamp Drag (slides alpha across surface).
- LASSO/SHAPE: Square Lasso (SPACE numeric size; ortho recommended); Rectangle Lasso (works with paint, freeze, fill, planes; Q = square); Vertex Lasso (double-click/start vertex finish; ESC cancel; BKSP delete last; SPACE moves shape); Polygon (green circle on first point + ENTER); Stroke Lasso (freehand hold LMB; "relaxation" param; smoother cut edges); Shapes (Windows > Popups > Shapes / activity bar; number keys apply shapes, sequences e.g. 1 then 5 = 15; ALT rotate, R round, Q modifier); Circle Lasso (SPACE numeric; from centre); Ellipse (Q exact round); Closed Spline (ESC stop; RMB smooth/angular; DEL; click inserts; ENTER/double-click finish; save/load shapes); 3D Closed Spline (enable Edit > Preferences > Beta Tools "Allow Splines from V4.9"; draws in 3D space); Single Polygon.
- BOTTOM: Border width (extruded falloff: square -> curved pyramid); Depth Limit (from last pick point; mm/cm in ortho per measurement units); Ignore back faces; Expand from Center (hotkeyable); Settings (modifier key for square/round).
- HOTKEYS: E, ESC, ENTER/double-click, DEL, BKSP, SPACE, ALT rotate, CTRL+ALT constrain rotation (Preferences > Tools), Q, R, Shift, number keys.
- CAVEATS: pressure modes need pressure tablet; Curve Stroke radius only shown for surface-attached points; when not sculpting, shapes act in 2D as masks/freeze; higher voxel res -> cleaner lasso shapes; shapes used for cloning, cutting, booleans.

---
## 22. Brush Options panel
URL: https://3dcoat.com/documentation/manual/brush-components/brush-options/
- PARAMS: alpha preview; Brush Rotation; Zero Pressure Radius (stylus start radius); Depth Modulator; Rotation Amplitude; Radius Variation %; Depth Variation %; Jitter Opacity/Position/Hue/Brightness/Saturation; Vary color per stroke (fur/hair); Random flip x/y; Paint with dabs + Use spacing (%); Rotate along stroke; Skip eraser; Sharp Shape (old style); Sharp Shape with all alphas; Fade on edge; Apply Brush "Dabs" with Spacing.
- CUSTOMISATION: assign key to "Start brush rotation" in Customize Navigation.
- CAVEATS: Sharp Shape (old) doesn't work with airbrush/native voxel tools (always sharp). "Experimentation is the best way to learn".

---
## 23. Conditions (Height/Color) Limiter
URL: https://3dcoat.com/documentation/manual/brush-components/conditions-limiter/
- FEATURES: Top Bar icon (next to Condition Mask layer / Degree); controls how depth/colour/gloss of strokes depend on colour, height etc. Reset to "Always" when done.
- PREREQ: Edit > Calculate (or Textures menu) Occlusion (depth, contrast) and Curvature ("cavity" + "long-range" intensity).
- MODES: Always; More/Less on Concave; More/Less on Convex; More on Flat; More on Curve; More on Lit / Shadow (need AO); More on Top / Bottom / Sides; More on Bright/Midtone/Dark (current layer colour); More on Picked (near picked colour); More on Bumped / Dent (current layer displacement).
- WORKFLOWS: recommended non-destructive: new layer -> RMB Smart Material > "Attach to current layer". Edit: detach -> Smart Material Editor -> cavity/dirt layer condition: Cavity Width, Cavity Degree, Contrast -> reattach. Conditional painting: paint tool > "Conditions" dropdown (default "No Masking") > e.g. Concavity.
- CAVEATS: conditions only work with Freeze in Sculpt surface mode, or Surface Paint on vertex in Paint; standard sculpt brushes ignore conditions (only respect Freeze); Bumped/Dent only on layers with displacement; RGB cavity layer must exist for width changes; vase params (Overall Cavity Modulator, Cavity area width, Additional Cavity width).

---
## 24. Brushes general use (Alphas)
URL: https://3dcoat.com/documentation/manual/brush-components/brushes-alphas/
- DATA STRUCTURE: alpha = grayscale intensity map; 8-bit alpha holds 4 internal channel layers: Color/Transparency, Height/Depth, Specular, Erase Mask -> multi-channel brush tip painting several channels at once. TIF holds up to 7 channels (RGB, alpha, height, specular, erase mask). Alphas may mix positive/negative values (EXR) for skin; negative alphas for draw/extrude brushes. "Positive alpha" option (don't subtract top-left pixel; 16-bit TIF).
- FORMATS: TGA, PSD, ABR, 3D model as brush; 16-bit only for TIF/PNG/EXR (16-bit alpha TIF only); PSD/JPG converted to 8-bit. Grayscale -> 1-channel file; colour 16-bit -> RGBA; RGB-only puts alpha+height in Green (colours look faded). Drag & drop import. .penpack packages.
- HOTKEYS: T alpha panel; Radius [ ]; Rotation ( ) (1-360 deg; red line shows orientation); Depth - +; mouse wheel for these requires Preferences setup; rotate by mouse via Camera > Customize Navigation > ActionType: Start Pen Rotation (e.g. SHIFT+mouse); SHIFT+draw smooth; hold LMB then SHIFT = straight line; CTRL+draw = cavities; Shift/Ctrl multi-select alphas (order matters; page inconsistent sequence vs random).
- UI: RMB on alpha: Brush Options, Delete, Save to PSD/TIF, Load from PSD/TIF, Edit in external editor (live link, autoreload; default Photoshop). Dropdown: Refresh preview, Add New Folder, Add Existing Folder, Add pictures from folder, Add Brushes from package, Folder filter, Icon Size Tiny/Normal/Large/Huge.
- CAVEATS: many apps don't support TIF layer channels (only Photoshop/GIMP); clipped decals need multi-layer PSD; tip on keeping 3DCoat from switching brush packs via hotkeys.

---
## 25. Brush Top Bar
URL: https://3dcoat.com/documentation/manual/brush-components/brush-top-bar/
- PAINT CHANNELS: Depth, Color, Glossiness painted simultaneously; click icon toggles (big X when off); hover reveals options; RMB drag U/D intensity, L/R size. Depth purple sphere; Color green sphere/texture folder; Glossiness shining sphere. "~" = semi-transparent compact channel panel (pinnable). Additive drawing toggle. Cursor: red line = relief depth, green line while SHIFT = smoothing, blue segment = opacity. Colour source: current / random between primary+secondary / random mix. Roughness builds up to toolbar value.
- CONTROLS: Pen/Mouse/Lock icons (pressure mode: mouse icon = fixed value; pen = stylus pressure; lock near Depth = radius changes without changing absolute depth); Steady stroke; Invert Tool (=CTRL); Radius (relative to scene scale); Tapering (needs radius/opacity pressure-dependent); Focal Shift (must be enabled in Preferences); Falloff curve; Depth, Smoothing, Opacity, Glossiness Intensity, Roughness, Metalness; Brush Curves (pressure->radius); Conditions; collapse settings by clicking label area.
- HOTKEYS: ~ compact panel; D depth; C colour; R glossiness; - + depth; SHIFT smoothing; SHIFT+"+"/"-" smoothing amount; O/P opacity; < > glossiness; CTRL invert; SHIFT / CTRL+SHIFT Anti-Bump Smoothing menu (Surface).
- CAVEATS: mouse wheel adjust only if enabled in Preferences; heavy pressure on complex pen shapes -> steep height overfalls, distortion when normal-mapped to low-poly; reset limiter to None. No symmetry/lazy-mouse on top bar besides Steady stroke.

---
## 26. Freeze menu
URL: https://3dcoat.com/documentation/manual/interface-and-navigation/freeze-menu/
- DATA: Freeze = mask; Photoshop-style clipping layer masks in Sculpt & Paint; Freeze state <-> layer Opacity/Transparency convertible. Freeze Mask to Layer / Pick to Apply Freeze Selection / Current Layer Color to Freeze Selection (SHIFT add, CTRL subtract) - like storing a Pose selection. Freeze/Pose Opacity only changes display not strength.
- COMMANDS: Activate Freeze Tool; Toggle Freeze View (patterns black/white); Show/Hide Freeze; Freeze Painted Pixels / Transparent Pixels / Surface / Border / Paint Object / Surface Material; Unfreeze Paint Object / Surface Material / All; Invert; Smooth Freezing (feather); Sharpen Freezing; Fill Unfrozen; Erase Unfrozen; Hide Frozen Area; Expand/Contract Frozen Area (1 px); Fill by Transparency; Store/Restore Freezing State (to disk).
- HOTKEYS: Alt+F view; Ctrl+F show/hide; Ctrl+NumPad/ border; Ctrl+NumPad+ expand; Ctrl+NumPad- contract; Ctrl+D unfreeze all; Ctrl+Shift+I invert; Ctrl+NumPad* smooth.
- PAIN POINTS: numpad-dependent hotkeys; several undocumented commands.

---
## 27. Symmetry
URL: https://3dcoat.com/documentation/manual/interface-and-navigation/symmetry-menu/
- OPEN: S key or Symmetry menu; off by default; all rooms.
- CONTROLS: Enable Symmetry; Show Symmetry Plane; per-axis X/Y/Z; reset plane; hide display; lock plane position; centre per axis: Global Space / Local Space (object centre) / General Case Axis (custom, rotate/roll axis); Pick from Bound Box; Store state.
- TYPES: Mirror (one or multiple planes); Radial (N slices; can combine with mirror; radial created before mirror); Radial Mirror (radial after mirror plane); Translation (periodic/tiled; splash tiles colour-only cause sculpt artifacts; translation is artifact-free method: Surface box 120x120x5 with 100x100 offsets, new SL layer first, Erase SL / delete layer reverts).
- RETOPO: Virtual Symmetry (mirror display w/o creating polys; "Apply symmetry" makes real); caveat: symmetry on an already symmetrical retopo mesh creates extra overlapping geometry; virtual doubles visible poly count.
- WORKFLOW (non-conformed symmetry, community Evil_Weasel): flat plane from Modeling room into Surface layer -> enable symmetry, transform plane (symmetry follows) -> delete polys (symmetry remains) -> convert to voxel -> Shift+drag object onto helper layer to merge -> store helper in Sculpt Models panel. Voxel mode can't make a flat plane primitive.
- Geometry/Symmetry copy to mirror object around another.

---
## 28. Room Customization
URL: https://3dcoat.com/documentation/manual/interface-and-navigation/customization/
- FEATURES: 2022 UI rework; customise via scripts or manually; custom Rooms and Workspaces; simplified mode vs full functionality.
- OBJECT TREE: layer colouring; one-button grouping; gizmo-less move/scale/rotate.
- HIDING UI: Edit > "Customize UI" checkboxes per menu item/tool (recommended for narrow tasks). TAB hides whole interface; then Space = tool/color popup (all left-panel paint tools + colour wheel), "~" = Main Paint Functions panel at cursor.
- WINDOWS: show/hide/move/dock/undock/float; drag tab until blue outline to dock; drag out to float; drag borders to resize (laptops); arrangements savable; popup menu via small down-arrow top-right of a window (e.g. Pen window "Large" icons).
- Activity Bar = Preview/Beta (Preferences > Beta). Projector tool via light icon.
- HOTKEYS: Hints; END + key (single or multi-button); reassign / stack / remove.
- Add tools to other rooms (e.g. SmartRetopo into Modeling). "Edit Text Tags" dialog to rename tools/brushes and submit to Pilgway.
- CAVEATS: Activity bar beta; no official dual-monitor support.

---
## 29. Modify or Create new Room
URL: https://3dcoat.com/documentation/manual/interface-and-navigation/modify-or-create-new-room/
- FEATURES: custom rooms with a chosen base toolset; menu/room scripts in UserPrefs/Rooms/; room scripts may be Python (.py instead of .cpp, same function names).
- WORKFLOW: room tab wrench icon "Edit the Current Room Settings" -> Edit Menu Panel -> enable "Use Script for the menu" (required to persist) -> Edit... opens menu.cpp in notepad (stored Documents\3DCoat-2022\UserPrefs\Rooms\CustomRooms\Paint) -> add line -> OK.
- DISCOVERY PATTERN: RMB+MMB together over any command copies its script call to clipboard, e.g. cmd("$GreyscaleLight"); or ui("$GreyscaleLight").
- MENU SCRIPT: CreateViewMenu() { start_main_menu("VIEW"); menu_item("CommandName"); menu_separator(); menu_hotkey("5",0,0,0); }.
- RMB script lets users customise the right-click action menu (Rygaard videos).
- CAVEATS: version-specific path; example comment mislabelled.

---
## 30. Preferences
URL: https://3dcoat.com/documentation/manual/interface-and-navigation/edit-menu/preferences/
- GENERAL: Restore "Don't show again" hints; Reset Hotkeys; Restore Hotkeys to Default; Restore Windows & locations; background zip of saves; "Don't use sticky keys"; update notifications; "Allow inertia" (scroll velocity); Show Tooltips; Hide Left Tool Panel (use space menu); pick-point coordinate preview; Autosave (interval, Autosave Depth History; autosave.3b in User Data); translation; PERFORMANCE: Multi-Core Optimization, Max Processors, Multi-Core saving, Use MRT (real-time normal map updates), Auto Reload Changed Modules, Shader Debug Mode, Store Windows state; AO/Curvature auto-calc policy (defaults/ask/skip).
- IMPORT/EXPORT: Quixel folder watch; FBX units; External 2D Editor (PSD; layer order breaks in Clip Studio/Affinity/Krita); Normal map preset: normals method (3DCoat area-weighted, Maya, Angle Weighted, Square Weight, Maya 2013+), DirectX vs OpenGL export, Triangulation Method (must match DCC), Tangent Space (Mikk "90% of the time the best"), Swap TB, Denormalized TB, Normalize TB; Padding modes; presets override prefs; 3D-print presentation renders.
- VIEWPORT: Z-up option; hide nav gizmo; background/env; Fixed Scene Scale (keep objects ~10-300; new objects only); Measure Units = labels only; Vertical sync; gamma; ACES; Iterative Viewport AA (idle); Auto-reduce GPU Quads Resolution during brushing if not processed within ~1 s + Trigger Time threshold; Sculpt RMB properties (hotkey via Windows > Popups > Trigger volume properties); RMB properties in Retopo/Modeling/UV; Near plane modulator; Screen Space Grid; import thumbnails on start page; Camera Zoom/Rotation Speed; MOUSE WHEEL, Ctrl+Wheel, Shift+Wheel, Alt+Wheel each mappable to a parameter; wheel zoom speeds persp/ortho/UV (-1 reverses); 3D print Layer Thickness, Build Size.
- BRUSHING (tablet): Tablet Interface Wintab vs Tablet PC (Windows Ink: uncheck "Use Windows Ink" in Windows tablet props); Brush Sensitivity; eraser as pen; ignore pen double-clicks; voxel paint depth (deep = artifacts/slow); remember brush/strip per tool; remember radius per tool; show/hide Focal Shift & Falloff; Symmetry Point Opacity; prevent double painting over stacked UV islands; brush visibility: hide with Caps Lock (Always/Never/Show when needed), hide while stroking, show shape curve, alpha preview, central dot in Caps mode, message near brush; brush colours; Compact interface TAB.
- 3D MOUSE (3DConnexion): older API (lag w/ wireless), ortho zoom speed, translation modulator, show pivot, default pivot at viewport centre.
- THEME: UI font, Font Size = UI scaling; no search in space panel; Activity bar vertical/horizontal/hidden; folders as buttons; tabs vs drop-list for rooms; grey-out background behind popups; themes Dark/Grey/Light (.xml in OptionsPresets; custom saved .json in UserPrefs/UI_Color_Themes); icons replaceable (baseicons.psd, SmallIcons.psd -> DDS).
- TOOLS: Retopo auto-select edges on delete; Sculpt: density/polycount labels by volume names, skip Downgrade/Restore question, legacy multires proxy mode, subtraction shell, soft booleans for voxels, QWER gizmo hotkeys, full-circle screen-space rotation gizmo; RGB cavity (R near radius 100, G middle 20, B local 1); E-mode ALT+CTRL angle step, array/rounding keys; memory info diagnostics; OBJ vertex order; Nodes display; Timelapse recording (no interface, camera smoothing, interval).
- BETA: ShowBetaTools (recommended on; "essential part of 3DCoat" yet unfinished); Allow splines from V4.9; Treat retopo groups as materials (experimental, own risk).
- NOTE: page doesn't cover undo levels, touch, CUDA.

---
## 31. Tablet on Window
URL: https://3dcoat.com/documentation/manual/getting-started/tablet-on-window/
- SETTINGS: Tablet Library: WinTab (default; needs Wacom WinTab driver) vs Tablet PC (Windows Ink; no extra driver). Switch tablet icon to pen (LMB on it). Edit > Preferences > Brushing > Brush Sensitivity (e.g. 0.1 vs default 1 for stronger light-pressure response). Per-brush pen vs mouse (constant) icons beside Radius/Depth.
- DRIVER: Wacom Tip Feel / pressure curve; Huion Pressure Sensitivity Adjustment.
- PAIN POINTS: Wacom raised pressure levels -> must tune; inconsistent menu paths; old video; no touch or pen button info.

---
## 32. Stylus doesn't work in sculpting
URL: https://3dcoat.com/documentation/manual/navigation/stylus-doesnt-work-in-sculpting/
- CAUSES: tablet in Mouse mode (unsupported); wrong interface (Wacom vs WindowsInk); corrupted user settings ("unlogical behavior").
- WORKFLOW: run TestStroke (pilgway standalone Windows app, system-level stroke code only; press 1 = Wacom, 2 = WindowsInk) -> Wacom Mapping tab Mode = Pen -> rename Documents\3DCoat user folder ("crucial") -> relaunch (defaults) -> Edit > Preferences > Brushing > Tablet Interface -> manually copy assets back.
- PAIN POINTS: Windows-only guidance; reset-user-folder as fix; manual asset restore.

---
## 33. Activity Bar
URL: https://3dcoat.com/documentation/manual/navigation/activity-bar/
- Photoshop-like panel bar, hover icon to open panel: Shapes, Brushes, Panoramas, Brush Parameters, Strips, Stencils, Smart Materials, Sculpt models, 3D Splines, Joints, Presets. Also Windows > Panels. Horizontal/vertical via Edit > Preferences > Theme "Activity bar position". (Hover-to-open = no touch equivalent stated.)

---
## 34. Retopology (room)
URL: https://3dcoat.com/documentation/manual/workspaces-rooms/retopology/
- FEATURES: creates low-poly mesh over a sculpt mesh (Modeling room = low-poly without sculpt reference, different tools). Handles Auto-Retopo output, from-scratch, or external topology. "Easier to learn" than Sculpt.
- UI (4 areas): Tool Panel (left; topology, seams, unwrap); Poly Groups panel; UV Preview panel (PREVIEW ONLY, not editing); Retopo menu (import/export, baking, save/restore). Top Bar shows contextual params.
- TOOLS: vertices/edges/faces/strips; auto-snap to nearest sculpt surface; loop networks via Through Strokes + Freehand Strokes; Extrude & Bevel on edges+faces; Relax; Grow/Shrink selection; 2D primitives (circle, box, plane, ellipse, N-gon, disk, triangle); primitive booleans add/subtract/intersect/split; Record Script button (red recording/blue stopped) + script command generator; compact context-sensitive RMB menu.
- DATA STRUCTURE: Retopo Poly Groups = Photoshop-like layers per Sculpt Tree object (drag reorder, trash, visibility); multiple retopo versions coexist; created by Autopo or manually.
- EXPORT: obj, lwo, fbx, stl, ply; Export selected (patch); Export separate groups.
- CAVEATS: choose correct UV map and retopo layer before working (notice shown if wrong); snapping issues (tutorial); bake required before UV editing in UV room.

---
## 35. AUTORETOPO (Autopo)
URL: https://3dcoat.com/documentation/manual/workspaces-rooms/retopology/autoretopo/
- ACCESS: Sculpt > Geometry > Autopo, or RMB any mesh in Sculpt > Autopo.
- OUTPUT MODES: AUTOPO (edge loops -> Retopo room); AUTOPO with Ptex; AUTOPO with MV Paint; AUTOPO for Per Pixel (-> Paint room with auto seams/maps). New Paint sub-object per Sculpt Tree layer; batch multiple layers (video).
- ENGINES: default Autopo; Instant Meshes (isotropic tri/quad-dominant, aligns to sharp features, "under a second" on 100k+ faces); Old-style quadrangulation (poor; quick quads only).
- PARAMS: Mesh Source (selected tree items); Required Poly Count (>= 2x mesh polycount after subdivision recommended); Symmetry (improves quality; finalise before start; axial not supported -> use Radial Mirror); Quadrangulation Quality (Draft preview vs final); Capture Details (more poles); Hard Surface Retopology; Auto-Density Influence Multiplier (curvature-driven density); Voxelize Before Quadrangulation (scans; then decimate); Voxelized Object Poly Count (x1000); Decimate if Above (x1000); Smooth Resulting Mesh Tangentially (keep sharp); Bypass density and strokes (fully automatic).
- GUIDANCE: Density Shading (paint mask with brushes or E-panel); Flow Guides (stop/start around joints; fingers from tip past wrist); Through guides (straight, cut through model, start/end outside mesh; lateral across arm = loops). Old Crease Angle removed: curvature-based detection; Hardsurface mode for sharp edge detection on voxelized soft objects.
- BEST PRACTICES: first pass with no guidance ("over-masking is easy"; none sometimes best); ortho views for guides; hard-surface static models: just final polycount; if seam placement matters use simple AUTOPO then manual seams in Retopo; hard-surface animated often better manual.
- CAVEATS: auto UVs consistent quads but awkward seams; dense small polys near edges read as creases; no hotkeys.

---
## 36. Add Geometry (Retopo tools)
URL: https://3dcoat.com/documentation/manual/workspaces-rooms/retopology/left-tool-panel-in-retopology/add-geometry/
- TOOLS: Add/Split (click to add edges/polys, split, connect; RMB tweak); Quads (drag from edge; Parallel, Direct, Trapezoid 2-click methods); Points to Polygons (LMB add point, hover + RMB create poly, RMB drag tweak, SHIFT triangles; Special > clear); Cap (hover hole + RMB -> pole + triangles); Strokes (draw strokes, ENTER poly-surface, ESC clear, CTRL-draw add/connect/break, closed splines, start in empty space to slice, slices+circles -> cylinder; Special: Clear/Smooth/Delete); Primitives 3D/2D with booleans; RFill ("Quad Fill"); Knife (line, ENTER/double-click); Smart Retopo (Loft, Strip, Quadrangulation boundary -> ENTER; SHIFT disables snapping; RMB edit edges; CTRL slide edge; CTRL+SHIFT split rings; U Spans with CTRL+wheel; "Alternative Select"); Spine Tool (extrude faces along arc; spline mode LMB drag, wheel scales loop; ENTER/New Extrude; double-click adds/removes loop); Smart Extrude (ENTER new; RMB+drag scale; SHIFT+drag rotate; modes Free, Normal, Extrude Faces, Extrude Vertices; new verts snap later unless Auto snap off); Make Joints (details external doc).
- PATTERN: ENTER = commit, ESC = clear, RMB = secondary/tweak, SHIFT = disable snap/force tri, CTRL = modify.

---
## 37. UV (room)
URL: https://3dcoat.com/documentation/manual/workspaces-rooms/uv-workspace/
- FEATURES: modify UVs on imported meshes; island position/size/orientation/alignment; stretch limiting; packing. Retopo and UV rooms share identical UV tools. Unwrap algorithms LSCM (older) and ABF++ (newer), chosen before unwrap. Real-time unwrap preview with per-part distortion as seams are marked. Multiple UV maps / UDIMs per mesh (polygons can't be shared between maps). Select islands in viewport; swap UVs after painting "without penalty".
- WORKFLOWS: finalise topology -> bake to Paint room -> UV room available. Retopo objects need UVs before baking to Paint. Edit existing: tweak topology in Retopo -> unwrap -> UV room for placement/packing. Iterate UV<->Paint. Paint room Texture UV Editor for precise labels.
- BEST PRACTICES: few, large pieces; similar sizes; economical arrangement; watch distortion preview; separate maps per purpose.
- CAVEATS: UV room only for Paint Objects; seams required before unwrap.

---
## 38. UV workflow example
URL: https://3dcoat.com/documentation/manual/workspaces-rooms/uv-workspace/uv-workflow-example/
- WORKFLOW: import -> UV room -> (opt) Clear seams -> (opt) Auto Seams / Sharp Seams (mechanical) -> click edges to make seams; cut at corners; red/blue = distortion -> cutting off area creates new island (new colour patch) -> Unwrap -> rotate/scale islands -> brush to smudge islands -> APPLY UVs -> back to Paint.
- HOTKEY: Ctrl+click removes seam.
- CAVEATS: nothing unwrapped until Unwrap; unwrapping doesn't change mesh until Apply (old UVs remain on export/return) - useful as non-committal preview state.

---
## 39. Paint (room)
URL: https://3dcoat.com/documentation/manual/workspaces-rooms/paint/
- FEATURES: 3D counterpart of 2D painting apps ("familiar to Photoshop users"); layer-based brush-driven; paint Diffuse/Albedo, Glossiness/Metalness, Depth simultaneously; depth exports as Bump/Displacement/Normal; colour layers as vertex weight/emissive maps.
- MODES: Per Pixel (precise, no displacement); MicroVertex (heavier displacement); Ptex (no UV seam concerns); Surface/Vertex (Polypaint on Surface models); Voxel painting. Vertex colours on sculpts and Ptex bakeable to UV maps.
- UI: left tool panel; Channels (Depth/Color/Gloss); Stencil & Material preview; Preview Options; Color Picker (image colour panel, palettes); Paint Wheel (any image as colour wheel); Texture UV Editor (Textures menu); Hub Mode panel; Tweak tools. Menus: Edit, Textures (Texture Baking Tools), Hide, Bake Paint, Color Picker.
- INTEGRATION: Live Photoshop connection / External 2D Editor (PSD); Krita ("Photoshop replacement on Linux"). Video on hotkeys matching Photoshop tools.
- CAVEATS: cannot triangulate mesh in Paint room after setup (workaround: copy to Retopo, triangulate, bake back with normal map; or tick Triangulate on Per Pixel import); importing alpha directly not possible (workaround: Linked Layer); Paint room has no mipmapping (for real-time speed; filtering in Render room); "Clear All Unused Painting Layers" before re-baking to avoid duplicates.
- BEST PRACTICES: tablet + stylus; Stroke Mode/Stamp for precise repeats; Smart Materials for multi-channel PBR; test UVs in UV room; check in Render room.

---
## 40. The Layers Panel (Paint)
URL: https://3dcoat.com/documentation/manual/workspaces-rooms/paint/the-layers-panel/
- DATA STRUCTURE: Photoshop-like layers, scene-level (not per object); per layer: Opacity (+ blend mode), Depth Opacity (+ Depth Blending: Add, Subtract, Max, Magnify (exponential), Suppress), Gloss Opacity (Roughness Opacity in metal/rough), Metal Opacity. Blend modes per channel (color, depth, gloss, normal). In Sculpt room layers hold deformation; baking sculpt-layer deformation = resample mesh. Layer 0 = Background (mesh data + neutral 0.5 grey base, alpha 1; avoid painting it except transparency; displacement always based on Layer 0).
- UI: Blending panel via down-arrow on hovered layer or Window > Popups > Layer Blending; Lock Texture (cache per channel to disk at full res for AO/cavity/normal when painting low-res); Pass-through (groups only); emissive via blend mode. Icons: Eyeball (Alt-click = solo); six-dot drag handle, double-click rename. Bottom: Add, Folder group, Merge Down, Duplicate, Shift up/down, Delete All Unused, Delete.
- RMB MENU: Lock Texture, Layer Blending, Duplicate, Flip Layer (+Duplicate) via topological symmetry, Copy Blue<->Red, Copy Channels, Merge Visible (undoable), Merge Down (NOT undoable), Merge Up (NOT undoable), Freeze Painted / Transparent Pixels (Ctrl+LMB on layer), Discard Clip Masked Pixels, Apply Blending, Color to Specular/Glossiness, Invert Color/Glossiness, Fill entire layer, Refill Material, Set Height to Zero, Make Transparent, Remove Glossiness.
- HOTKEYS: Ctrl+Shift+N new; Ctrl+Shift+Del delete; Del erase unfrozen; Insert fill unfrozen; Ctrl+Insert fill by mask; Ctrl+Shift+D duplicate; Ctrl+Shift+E merge visible; Ctrl+E merge down.
- Groups compatible with Photoshop groups. OBJ displacement export settings sets 1/2.
- PAIN POINTS: some merges not undoable; distorted layers need re-bake/vector displacement; sculpt-layer data lost Surface->Voxel.

---
## 41. Smart Materials
URL: https://3dcoat.com/documentation/manual/brush-components/smart-materials/
- CONCEPT: PBR materials with separate textures per channel (Color, Depth, Glossiness, Metalness) + layered hierarchy + Condition Mask + Edge Scattering + Opacity Mask; projected via mappings (Cube recommended for seamless; UV, Cylindrical, Spherical). With no material selected (big X), channels use the brush alpha.
- STORAGE: Docs/3DCoat/UserPrefs/SmartMaterials (user) vs data (temp); 3dcpack packages; auto-convert copied legacy files.
- APPLY: hide other paint objects or mask layer; FILL tool by object/contiguous mesh, UV shell in 2D Texture Editor, all visible, by UV map.
- RMB: Delete, Share item, Share item folder (3dcpack), Duplicate, Attach to current layer, Refill Material, Fill Entire Mesh, Refresh Preview, For all materials (default mapping), Move Items to, factory defaults.
- EDITOR: Name, Overall Displacement Scale, Overall Cavity Modulator, Preferred Mapping, Layer, Color, Depth (greyscale height, NOT normal map despite icon), Glossiness, Metalness, Condition Mask, Edge Scattering, Opacity Mask. Normal maps get converted to bump (slow, non-trivial). Convert to node-based NG Materials.
- PREVIEW PANEL: compact/extended; tiled/non-tiled stencils (SM always tiled); full-screen preview; lock texture scale to object; centre; flip; Paint; Edit image (E stroke mode, CTRL erase); Distort / Clear / Save / Load distortion; Rotate/Move/Scale/Aspect (RMB resets); projection preview modes; preview opacity; "Stencil transform with the nav bar". Stencil modes: Modulate, Keep volume (may not work in voxel), Invert.
- DATA: materials mix via depth (summary depth -> normal map).
- CAVEATS: matching preview needs ~8k source; closing Material Preview window is "semi-permanent"; RGB cavity default since 2021.53 (Edit > Preferences > Tools; Texture > Calculate Curvature).

---
## 42. Painting Modes
URL: https://3dcoat.com/documentation/manual/workspaces-rooms/paint/texture-painting-and-modes/
- MODES: Per Pixel (own UV or auto UV), Micro-Vertex (Displacement), Ptex, Vertex (Polypainting), Volumetric (voxel). "Each with its own positive and negative sides" (unspecified).
- PERFORMANCE: textures loaded uncompressed into RAM: 6k (6144x6144) RGB 8-bit ~108 MB per layer.

---
## 43. Multi Level Resolution
URL: https://3dcoat.com/documentation/manual/workspaces-rooms/sculpt/surface-mode/multi-level-resolution/
- FEATURES: Surface mode only; toolbar UP/DOWN buttons (UP at top adds subdivision level); panel via Windows > Panels. Add Bottom Level (2x decimation); Add Top Level (Loop Subdivision); Add Lowest Level from Retopo room; Res-/Res+; Current level; Bottom/Top; Remove Multi-Resolution (to change topology).
- WORKFLOW: detail at highest -> deform at lowest -> back up, details kept. Apply to current/selected/all visible objects; retopo lowest-level objects share volume name (posing large scenes).
- CAVEATS: overly low-poly base -> linear interpolation sharp edges; Loop subdivision triangulates n-gons; legacy Proxy mode in Preferences > Tools (off).

---
## 44. Transform tools
URL: https://3dcoat.com/documentation/manual/workspaces-rooms/sculpt/transform-tools/
- TOOLS: Transform (gizmo, numeric params); Instancer (near-zero memory references; edits affect all copies); Move (LMB drag moves surface in cursor relative to screen; CTRL = along normal; alpha-dependent); Pose (videos; Ring selection mode -> drag along length then rotate gizmo for twists); Fit (mark corresponding features, stitches objects); Reproject (details + vertex paint from meshes onto another; whole or brush-local); Surface Array (place poly/volume objects on surface or selected low-poly faces; surface via Loft/Strip/Polygon splines; Shift on end spline point = plane constraint); Bend (Preview Immediately, radius, max angle, method; voxelize first; "Update volume"); Twist; Warp; Array (Linear, Circular, Axial, Along Spline, Rectangular; Instance option).
- GIZMO: Position XYZ (X resets to 0,0,0); Rotate screen-space or per-axis; Reset Axis; Align to view; Apply.
- HOTKEYS: LMB drag; CTRL+drag; X reset; ALT+click ghost icon = ghost parent; RMB over curve = curve menu ("Bend volume").

---
## 45. Right-Click Menu (Sculpt Tree, voxel)
URL: https://3dcoat.com/documentation/manual/workspaces-rooms/sculpt/voxel-right-click-menu/
- VISIBILITY: Reference Colors (colour tag); Settings (density/polycount by name); Show All Hidden Volumes; Show Hidden in SubTree.
- LAYER: Delete, Add Child, Rename ("Volume XXX" default).
- TRANSFORM/DENSITY: Decrease/Increase object 2X; To global space; To uniform space; Resample (exact polycount); Radial Array (Instance option -> VoxTree instances); Transform; Snap to Ground; Lay On Ground (physically stable); Flip.
- GEOMETRY: Extrude; Extract Shell (voxel slow/robust vs Thicken Using Surface fast/artifacts); Fill voids (needed for clean topology); Close Invisible Hulls; Thicken / Close Holes / Separate Disconnected Pieces (Objectify) (Surface only).
- IO: Save volume (+subtree) to 3B; Import 3D File; Edit shader settings; Import Point Cloud (small spheres); Import object; Export scene / selected; Save to Meshes Panel / Splines Panel; Decimate > Auto-UV Map > Export.
- RETOPO/CLONE: Autopo (GUUV or other unwrapper; guides, density, hard edges); Retopo via decimation (works w/ Live Booleans); Clone (instance / with symmetry / degrade (half detail) / space density (for Copy tool)); Bake color from Visible Volumes (leaves layer in Surface).
- MERGE (voxel): Merge Visible; Merge subtree (merge children into parent, delete them); Merge selected; Pick Icon (pick destination in viewport); Copy & Merge With (Shift+LMB drag in tree); Merge with (move to) (drag-drop; drop on + = into subtree; Alt+drag = duplicate). Surface mode has "(no booleans)" variants.
- BOOLEANS: Soft Booleans settings (Surface; bevel radius, shape flat/rounded, divisions, relaxation; supported for cut, split, clone, primitives; any voxel op converts mesh to Surface); Copy & Subtract from; Subtract from (Ctrl+LMB drag in VoxTree); Intersect with (Ctrl+Shift+LMB drag); Remove intersection with (extra shell width for print gaps; RMB sets width); Split with (Shift+Alt+LMB drag); Change parent; Create Intersection Curve.
- UX PATTERN: drag-and-drop in tree with modifier keys = boolean operation type (Shift merge, Ctrl subtract, Ctrl+Shift intersect, Shift+Alt split, Alt duplicate).

---
## 46. Geometry menu (Sculpt)
URL: https://3dcoat.com/documentation/manual/workspaces-rooms/sculpt/geometry-submenu/
- FOUNDATIONAL: Show statistics (volume, area, dimensions, hole count); Define measurement units (voxel density per axis); Edit scene scale (-> Edit > Scene Scale Master in 2024); Res+ (doubles voxel count; resolution prefix in tree); Resample; Screen Space Subdivide (triangles ~N pixels on screen); Symm copy; Retopo mesh to Sculpt mesh; Paint Mesh -> Sculpt (no colour/subdiv | with PBR+subdiv | to Import tool).
- AUTOPO submenu (4 modes). Unghost.
- SURFACE COMMANDS: Shell; Clean Surface; Close holes (scans); Weld Vertices; Decimate; Cleanup Memory; Remove Self Intersections Parts (to own layer); Separate Disconnected Parts.
- BASIC: Clear; Smooth all; Unhide all; Invert hidden; Delete hidden; Separate Hidden Volumes (always bevels, uncontrollable; use Split to avoid); Visibility/Ghosting: Isolate (= ALT+LMB on layer), Toggle Visibility, Isolate/Toggle Ghosting, Invert Volumes Visibility (removes original ghosting).
- ADVANCED (Caching/Proxy, legacy; enable in Preferences > Tools): cache high-res, leave low-res proxy (2x/4x/8x); edits carried back, details preserved; Proxy Slider panel (Decimate voxel / Reduce surface); Toggle proxy mode; Cache/Uncache visible (redundant); Clear all caches (NOT undoable); Highlight; Contour selection params; Render selection Contour.
- PERFORMANCE: Cast shadows (cosmetic); Incremental render (re-render changed parts only; auto off with shadows); Accurate smoothing (cost); Stroke expansion (Grow on pen motion).
- PAIN POINTS: redundant commands; few hotkeys documented.

---
## 47. Clay Engine
URL: https://3dcoat.com/documentation/manual/workspaces-rooms/sculpt/voxel-mode/clay-engine/
- FEATURES: Voxel/Surface Hybrid engine brushes, interchangeable in voxel room. Brushes: Base Clay (basic; duplicate+rename to customise; alpha via "Use current alpha" in Brush parameters > Modifiers); Wet Clay (clay + slight smudge); Vox Smart Pinch; Vox Pinch; Vox Flatten; Thick Layer (no buildup); Vox Extrude; Vox Buildup; Voxel Skin (mixed +/- alphas; needs "Surface-like mode"); Usual Clay, Trim Smooth Border, Soft Clay.
- COMPARISON: Vox Clay thick/firm (pure voxel, large volumes, merging); Base Clay moderate (general); Wet Clay muddy/slick (soft transitions, fill crevices).
- ALPHAS: +/- mixed EXR; "Open texture, make round falloff".
- BEST PRACTICE: duplicate built-in brush to create custom.

---
## 48. Commands for Sculpt room
URL: https://3dcoat.com/documentation/manual/workspaces-rooms/sculpt/commands-for-sculpt-room/
- COMMANDS: Res+ (only when current res can't add detail); Increase resolution (doubles); Resample (dialog); Clear (keep name+res); Smooth all (Tangent smoothing option; "Skip this dialog", restore via Preferences > Tools; some options Surface only); Edges relax (open edges; Surface only); Multiresolution UP/DOWN (Surface only); StemCell (2025: one-click validate/correct vs TurboSquid guidelines).

---
## 49. Scripting & Core API
URL: https://3dcoat.com/documentation/manual/scripting-and-core-api/
- LANGUAGES: AngelScript (original, C++-like; DEPRECATED, doesn't work on Apple Silicon); Python (embedded, no setup; "standard for CG industry"; trigger UI commands, operate on scene, create tools; ~1:1 with C++ Core API names; slower -> general management); C++ Core API (compiled C++17, native speed, multithreaded; Visual Studio only; supports coloured voxels; write .cpp in VS, open in 3DCoat which runs it).
- RUN: Scripts > Run Script; Scripts > Create the Python Script / Create a new Core API script. Script recorder: RMB+MMB over a function records/copies its command text.
- BEST PRACTICES: study examples (simple -> complex); OptForm command reference; Notepad++ C syntax.
- CAVEATS: old Python scripts work except rooms; docs/video tutorials "a little later".
- Links: pilgway.com/files/3dcoat/PythonAPI, /CoreAPI, /scriptdocs.

---
## 50. Core API
URL: https://3dcoat.com/documentation/manual/scripting-and-core-api/core-api/
- FEATURES: compiled C++ extensions ("not scripting"); transparent VS 2022 Community build with wizard; 3DCoat installs VS if missing. Scripts > Create new Core API script (templates; "Minimal c++ program"); don't create project manually. Script menu item click = execute; RMB = edit/build/rebuild; create distributable for sharing; debugger shows native types nicely; self-test prevents failed builds.
- CLI: 3DCoat.exe -script "path to cpp/python script"; coat::utils::quit() / coat.utils.quit() for headless batch.
- Live booleans accessible via Python and Core API.

---
## 51. Python API
URL: https://3dcoat.com/documentation/manual/scripting-and-core-api/python-api/
- MODULES/CLASSES: coat.io, coat.dialog, coat.Mesh, coat.Scene (roots), coat.SceneElement, coat.Volume, coat.ui, coat.vec2/3/4, coat.mat3/4, coat.symm.
- WORKFLOW: Scripts > Create Python Script (template; opens in associated editor); requirements.txt in script folder auto-installs modules; Scripts > Install Python Modules; VS Code recommended with coat.pyi hints; Extensions > Show Python Console = only debugging method currently.
- CAVEAT: Python moved to ProgramData on Windows; slower than C++.

---
## 52. Introduction to 3DCoat
URL: https://3dcoat.com/documentation/manual/introduction-to-3dcoat/
- FEATURES: unified pipeline from "block of digital clay" to textured production model: sculpt, retopo, UV, PBR paint, low-poly modeling, render. Imported models convertible to voxel or surface objects.
- 2026 (July 2026): GPU node system for non-destructive texturing; procedural library ~30 material channels; line splitter, smart hybrid primitives, hollow box primitives (3D print), revamped Group Tree; lofted surfaces for voxel sculpting; HYBRID MESH (retopo meshes as sculpting surfaces); parametric hybrid modeling; 3D lattice voxel structures; texturing while sculpting; QUICK ACCESS SEARCH; node transform gizmo; pose tool deformation modes; bevel Profile Shape; UDIM, GLB/GLBC export, LWO3.
- VOXEL CLAIMS: no topological constraints; voxel->surface skin "mostly quad-based"; booleans with crisp edges; adaptive dynamic tessellation.
- TEXTURING: MicroVertex, Per Pixel, Ptex, Polypaint; real-time PBR + HDRI; up to 16K textures; fast AO/curvature; texture-by-UV GPU blending.
- RETOPO: AUTOPO with edge loops; decimation retopo; Instant Meshes; retopo groups with colour palettes. UV: ABF, LSCM, planar, Global Uniform (GU); checker views; UDIM.
- RENDER: PBR, SSR, DOF, render passes, RenderMan, node editor for env/post.
- Concept art fit: voxels = less technical concern. Recordable scripts (primitive actions).
- LICENSING: hardware-independent serial but one running copy at a time; simultaneous instances can disable serial; uninstall unused licenses (Help menu).

---
## 53. Workspaces Rooms (overview)
URL: https://3dcoat.com/documentation/manual/workspaces-rooms/
- CONCEPT: rooms = separate but connected "mini-applications" to focus on one operation at a time. Paint (textures; Photoshop-familiar); UV (extension of Paint, auto-synced; Retopo & UV = pre/post-process of UV work); Retopo (low-poly over sculpt); Modeling (low-poly without sculpt mesh, different tools); Sculpt (quick overall forms, organic); Render (3D->2D). Sidebar: Factures, Simplest, Kitbash, 3DPrint, Photogrammetry, Nurbs, Nodes.
- PAIN POINT: page doesn't explain how data moves between rooms or how to switch rooms (implicit model, learned elsewhere).

---
## 54. Modeling (room)
URL: https://3dcoat.com/documentation/manual/workspaces-rooms/modeling/
- FEATURES: poly/edge/vertex editing for hard-surface & low-poly; extends Retopo toolset; surface snapping OFF by default; models exist in Retopo room too. Booleans "not yet covered".
- WORKFLOW: Primitives -> SELECT tool (tools depend on selection mode verts/edges/faces) -> block out low-poly -> subdivided sculpt mesh -> Sculpt room detail.
- DYNAMIC SUBDIVISION: Mesh menu > Sculpt Mesh (live subdivided preview with cage visible; Modeling + Retopo); Unlink Sculpt Mesh; Opacity lowers cage; Convert to Sculpt Mesh or Import > Pick From Retopo; Subdivide/flat subdivision before import; Estimated Poly shows density.
- CAVEAT: symmetry looks applied in viewport but not in geometry (Mesh-Virtual Mirror Mode) -> Symmetry Copy from Polygroups required; live subdivision can look asymmetric.
- BACKGROUND: voxels = polygon approximation of volume; voxels for blocking/organic/booleans; surface for detail/sharp edges; Auto-Subdivide in surface brushes adds local detail. Community: block in voxels, then Surface.

---
## 55. Render (room)
URL: https://3dcoat.com/documentation/manual/workspaces-rooms/render/
- FEATURES: internal renderer: PBR, HDR lighting, SSR and lights, RenderMan support, multiple coloured lights, render passes, DOF, ray count, real-time render (lighting, focus, AO), GI. Turntable/Flyby animations (CW/CCW), any resolution, up to 32-bit, alpha optional; upload to YouTube/Vimeo; screenshots to Pilgway servers (Help menu).
- CAVEATS: realtime render greyed out due to StemCell Certification feature (disable in Render settings); RenderMan WIP (4.8).

---
## 56. Simplest (room)
URL: https://3dcoat.com/documentation/manual/workspaces-rooms/simplest/
- PURPOSE: beginner/blocking room: "complex shapes are combinations of simple shapes" (primary/secondary/tertiary shapes).
- TOOLS: Objects: Primitives, Import, Curves, Text (along spline or voxel text), Logo, Constructor, Sketch, Snake, Spikes, Muscle, Cloth. Adjust: Cut Off, Measure (LMB drag), Pose, Move, Transform, Warp, Axial (radial duplicates), Bas-Relief. Commands: Res+, Resample, Clear, Smooth All.
- UX NOTE: curated reduced-toolset room as on-ramp (vs full Sculpt room).

---
## 57. Different Forms of "Resolution"
URL: https://3dcoat.com/documentation/manual/getting-started/different-forms-of-resolution/
- CONCEPTS: Perceived (texture maps illusion; games), Actual (true voxel/surface mesh resolution; CAD/CAM/print), Viewport (Paint room real-time subdivision, temporary), Export (retopo mesh + maps). Voxels and "Surface Skins" closest to prototype's actual resolution.

---
## 58. System requirements
URL: https://3dcoat.com/documentation/manual/getting-started/system-requirements/
- Content only in images; no text extractable. (Recorded as fetched, no data.)

---
## 59. Questions & Answers (FAQ)
URL: https://3dcoat.com/documentation/faq/
- STARTUP/CRASH: causes = missing video drivers, cloud-sync folders (OneDrive/Google Drive) over Documents, rights, antivirus, tablet driver changes, corrupted prefs, disk errors. Fix: delete Options XML or rename 3DCoat user folder. "Fatal Error / Out of memory" at startup often a damaged texture -> rename folder, copy assets back one by one. Automated bug report (no scene data).
- SAVING: saves run in background, 10-30 s after appearing finished; reboot in that window can destroy scene; enable autosave 5-10 min.
- PERFORMANCE: VRAM limits max editable texture size (8 bytes/pixel; >=4 GB recommended); multiple GPUs unnecessary; OpenGL only since 2021; CUDA discontinued 2022; painting over few large UV faces slower than subdivided faces -> divide big faces. Windows 64-bit only (32-bit dropped).
- VOXEL vs SURFACE: colour preserved when switching; booleans and resampling preserve vertex colour (re-projected). "View/Show Voxels in paint room" on by default (disable for per-pixel etc). Depth (image-based, vector displacement, real-time normal map) vs Sculpt (mesh-based; normal map needs Texture Baking Tool).
- PEN: pressure not respected on 64-bit Windows -> specific Wacom driver version (outdated advice).
- UI: Edit > Preferences > Show hints; Retopo "Show mirrored".
- NAVIGATION: pivot dynamic, defaults to pick point on model; F sets manually; pivot modes in Camera menu; move objects w/o camera via Select/Move.
- HOTKEYS: F pivot; Shift first then draw = smooth; LMB first then Shift = straight line (Photoshop-like).
- Undo not covered.

---
## 60. Training Tutorials
URL: https://3dcoat.com/documentation/training-tutorials/
- CONTENT: catalogue of YouTube series: General (UI overview, mesh types, intro series by Anton Tenitsky, Quick Start series), Sculpting (voxel/surface brushes, multires, hard surface, speed sculpts), Retopo (quick start, autopo, manual, baking), Painting (Smart Materials, PBR), Modeling/UV (low-poly for beginners, AutoMap), Workflows (Blender, CAD, Plasticity, Textura, Print), concept art/timelapses.
- PAIN POINTS: no official beginner/advanced order; many videos from older versions (2012/2021/2022) with differing UI; one placeholder example.com link; 23-minute "reading" page.
- BEGINNER PATH (by titles): UI Overview, Understanding Mesh Types, Quick Start series, Low-Poly for Beginners, Quick Start Paint/UV/Retopo.

---
## 61. Library: Sculpt
URL: https://3dcoat.com/documentation/library/sculpt/
- Sculpt room two modes: Voxel = volumetric clay grid, not hollow shell; blocking/sketching/silhouettes; pull/stretch/merge/cut without polygon stretching/tearing. Surface = polygon mesh; pores, wrinkles, scratches, local edits. Video list (voxel/surface brushes, live booleans, multires, asset panels, spline arrays).

---
## 62. Licensing (Pilgway)
URL: https://pilgway.com/licensing
- TYPES: Individual (3DCoat / 3DCoatTextura); Company Node-Locked, Floating, Subscription; Rent-to-own 3DCoat (11 or 7 monthly payments of 41.6 / 62.4 EUR -> permanent); Rent-to-own Textura (9 x 21.6 EUR); Academic (schools; students, Textura for 1 EUR).
- UPGRADES: permanent license includes 12 months free updates; Textura->3DCoat upgrades; V4->202X; node-locked->floating; volume discounts.
- TIERS: 3DCoat full; 3DCoatTextura (texturing + rendering, unlimited free learning use); 3DCoatPrint (free, voxel modeling, export max 40K triangles, smoothed for print).

---
## 63. Quick Start Menu (opening dialog)
URL: https://3dcoat.com/documentation/manual/navigation/opening-dialog-menu/
- FEATURES: launch dialog "tries to anticipate what you want to do"; Shift+M reopens; context-sensitive. Learning: PBR library, website, YouTube, AI Assistant (Q&A, not 3D generation; beta), Quick Start interactive tutorials + training missions (splash screen), Updates manager (delta download; versions side-by-side in 3DCoat-202# folders), Themes.
- START OPTIONS (task-first entry): Voxel Sculpting (default shapes or voxelize OBJ at resolution set by resizing preview with gizmo); Surface Sculpting (base mesh, Live-Clay; tiled box scene); Vertex Painting (no UVs); Photogrammetry; Repair Scanned Mesh (voxels/shell/surface/bas-relief); Import Image as Mesh (incl. heightmap landscape); Paint UV Mapped Mesh (Per-Pixel; low-poly game assets); Paint With Ptex; Paint with Deep Displacement (Micro-vertex; View > Show Displaced Mesh); Perform Retopology; Poly Modelling; KitBash; Modeling for 3D-printing (Z-up); UV Map Mesh; Product Prototyping (CNC, moulding, lasercut: heightmaps, remove undercuts, close holes); StemCell certification; Open Recent.
- CAVEATS: Ptex impractical to edit in 2D apps; retopo work permanent only when baked into Paint; StemCell stops on discrepancies and must restart from beginning.
- BEGINNER: Quick Start tutorials + training missions.

---
## 64. Color management
URL: https://3dcoat.com/documentation/manual/color-management/
- FACTS: page admits 3DCoat "lacks a dedicated, robust color management system" vs Blender/Maya; author says it "could have errors". Uses monitor/device colour profile (wrong profile -> wrong colours); set monitor to sRGB; import/export sRGB; 32-bit linear EXR export; exported textures untagged RGB.
- OCIO native (Edit > Preferences > Viewport); ACES tone mapping viewport-only (not baked). Gamma: viewport RGB in Preferences; per-layer Textures > Adjustments > Gamma Correction.
- WORKFLOW: Ctrl+P sends current layer to Photoshop, live update on save. B = colour picker popup; Color Operations brush (HSB); view PBR channels separately; Flat Shade mode.
- Windows: Automatic Color Management can interfere with ICC; colorimeter recommended.

---
## 65. Free 3DCoatPrint
URL: https://3dcoat.com/documentation/manual/3dcoat-print/
- FEATURES: free simplified 3DCoat for 3D printing/beginners; voxel "digital clay" (cut/add/merge without topology); all sculpt tools + renderer; Sketch tool (2D front/top/side -> voxels); texturing/gamedev tools removed; DICOM import (not medical); STL/WRL export.
- LIMITS: export smoothing + max 40,000 triangles (only limits, at export).
- WORKFLOW: start with primitives, add complexity.
- CAVEAT: page contradicts itself on commercial use.
- UX NOTE: free tier = same sculpt core with curated UI (product-level "simplified mode").

---
## 66. Node System
URL: https://3dcoat.com/documentation/manual/nodesystem/
- FEATURES: non-destructive procedural engine for materials, masks, geometry deformers, VFX; graph compiled to GPU shaders via NGL (NodeGraph Language); resolution-independent; adapts to curvature/AO/surface space. Node Editor; Node & Object Inspectors (expose curves, colour pickers, sliders). Output to PBM channels (Albedo, Gloss, Metalness).
- NODE CATEGORIES: Color, GeometryIn, In, Layer, Material, Math, Noise, Noise3D, Out, Pattern, Pattern3D, Shape, Texture, Tilable, UV.
- PRESETS: NGMasks, NGMaterials, NGModifiers (geometry deformers/displacement), NGFilters (post filters on layers), NGVolumes (3D volumetric textures ignoring UV seams).

---
## 67. GPU Texturing
URL: https://3dcoat.com/documentation/manual/texturing/
- FEATURES: PBR; paint directly on 3D model. Per-Pixel (standard, fast, high-res), Microvertex (depth on tessellated mesh without UVs, bake later), PTex (per-face, film). Channels Albedo, Depth, Glossiness, Metalness painted in one stroke. Smart Materials adapt to cavity/edges; classic (raster + math masks) vs node-based (procedural, resolution-independent, "never pixelate"). Layers hold Color/Depth/Gloss/Metal; blend modes; masks; clipping; groups. Stencils: screen projection, spline strokes, alphas. Export presets Unreal, Unity, Blender, Maya, V-Ray (auto channel packing).
- CAVEATS: no performance data; some links point to local developer paths.

---
## 68. Library: Retopology
URL: https://3dcoat.com/documentation/library/retopology/
- Retopo converts dense sculpts into "clean, lightweight, animation-ready" meshes; between high-poly and texturing; manual or automatic. Video list: auto retopo with guides, relax, duplicating retopo mesh, strokes tool, Instant Meshes, hard-surface autoretopo, UV edge tools.

---
## 69. Top Bar (Sculpt)
URL: https://3dcoat.com/documentation/manual/workspaces-rooms/sculpt/top-bar/
- CONTROLS: Conform Retopo Mesh (snaps retopo verts to sculpt; with Move brush / Retopo Relax; may cause temporary FPS drops - computes at end of each stroke); On Plane (set plane: click-hold RMB, drag over voxel surface; Type of Surface; "Lofted Surface" offset/extend); RMB Action (quick RMB = RMB menu; long = pick point+plane; hold RMB slides; CTRL along normal; modes Pick Point&Forward (faces camera), Point Only, Point&Direction avg, local, Perpendicular to surface, Navigate (or hold ALT)); Steady Stroke (paint point trails cursor; simpler than Lazy Mouse which has Radius & Step); Invert Tool (= CTRL); Radius (+ radius lock wrench, pressure curve); Taper Modifier; Depth (+ lock); Focal Shift (Preferences); Falloff curve; Smoothing; paint: Opacity, Glossiness Intensity, Roughness, Metalness; Conditions limiter; Pen/Mouse/Size-lock/Depth-lock icons (LMB toggles).
- HOTKEYS: SHIFT+G isolate ghosting (unghost all); CTRL invert / plane along normal; ALT navigate.
- UX NOTE: overloaded RMB (short click vs long click vs hold have different meanings).

---
## 70. Sculpt Brush options
URL: https://3dcoat.com/documentation/manual/workspaces-rooms/sculpt/sculpt-brush-options/
- Same as Paint room brush options: Brush rotation; Zero pressure radius (stylus); Depth modulator; Rotation amplitude; Radius/Depth variation %; Opacity/Hue/Brightness/Saturation jitter; Jitter; Vary color each stroke; Random flip; Paint with dabs + Use spacing; Rotate along stroke (bristles); Skip eraser; Strict alpha; Flattened stroke (Photoshop-like overlap with truncated alpha); Fade on edge.

---
## 71. Pose tool
URL: https://3dcoat.com/documentation/manual/workspaces-rooms/sculpt/transform-tools/pose/
- FEATURES: rotate/scale/translate selection; works on all visible objects through all volumes; respects symmetry + all E-panel selection modes; Soft Selection. Options: Freeze/Pose opacity; Connective (topological) painting vs volumetric sphere; Pose Action Move by Gizmo / Normal Extrude.
- SELECTION MODES: Line, Ring, Sphere gradients (LMB press->release); Paint (brush selection; Shift+LMB smooth; CTRL subtract; E-panel lasso/rect; Airbrush soft selection via "Select with a pen"); Select Object (click in Sculpt Tree).
- SELECTION TOOLS: Snap to angle; Invert; Clear; Edit Pose falloff; Save/Load Selection to file (Surface recommended; voxelization breaks restore); Smooth Selection (5x/10x); Store selection to Layer; Pick selection from Layer; Current layer > Selection (SHIFT add/CTRL subtract); Polygroup layer from pose selection.
- GIZMO: line-based default; regular gizmo with Rotate/Scale/Translate states (click red bar); QWER via Preferences > Tools "Use QWER"; Hide Gizmo; Adjust Transition Area; Shift = move gizmo only; Apply Transform to Gizmo; Position; Pick Pivot (Position Only / Normal&Position / View Direction&Position); Reset Axis, Align to View, To Main Axis, To Center Mass.
- FREE FORM LATTICE: Use Free Form; lattice shapes; divisions XYZ; interpolation Method; Transform/Lattice toggle; symmetry; Auto Fit; Dense Conform; Auto Conform Mesh.
- DATA: selection <-> layer opacity <-> freeze are interconvertible masks.

---
## 72. Hide menu
URL: https://3dcoat.com/documentation/manual/interface-and-navigation/hide-menu/
- COMMANDS: Activate Hide Tool; Hide/Unhide Painting Object; Hide/Unhide Surface Material; Unhide All; Hide Frozen Area; Invert Hidden Faces; Delete Hidden Faces Permanently (NOT undoable); Expand/Contract Hidden Area; Store/Restore Hidden State.
- HOTKEYS: CTRL+NUMPAD+ expand; CTRL+NUMPAD- contract (note: conflicts with Freeze hotkey listing which uses same combos; hotkeys page lists NUM+/NUM- without Ctrl).

---
## 73. Windows Panels (tabbed/popup)
URL: https://3dcoat.com/documentation/manual/interface-and-navigation/windows-menu/tabbed-windows-popup-panels/
- BEHAVIOUR: hide/show, dock/undock/float; drag title bar, drop on highlighted preview; restore from Window menu; Store/Restore This Page Layout to file.
- POPUP HOTKEYS: Color Palette (assignable); Q curves quick menu; V pick depth; ~ Quick Panel (pinnable); E Stroke Mode; SPACE Tools palette; CTRL-F Search in UI (find + run any UI item in room); Multiresolution via Space bottom line or Windows > Popups.
- PANELS: Brush Options, Brushes, Stencils, Strips, Stroke Mode, Presets, Tool Options, Tool Presets; Color Channel, Palettes/Swatches, channels, Quick Panel; Paint Layers Blending, Layers, Mask, Painting Objects, Surface Materials, Materials, Material History, Transforms, Symmetry; Node Editor/Inspector/Object Inspector, Filters, Shaders; Polygroups, Poly Models, Sculpt Tree, Sculpt Models, Primitive History, Projector, Joints, Split & Joints, Splines, Shapes; Smart Materials, Environment map, VerTexture, UV Preview, Volumes; Curves Tree, Extensions, FPS_Monitor, Multi-Resolution, Search in UI, Start Menu.
- CAVEATS: Proxy Slider deprecated -> Multi-Resolution; Split & Joints Surface only; picking depth with brush <0.2 gives "insane numbers"; RMB swatch = X to disable.

---
## 74. Pure Voxel Sculpting (What are Voxels)
URL: https://3dcoat.com/documentation/manual/workspaces-rooms/sculpt/voxel-mode/pure-voxel-sculpting/
- DATA STRUCTURE: virtual 3D grid; each voxel value 0..1, SURFACE AT ISOVALUE 0.5 (i.e. a density/implicit field); voxels can carry colour and a shader; high resolution gives smooth curves.
- WORKFLOW: start empty or from volume; add/subtract like clay/wax/wood/stone; sculpt the form directly, no preset topology; Move/Grow add/remove volume; export to 3D print via wizard (solid like CAD).
- ADVANTAGES: no polygon subdivision; solid not hollow; no topological constraints, punch holes easily; print-friendly.
- LIMITS: surface can't be too thin; thin areas show 3D "jaggies" -> raise resolution or switch layer to Surface ([V] -> [S]).

---
## 75. Surface tools on Voxels
URL: https://3dcoat.com/documentation/manual/workspaces-rooms/sculpt/voxel-mode/surface-tools-on-voxels/
- FEATURES: abbreviated Surface tool set in Voxel room ("much faster than volume sculpting") + Pose/Move/Transform: Clay, Clay Fast, Draw, Flatten, Lute, Trim Adaptive, Flat Polish, Rapid Smooth, Smart/Roof Pinch, Chisel, Fill, Buildup, Extrude, Expand, Absolute, Rapid, Scratches/2, Mud/2, Pinch, Shift; smoothing variants (Smooth, Powerful Smoothing (local decimation+refinement), Relax, Relax Standard, Tangent Smoothing, Smooth Concave/Convex, Sharpen, Super Relax); Reduce/Decimate/Reconstruct; Add Detail (subdivide under brush); Retopo Relax; Freeze/Un-freeze/Surface Hide; Copy Clay; Snake Clay, Painting, Eraser, TGL_Pinch.
- HOW IT WORKS (hybrid model): surface brush on a [V] layer pauses volumetric updating; edits the adaptive skin wrapping the voxel volume; switching back to voxel brush/volumetric op restores voxel behaviour; ENTER applies and transforms surface back to voxels.
- CAVEATS: polygon stretching -> press ENTER; voxels don't support layers; freeze mask painted with surface tools LOST when switching back to voxel tool; VoxHide recommended for voxel masking.
- HOTKEYS: Draw LMB/CTRL+LMB/SHIFT+LMB; CTRL inverts Chisel/Fill/Pinch; CTRL+D clear freeze/unhide; CTRL+SHIFT+I invert; hold F = sticky Freeze tool.

---
## 76. Surface Layer
URL: https://3dcoat.com/documentation/manual/workspaces-rooms/sculpt/surface-mode/surface-layer/
- DATA: [S] layer; same layer panel as Paint: colour, gloss/roughness, metalness, depth; all deformation stored continuously in depth channel (no record toggle).
- TOOLS: hide/unhide sculpt layer = morph target switch (ZBrush analogue); Depth Opacity = morph intensity; Magnify SL brush (feather/blend layer depth; ~ZBrush Morph brush); Erase SL.

---
## 77. Left tool panel
URL: https://3dcoat.com/documentation/manual/navigation/left-tool-panel/
- Context-sensitive tool/brush list per room. Spacebar opens Voxel/Tool panel menu around cursor. Hide via Edit > Preferences "Hide Left Tool Panel" (then use space menu or custom presets on right side).

---
## 78. Navigation using 3DConnexion devices
URL: https://3dcoat.com/documentation/manual/navigation/navigation-using-3dconnexion-devices/
- Full 3DConnexion support; recommends Space Mouse Enterprise/Pro; settings split between 3DConnexion panel and Edit > Preferences > 3D Mouse; legacy mode not advised; buttons assignable to any menu item/tool via [>]; Lock horizon in 3DConnexion Advanced settings. spacenavd guide for Linux.

---
## 79. Voxel Adjust
URL: https://3dcoat.com/documentation/manual/workspaces-rooms/sculpt/voxel-mode/voxel-adjustment-tools/
- TOOLS: Cut Off (polygon/spline cut through volume; edge radius preset or hold R + move mouse; On Plane in perspective; Type of Surface; soft voxel booleans for cut/split/clone/primitives); Splitter (draw open line; cut thickness gap; Auto split volumes (slow, many objects); Turn voxels into surface (inexact); Just create splitter mesh); Measure (LMB drag); 3D Print Supports; Vox Slice (slice view; scans/holes); Quick Pick (click object -> select VoxTree layer); Fit; Reproject; Hide (LMB hide, CTRL+LMB unhide; new Sculpt Object from hidden parts; used as voxel MASK instead of Freeze which only works in Surface); Cell Hide (8x8x8 cell blocks, much faster, no sculpting/separating); Copy (merged sum of layers -> current layer w/ spherical brush; armor/clothing from body); Bas-relief (coins/jewelry); Undercuts (molding/CNC; Apply/Enter); Moulding (extra module).
- PAIN POINT: voxel masking uses Hide not Freeze (mask concept differs per mode).

---
## 80. Surface adjust tools
URL: https://3dcoat.com/documentation/manual/workspaces-rooms/sculpt/surface-mode/surface-adjust-tools/
- TOOLS: Sculpt Bevel (bevel along curves; per-point radius; "Bevel radius scale"; "Make bevel over curves"; no topology change -> Subdivide edge if low detail; baked to current layer); Cut Off (DEPTH LIMIT; Soft Booleans; hold Shift = cut outside selection); Noise (procedural on layer/mask); Close Hole; Reconstruct (local rebuild); Mesh Doctor (auto repair/step through errors); Clean Clay; Fill Holes; Poly Remove (paint mask -> delete polys); Angulator (sharpen within frozen selection); Dissolve ("infinite smoothing"; Preserve surface); Subdivide (Loop; frozen/non-frozen/entire); Measure (click points; Shift align; Esc stop; Ctrl no snap; double-click erase; guides as snapping markers; relative measurement "Set as unit", subdivision ticks); 3D Print Supports; Vox Slice; Extrude Faces; Bridge (two meshes); Quick Pick (H in any other tool); Bas-relief; Undercuts; Molding (auto/semi-manual; taper; 2023 handles ~70-100M polys, ~6 min for 50M).
- HOTKEYS: H quick pick; Shift (cut outside / align); Esc; Ctrl.

---
## 81. Primitives (Sculpt)
URL: https://3dcoat.com/documentation/manual/workspaces-rooms/sculpt/voxel-primitives-import-tools/
- FEATURES: build models from positive/negative primitive combinations; gizmo for orientation/distortion/scale/position + numeric fields; "Move only gizmo"; reset axes; custom primitives via + (obj/lwo/fbx -> Models/Splines panels; "More Primitives"); Sculpt Models panel for greebles/nurnies.
- FREE-FORM: lattice "Distortion Frame"; Transform as a whole; Local Symmetry; ResetPrim; EditPoints numeric per lattice point; inner/outer radius & thickness; alternate cages; Ctrl constrains along normal; Transform/Lattice toggle.
- CLICK TO PLACE: preview slides along surface normals; add or subtract each placement; RMB drag L/R = scale, U/D = penetration depth (same gesture grammar as brush size/depth).
- BOOLEAN MODES: Add, Subtract, Intersect, Split (into new VoxTree layer); Soft Booleans (organic seamless joins).
- SCRIPT RECORD: record icon -> UserPrefs/Scripts; script history.
- Primitives panel "limited" vs Import panel "more flexible".

---
## 82. Import to Sculpt Room
URL: https://3dcoat.com/documentation/manual/workspaces-rooms/sculpt/import-to-sculpt-room/
- SETTINGS: Import to Separate Instances (new VoxTree layer); Import w/o Voxelization (keep surface); Import as Child; Respect Negative Volumes (objects named "_negative" subtract); Cut Through Volumes; Import w/ Thickness; Subdivide; Close Mesh; Pick From Retopo; Shift XYZ; Merge Separate Volumes; Presets; Flat Subdivision (no smoothing).
- WORKFLOW: voxel resolution depends on import scale set via gizmo or numeric; Enter makes permanent. Click to place composites.
- CAVEATS: mesh should be closed for voxelization; low-poly imports problematic esp. Surface; DICOM not for medical.

---
## 83. Extensions and Addons
URL: https://3dcoat.com/documentation/manual/scripting-and-core-api/extensions-and-addons/
- MODEL (2024+): custom scripts, shaders, tools, content packages; Core API or Python; stored UserPrefs/Scripts/cExtension; Addons menu mirrors UserPrefs/Addons/ folder (own submenus; redistributable). Windows > Panels > Extensions manager: Start button, auto-launch checkbox. .3dcpack packages (shaders, textures, alphas, smart materials, scripts). Some need internet on first launch for Python modules (red status-bar message if missing). Example: Mouse Test (GitHub 3dcarrots/3DCoat) - viewport mouse info + menu item. END on custom menu item assigns hotkey.

---
## 84. Surface custom tools
URL: https://3dcoat.com/documentation/manual/workspaces-rooms/sculpt/surface-mode/surface-custom-tools/
- Base Brush (duplicate via RMB, rename, customise); Stitches (from Strips panel; use Steady stroke); Add Brush. Tool Options: Brush Stroke, Misc Settings (buildup: non-buildup reaches height limit; buildup "grows infinitely (but slowly)"), Sampling, Modifiers (undocumented). Pain point: page promises "all the options" but has headings only.

---
## 85. Poly Groups (Retopo)
URL: https://3dcoat.com/documentation/manual/workspaces-rooms/retopology/poly-groups/
- DATA: multiple layers per retopo object (reorder, trash, double-click rename, visibility, grouping); multiple retopo objects each with own geometry (parts / alternative topology versions).
- BOTTOM BAR: Search by name, New Layer, Duplicate, Select (all faces of layer), Move (selected faces to current layer), Symmetrical Copy (symmetry on), Subdivide, Clear, Trash, Group.
- CAVEATS: back faces darker; can't "fix" single-sided polys; double-sided shares one UV (mirrored); for two-sided texturing use Shell or Flip Faces + second UV set.

---
## 86. Presets for Brush alphas
URL: https://3dcoat.com/documentation/manual/brush-components/presets/
- Presets = user brush modifications library; folder structure (drag between folders); duplicate any tool to keep originals; "Custom > BaseBrush" creates a new category of stacked tools; "Save presets to file" (backup if MyDocs/3DCoat config deleted); "Add Presets from File"; .3dcpack via Brushes "Add Brushes from Package"; File > Create extension to share.

---
## 87. Kitbash (room)
URL: https://3dcoat.com/documentation/manual/workspaces-rooms/kitbash/
- FEATURES: assemble scenes/hard-surface detail from pre-made parts (greebles); OBJ asset library with auto thumbnails; place/move/rotate/scale on primary model; negative volumes ("_negative", subtract mode); merge into voxel sculpt avoids topology issues.
- JOINTS: lego-like attachable parts (Retopo > Make joints or external per spec); axial symmetry, alignment, compatibility; publish to Joints palette (same name overwrites); fit 10x10x10 grid, Y up; <=5K polys; tubes 16 segments; "Shader_Gold" retopo group naming -> shader. Splines stretched with Curves/Snake.
- CAVEATS: kitbashes should be polygon meshes not dense sculpts (100 sculpts = gigabytes); multi-object drop combined into one file (offers decimation).

---
## 88. View menu
URL: https://3dcoat.com/documentation/manual/interface-and-navigation/view-menu/
- SHADING: GGX Burley 12 (UE4); GGX Lambert (Marmoset); Handpaint; Greyscale Panorama; Smooth Shade ("5"); Relief Only; Flat Shade; Gloss/Roughness only; Specular Color; Metalness.
- DISPLAY: Backface Culling (turn off to find single-sided polys); Wireframe; Correct Alpha Ordering (paint objects only; may slow); Linear Texture Filtering (off = point filtering for pixel art); Seams; Low-Poly (cage + normal map); Show Displacement mesh; Adjust Tessellation (GPU cost).
- GRID/SNAP: Show/Snap 3D Grid (most screen-facing grid; ortho recommended); Grid Placement ZX/XY/YZ/Auto; Grid Density + Customize Grid; Axis / Separate Axis; Show 2D Grid (Ctrl+'); Snap to 2D Grid; Snap to Low-Poly Vertices; measurement guides; Snap to Curve / Curve Points / Center; Setup Printing Area.
- OTHER: Orthographic Projection; Projector; Toggle Full Screen; Show Voxels in Paint Room.

---
## 89. Navigation (overview)
URL: https://3dcoat.com/documentation/manual/navigation/
- Restates 13-zone layout (see #2): Activity Bar hover-expand without disturbing layout; Statistics line counts; Tool Options Panel ("not all tools have parameters"). Three layer types: sculpt layers, paint layers (paint and sculpt), Curves layers. Menu sets switchable via status-bar drop-down/tabs.

---
## 90. Vector Displacement
URL: https://3dcoat.com/documentation/manual/workspaces-rooms/sculpt/vector-displacement/
- VDM = XYZ +/- offsets encoded RGB. "Preliminary (early stage)" support only in Surface Extruder tool. 3-channel 32-bit EXR = VDM; load into a Brushes folder; Surface mode > Extruder, paint or stamp. Pick & Paste creates VDM from raw surface (auto unwrap/flatten edge); export EXR; RMB alpha "save as VD" with flip X/Y.
- TIP: Tool Options subdivision for localized detail instead of res+.
- FUTURE (not current): VDM from any surface/model, voxel support, all brushes.

---
## 91. Layers menu
URL: https://3dcoat.com/documentation/manual/interface-and-navigation/layers-menu/
- COMMANDS: Layers panel; Layer Blending; New; Add Layer w/ Normal Map; Duplicate/Delete; Merge Visible; Merge Down/Up; Copy channels (source/dest layer+channel; Replace/Move/Blend/Add/Subtract; masks by name); Apply Layer Blending; Discard Clip Masked Pixels; Erase Unfrozen (channel toggles); Fill Entire Layer; Refill Material; Clamp Min. Depth (remove spikes); Clamp Layer Depth. Symmetrical Transform (Flip, Copy Blue<->Red; needs Topological Symmetry regions). Import/Export (PSD all layers colour, roughness, metalness, depth).
- BLENDING PANEL: Lock Texture; Lock Transparency; Weight Map; depth modes Add/Subtract/Max/Magnify/Suppress.
- DATA: layers are "a kind of scene layer"; voxel volumes and surface models support (paint) layers via voxel paint / vertex paint; panel differs per room.

---
## 92. Edit menu
URL: https://3dcoat.com/documentation/manual/interface-and-navigation/edit-menu/
- UNDO Ctrl+Z / REDO Ctrl+Y (no history limit documented).
- TRANSFORM WITHOUT GIZMO (Blender-like modal): assign hotkey (END); press hotkey then move; LMB confirm; RMB/Esc cancel; Space numeric (1D only); Shift/Ctrl/Ctrl+Shift discrete steps; W translate, E rotate, R scale; X, Y (or C), Z axis constraint; plane constraints Shift+Z / ZZ (XY), Shift+X / XX (YZ), Shift+Y / YY (ZX); F pick new pivot.
- OTHER: Scale Master (visual vs export scale); Calculate Occlusion; Calculate Curvature (needed for cavity conditions); Light Baking Tool (curvature, thickness SSS, local curvature RGB: B local, G middle, R far); Bake Geometry Info (GeometryIn for nodes); Sync Layer with External Editor (Ctrl+S in editor returns); Edit All Layers in Ext. Editor Ctrl+P; Edit Projections Ctrl+Alt+P; Project Through; Load/Save Hotkeys; Customize UI; Preferences; Reset to Default Settings (deletes Options*.xml, restarts); Relocate Data; Convert Older Materials; Bake Shader Nodes.

---
## 93. Library: Getting Started
URL: https://3dcoat.com/documentation/library/getting-started/
- Index: UI overview, Quick Start Series, mesh types, saving/backing up interface layout, tips for working across rooms, hotkey access to brushes and panels. (Headings only.)

---
## 94. Library: Painting
URL: https://3dcoat.com/documentation/library/painting/
- Paint Room "like Photoshop, but in 3D": colour, glossiness, depth (normal/bump/displacement) painted on surface with layers. Topic index: quick start, image picker, reference images, decals, UV texture editor, Paint Mesh <-> Sculpt round trip, hand-painted style series, Textura, Krita.

---
## 95. Library: Modeling
URL: https://3dcoat.com/documentation/library/modeling/
- Modeling Room: "direct, precise manipulation of polygons, edges, and vertices without automatic surface-snapping"; low-poly assets, UV maps, geometry from curves/primitives. Videos: Soft Selection, beginners, ship/helicopter/temple builds.

---
## 96. Library: UV
URL: https://3dcoat.com/documentation/library/uv/
- UV room: create/modify/optimise UVs; unwrap, pack, minimise distortion, texel density. Topics: multiple UV sets, UDIM tiles, swapping UVs, auto UV, stripe unfolding, select islands in viewport, UV Path Tool, unify UV maps, photogrammetry UVs, hard-surface UV basics.

---
## 97. Library (index)
URL: https://3dcoat.com/documentation/library/
- "Comprehensive, all-in-one 3D digital sculpting and texturing software" (Pilgway); game dev, concept art, industrial design; one app for all stages. Sections listed (see CRAWL LOG).

---
## 98. 2026 Key Features and Improvements (blog)
URL: https://3dcoat.com/documentation/2026/07/27/2026-key-features-and-improvements/
- SCULPT: "Pattern to Volume" (node patterns -> sculpt objects); lofted surfaces from curves in On-Plane tool, sculpted with voxel brushes; Retopo meshes -> Hybrid Meshes as On-Plane surfaces; Splitter tool (parts onto own layers).
- UI: text search for tools in Quick Access panel (Sculpt + Modeling).
- POSE: new deformation modes; snap mesh to object surface. Curves bending smoother.
- TEXTURING WHILE SCULPTING: node system as shader for sculpt objects; real-time material preview while sculpting before retopo/UV ("industry first" vendor claim).
- PERFORMANCE: GPU nodes compiled to shaders via NGL; unspecified optimisations.

---
## 99. Paint Tool Panel
URL: https://3dcoat.com/documentation/manual/workspaces-rooms/paint/paint-room-tools/
- SHARED: Spacebar = pie menu of tools; LMB/RMB primary/secondary colour; X swap.
- TOOLS: Painting Brush (3 channels; alpha; connective painting works on voxels); Pencil (pixel-sharp; Ctrl erases when depth off; turn off linear filtering); Airbrush (accumulation); Color Operations (desaturate, saturate, darken, lighten, sharpen, smooth, hue +/-, subst hue, H&S; Ctrl reverses); Height (Magnification/Reduction; Ctrl inverts; Degree of change); Smudge (Smudge/Pinch/Expand; screen space; small details; LMB click applies pinch/expand); Power-Smooth (screen-based; voxel painting depth caveats); Clone (Ctrl+LMB source; modes Translation, Dx, Dy, Mirroring, Inversion, Clone sector; symmetrical copy needs S + symmetry); Transform/Copy (LMB move, Shift proportional, Ctrl free corners, Esc cancel, Enter apply; PSD export/import; external edit); Copy and Paste (Ctrl+C, Ctrl+V, Ctrl+Shift+C alpha brush from surface, Ctrl+Shift+V mirrored paste; work in any tool); Curves (non-destructive per layer; Enter apply, Ctrl+Enter inverse depth, Backspace last point, Esc all, LMB add/drag, Shift drag move curve, Ctrl drag rotate; profiles Uniform, Sharp, Obtuse, Arrow...; .curve files); Text (along curve; Enter extrude, Ctrl+Enter indent); Picture (tile image along spline); Eraser (active layer only; Hide mode: LMB hide, Ctrl reveal, Ctrl-X unhide all, NUM+/NUM- widen/narrow; Act as Pencil); Hide Poly; Freeze (Shift smooths edges; modes Freeze all, Convexity, Concavity, Not key color, Key color; Contrast/Smoothing/Freeze degree; save/load masks); Fill (Layer / Surface Material / Object; tolerance; gradient mode; max angle; modulation patterns: noise, stripes, hexagon, pores, fractal wood...; long fills warn "not frozen, calculating"); Select (ex Magic Wand; Shift add, Ctrl subtract; freezes by colour tolerance); Pick (V primary colour, G brush depth, H top layer, LMB+V/RMB+V primary/secondary; double click picks from screen space; tiny brush sizes give wrong values); Flatten (Make planar; plane extrusion, cut off, fill); Measure (units); Topo-Symmetry (LMB red face then blue face; copy red<->blue; SYMM file).
- UX NOTES: "Freeze is the opposite of selection"; selection implemented as freeze inverse.

---
## 100. Select Geometry (Retopo top bar)
URL: https://3dcoat.com/documentation/manual/workspaces-rooms/retopology/top-bar/select-geometry/
- MODES: Vertices (Expand, Contract, Transform, Connect, Snap, Scale, Store/Load/Clear Selection); Edges (Free Extrude, Cut, Relax, Rotate CW/CCW, Extrude, Split, Collapse, Delete, Edge Loop, Edge Ring, Select Sharp (by mark/crease angle/group/UV set), Bevel, Set Seams, Mark/Clear Sharp, Bridge); Faces (Normal Extrude, Extrude Faces/Verts, Intrude, Shell, Free Extrude, Snap, Scale, Relax, Delete, Clone, Separate, Subdivide, Hide, Flip Faces, Invert Hidden, Unhide, Inset, Bridge).
- HOTKEYS: INSERT split edges / subdivide faces; BKSP collapse edges; DELETE delete; L edge loop; R edge ring; ENTER confirm transformed clone.
- CAVEATS: Transform with nothing selected transforms entire mesh; Scale per connected cluster; flip faces can create non-manifold; free-extruded verts not auto-snapped. No soft selection mentioned.

---
## 101. Curves menu
URL: https://3dcoat.com/documentation/manual/interface-and-navigation/curves-menu/
- FEATURES: works in all rooms; Activate curves editor; Q = Curves Quick Menu; Stop edit curves (+hide selected); Record strokes (each stroke saved as invisible curve in "Strokes" folder of Curves Tree = stroke history as data).
- CURVES TREE (Windows > Panels): Search, Activate, Apply, Duplicate, Brush along curve (spacing/jitter), Load, Save, Delete, Group; Load Curve from image (traces B/W bitmap).
- SNAPPING: surface, curve points, nearest curve, bbox centre; quantize length; horizontals/verticals; must enable in menu + settings.
- OPS: Separate Disconnected, Split Self Intersections, curve Booleans (intersection/union/subtraction), Simplify (0-1), Smoothing, Remove Sharp Corners (arc radius), Subdivide, Reverse, length display; place on plane; curve modifiers (detach, edit, hide meshes).
- APPLY: Start new curve; Brush Along Curve; Run brush along projection; Edit Pressure Profile; Select/Freeze projection area or in 3D space; Freeze selection to curve; Snap to surface; Assign radius; Set Coordinate; Delete all.
- HOTKEYS: Q quick menu; E curves mode; RMB on curve = properties; Enter apply curve to current tool. Closed curve fills area; open curve runs brush along path.

---
## 102. Retopo Tweak Tools
URL: https://3dcoat.com/documentation/manual/workspaces-rooms/retopology/left-tool-panel-in-retopology/retopo-tweak-tools/
- TOOLS: Sharp Edges (normal split); Brush (soft-selection-like falloff move; Shift smooths spacing); Keep Bounds While Smoothing; Through All Groups; Delete face/edge (click/drag; Ctrl deletes connected sets / whole edge loops); Collapse (LMB edge -> merge verts; Ctrl+LMB edge rings); Split Rings (new loops from highlighted row); Move ("Auto" moves any element type on the fly per Brush Command Panel); Slide Edges/Vertex (LMB slide edge, Ctrl+LMB slide loop); Measure (guides; Shift align, Esc, Ctrl no-snap, double-click erase); Show Open Edge.
- PATTERN: Ctrl = extend to loop/ring/connected set.

---
# CROSS-CUTTING UX SYNTHESIS (only from page statements above)
- Universal gesture grammar: LMB = act; RMB drag horizontal = brush size, vertical = depth (also for click-to-place primitive scale/penetration); SHIFT = smooth (or straight line if pressed after LMB); CTRL = invert tool; ALT+mouse = navigate when tool captures LMB; ENTER = commit (remesh in Surface, apply curve/stroke/import); ESC = clear/cancel; Space = quick tool menu (Paint: radial pie); E = stroke-mode panel; END over any UI element = assign hotkey; RMB+MMB over command = copy its script name.
- Stylus nav: tap-drag empty = orbit; pen RMB drag = pan/zoom; pen RMB over model = size/depth. Tablet in Mouse mode unsupported; Wintab vs Windows Ink choice; reset-user-folder as fix. No touch/multitouch documentation found anywhere.
- Data model: Sculpt Tree (objects/volumes, hierarchical, each with own V/S mode, resolution, ghost/visibility, live-boolean child ops) vs Layers panel (scene-wide Photoshop-like layers carrying colour/gloss/metal/depth; sculpt layers only on Surface objects; lost on Surface->Voxel). Masks are interconvertible: freeze <-> layer opacity <-> pose selection; voxel masking uses Hide (Freeze is Surface-only; surface freeze lost on switching back to voxel tool).
- Voxel = 0..1 field, surface at 0.5 (implicit/isosurface); default 1 voxel/mm; thin parts jaggy; no layers; booleans/live booleans voxel-only; Clay Engine hybrid brushes. Surface = triangle skin, dynamic subdivision/remove stretching/auto-subdivide replaced Live Clay (2022); multires surface-only.
- Admitted pain points: no dual monitor; panels reset; inconsistent docs (duplicate/conflicting hotkeys, counts); many commands undocumented; some merges/deletes not undoable; voxels memory-heavy; texture RAM (6k ~108MB/layer); saves finish 10-30 s late; old tutorial videos; customisation via editing menu.cpp; doc AI chat beta.

---
# CRAWL LOG
Tool: WebFetch (summarising fetch model). All URLs below fetched successfully unless marked.
1. https://3dcoat.com/documentation/
2. https://3dcoat.com/documentation/manual/interface-and-navigation/
3. https://3dcoat.com/documentation/manual/getting-started/  (also yielded full sidebar sitemap)
4. https://3dcoat.com/documentation/manual/navigation/hotkeys/
5. https://3dcoat.com/documentation/manual/navigation/camera-and-navigation/
6. https://3dcoat.com/documentation/manual/navigation/camera-and-navigation/customize-navigation-as-blender/
7. https://3dcoat.com/documentation/manual/navigation/navigation-panel/
8. https://3dcoat.com/documentation/manual/navigation/space-bar-menu/
9. https://3dcoat.com/documentation/manual/workspaces-rooms/sculpt/
10. https://3dcoat.com/documentation/manual/workspaces-rooms/sculpt/sculpt-tree/
11. https://3dcoat.com/documentation/manual/workspaces-rooms/sculpt/sculpt-layer/
12. https://3dcoat.com/documentation/manual/workspaces-rooms/sculpt/voxel-mode/
13. https://3dcoat.com/documentation/manual/workspaces-rooms/sculpt/surface-mode/
14. https://3dcoat.com/documentation/manual/workspaces-rooms/sculpt/voxel-mode/voxel-tools/
15. https://3dcoat.com/documentation/manual/workspaces-rooms/sculpt/surface-mode/surface-tools/
16. https://3dcoat.com/documentation/manual/workspaces-rooms/sculpt/live-booleans/
17. https://3dcoat.com/documentation/manual/workspaces-rooms/sculpt/voxel-mode/voxel-objects-tools/
18. https://3dcoat.com/documentation/manual/workspaces-rooms/sculpt/voxel-mode/density-and-resolution/
19. https://3dcoat.com/documentation/manual/workspaces-rooms/sculpt/brush-engine/
20. https://3dcoat.com/documentation/manual/brush-components/
21. https://3dcoat.com/documentation/manual/brush-components/strokes/
22. https://3dcoat.com/documentation/manual/brush-components/brush-options/
23. https://3dcoat.com/documentation/manual/brush-components/conditions-limiter/
24. https://3dcoat.com/documentation/manual/brush-components/brushes-alphas/
25. https://3dcoat.com/documentation/manual/brush-components/brush-top-bar/
26. https://3dcoat.com/documentation/manual/interface-and-navigation/freeze-menu/
27. https://3dcoat.com/documentation/manual/interface-and-navigation/symmetry-menu/
28. https://3dcoat.com/documentation/manual/interface-and-navigation/customization/
29. https://3dcoat.com/documentation/manual/interface-and-navigation/modify-or-create-new-room/
30. https://3dcoat.com/documentation/manual/interface-and-navigation/edit-menu/preferences/
31. https://3dcoat.com/documentation/manual/getting-started/tablet-on-window/
32. https://3dcoat.com/documentation/manual/navigation/stylus-doesnt-work-in-sculpting/
33. https://3dcoat.com/documentation/manual/navigation/activity-bar/
34. https://3dcoat.com/documentation/manual/workspaces-rooms/retopology/
35. https://3dcoat.com/documentation/manual/workspaces-rooms/retopology/autoretopo/
36. https://3dcoat.com/documentation/manual/workspaces-rooms/retopology/left-tool-panel-in-retopology/add-geometry/
37. https://3dcoat.com/documentation/manual/workspaces-rooms/uv-workspace/
38. https://3dcoat.com/documentation/manual/workspaces-rooms/uv-workspace/uv-workflow-example/
39. https://3dcoat.com/documentation/manual/workspaces-rooms/paint/
40. https://3dcoat.com/documentation/manual/workspaces-rooms/paint/the-layers-panel/
41. https://3dcoat.com/documentation/manual/brush-components/smart-materials/
42. https://3dcoat.com/documentation/manual/workspaces-rooms/paint/texture-painting-and-modes/
43. https://3dcoat.com/documentation/manual/workspaces-rooms/sculpt/surface-mode/multi-level-resolution/
44. https://3dcoat.com/documentation/manual/workspaces-rooms/sculpt/transform-tools/
45. https://3dcoat.com/documentation/manual/workspaces-rooms/sculpt/voxel-right-click-menu/
46. https://3dcoat.com/documentation/manual/workspaces-rooms/sculpt/geometry-submenu/
47. https://3dcoat.com/documentation/manual/workspaces-rooms/sculpt/voxel-mode/clay-engine/
48. https://3dcoat.com/documentation/manual/workspaces-rooms/sculpt/commands-for-sculpt-room/
49. https://3dcoat.com/documentation/manual/scripting-and-core-api/
50. https://3dcoat.com/documentation/manual/scripting-and-core-api/core-api/
51. https://3dcoat.com/documentation/manual/scripting-and-core-api/python-api/
52. https://3dcoat.com/documentation/manual/introduction-to-3dcoat/
53. https://3dcoat.com/documentation/manual/workspaces-rooms/
54. https://3dcoat.com/documentation/manual/workspaces-rooms/modeling/
55. https://3dcoat.com/documentation/manual/workspaces-rooms/render/
56. https://3dcoat.com/documentation/manual/workspaces-rooms/simplest/
57. https://3dcoat.com/documentation/manual/getting-started/different-forms-of-resolution/
58. https://3dcoat.com/documentation/manual/getting-started/system-requirements/  (fetched; content image-only, no text extracted)
59. https://3dcoat.com/documentation/faq/
60. https://3dcoat.com/documentation/training-tutorials/
61. https://3dcoat.com/documentation/library/sculpt/
62. https://pilgway.com/licensing
63. https://3dcoat.com/documentation/manual/navigation/opening-dialog-menu/
64. https://3dcoat.com/documentation/manual/color-management/
65. https://3dcoat.com/documentation/manual/3dcoat-print/
66. https://3dcoat.com/documentation/manual/nodesystem/
67. https://3dcoat.com/documentation/manual/texturing/
68. https://3dcoat.com/documentation/library/retopology/
69. https://3dcoat.com/documentation/manual/workspaces-rooms/sculpt/top-bar/
70. https://3dcoat.com/documentation/manual/workspaces-rooms/sculpt/sculpt-brush-options/
71. https://3dcoat.com/documentation/manual/workspaces-rooms/sculpt/transform-tools/pose/
72. https://3dcoat.com/documentation/manual/interface-and-navigation/hide-menu/
73. https://3dcoat.com/documentation/manual/interface-and-navigation/windows-menu/tabbed-windows-popup-panels/
74. https://3dcoat.com/documentation/manual/workspaces-rooms/sculpt/voxel-mode/pure-voxel-sculpting/
75. https://3dcoat.com/documentation/manual/workspaces-rooms/sculpt/voxel-mode/surface-tools-on-voxels/
76. https://3dcoat.com/documentation/manual/workspaces-rooms/sculpt/surface-mode/surface-layer/
77. https://3dcoat.com/documentation/manual/navigation/left-tool-panel/
78. https://3dcoat.com/documentation/manual/navigation/navigation-using-3dconnexion-devices/
79. https://3dcoat.com/documentation/manual/workspaces-rooms/sculpt/voxel-mode/voxel-adjustment-tools/
80. https://3dcoat.com/documentation/manual/workspaces-rooms/sculpt/surface-mode/surface-adjust-tools/
81. https://3dcoat.com/documentation/manual/workspaces-rooms/sculpt/voxel-primitives-import-tools/
82. https://3dcoat.com/documentation/manual/workspaces-rooms/sculpt/import-to-sculpt-room/
83. https://3dcoat.com/documentation/manual/scripting-and-core-api/extensions-and-addons/
84. https://3dcoat.com/documentation/manual/workspaces-rooms/sculpt/surface-mode/surface-custom-tools/
85. https://3dcoat.com/documentation/manual/workspaces-rooms/retopology/poly-groups/
86. https://3dcoat.com/documentation/manual/brush-components/presets/
87. https://3dcoat.com/documentation/manual/workspaces-rooms/kitbash/
88. https://3dcoat.com/documentation/manual/interface-and-navigation/view-menu/
89. https://3dcoat.com/documentation/manual/navigation/
90. https://3dcoat.com/documentation/manual/workspaces-rooms/sculpt/vector-displacement/
91. https://3dcoat.com/documentation/manual/interface-and-navigation/layers-menu/
92. https://3dcoat.com/documentation/manual/interface-and-navigation/edit-menu/
93. https://3dcoat.com/documentation/library/getting-started/
94. https://3dcoat.com/documentation/library/painting/
95. https://3dcoat.com/documentation/library/modeling/
96. https://3dcoat.com/documentation/library/uv/
97. https://3dcoat.com/documentation/library/
98. https://3dcoat.com/documentation/2026/07/27/2026-key-features-and-improvements/
99. https://3dcoat.com/documentation/manual/workspaces-rooms/paint/paint-room-tools/
100. https://3dcoat.com/documentation/manual/workspaces-rooms/retopology/top-bar/select-geometry/
101. https://3dcoat.com/documentation/manual/interface-and-navigation/curves-menu/
102. https://3dcoat.com/documentation/manual/workspaces-rooms/retopology/left-tool-panel-in-retopology/retopo-tweak-tools/

FAILURES / UNREACHABLE:
- https://3dcoat.com/documentation/manual/workspaces-rooms/uv-workspace/uv-tools-functions/ : SERVER_ERROR on first fetch; retry refused by tool (recent failure). Not read.
- https://3dcoat.com/documentation/manual/getting-started/system-requirements/ : reachable but requirements only in images (no text).
- Start URL "https://3dcoat.com/documentation/manual/color-management/" resolved fine (note: sidebar also lists /manual/getting-started/color-management/, not fetched).
- Not fetched (lower priority, in sitemap): Library Smart Materials/Nodes/Photogrammetry/Render/Print/Learning; File/Textures/Calculate/Bake/Scripts/Addons/Capture/Help menus; Controls (sliders); paint submodes (per-pixel, micro-vertex, ptex, surface painting); UV top bar/preview/import/export; Retopo menu/virtual mirror/bake/strokes/commands/UV tools/autopo guide; Sculpt Shader, Surface Painting, Multires tools/adjust/commands, Spline curves, Instancer/Move/Fit/Reproject/Surface Array subpages, Hollow Box, export; Modeling subpages; Photogrammetry, Nurbs, Nodes room, Factures, 3DPrint rooms; GPU node subpages; Linux/applink pages.
- No WebSearch was needed (all URLs discovered from sidebar links).
