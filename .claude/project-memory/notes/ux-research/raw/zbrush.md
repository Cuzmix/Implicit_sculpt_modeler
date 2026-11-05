# ZBrush official documentation crawl (UX research)

Crawled 2026-10-25 via WebFetch/WebSearch. Entries record only what each page states. Fields with nothing on a page are omitted or marked "none stated". Sources: maxon.net marketing feature pages (M), help.maxon.net online help (H), ZBrush for iPad help (iPad).

---

## [M] ZBrush product page
URL: https://www.maxon.net/en/zbrush
- FEATURES: 200+ brushes; base mesh creation; remeshing; ZModeler; Live Boolean; PolyPaint (no UVs needed); UV Master; SpotLight; MorphUV; Redshift in ZBrush (CPU); BPR (shadows, AO, fibers, HD geometry); LightCap (real-time material/lighting); GoZ to Cinema 4D; Cineware. FAQ claims tens of millions of polys in real time.
- 2027.0: integrated UV Editor on desktop; Selection Sets store multiple layouts of Polygroups, masks, PolyPaint, UVs and Morph Targets; iPad gains non-destructive 3D Layers and SpotLight.
- PLATFORMS: Windows (incl. Windows on Arm), macOS (Apple silicon), iPadOS. One license covers desktop and iPad, usable at the same time.
- INPUT: graphics tablet "strongly recommended" (Wacom given as example).
- DATA STRUCTURES: Selection Sets (polygroups/masks/polypaint/UV/morph target layouts).
- PAIN POINTS: desktop/iPad feature parity is an ongoing goal, not complete. Performance depends on the CPU, not the GPU.
- HOTKEYS: none stated.
- Docs link: https://help.maxon.net/zbr/en-us/Content/html/zbrush-online-help.html

## [M] Features overview (category filter)
URL: https://www.maxon.net/en/product-detail/zbrush/features?categories=1200575|1200576|1200577|1200578
- JS-rendered list. Only four category headings came back: SCULPTING, PAINTING & TEXTURING, RENDERING, PIPELINE. No feature descriptions were returned.

## [M] Base Mesh Creation
URL: https://www.maxon.net/en/zbrush/features/base-mesh-creation
- TOOLS: DynaMesh; ZSpheres; Mannequins; Snapshot3D; Mask Mesh brushes (MeshExtrude, MeshBalloon, MeshSplat, MeshExtrudePropDepth); ShadowBox.
- DynaMesh: sculpt freely without topology constraints. Push/pull geometry, merge separate pieces, or subtract (boolean-like). Redistributes polygons to an even size on command, so brush strokes stay consistent.
- ZSpheres: build a skeleton of spheres (like a wire armature); ZBrush generates the surface around it.
- Mannequins: library of humanoid and animal posable figures, used as starting points.
- Snapshot3D: greyscale alpha image to 3D mesh. Images can be added or subtracted boolean-style.
- Mesh From Mask: lasso a mask outline and it becomes an editable mesh that updates in real time. Extrude mode gives flat shapes of uniform thickness with bevels. Balloon mode gives organic shapes, thicker where the area is wide.
- ShadowBox: paint mask "shadows" on the front, side and bottom faces of a cube; the model is generated inside the box.
- UX NOTE: there are several 2D-to-3D creation paths (masks, alphas, silhouettes) that suit touch or pen drawing.

## [M] Brush System
URL: https://www.maxon.net/en/zbrush/features/brush-system
- Pen pressure from the tablet modulates strokes. Brush types: pinch, move, build-up, chisel, slice. Any 3D model can be used as a brush.
- Cloth/Dynamics brushes: contract, expand, inflate, drape under gravity. A mask pins part of the mesh. Works on low-res planes. Setup: place mesh, enable collision volume, set controls; cloth drapes over other visible meshes. Brushes: ClothTwister, ClothWind, ClothPinchTrails.
- Insert Mesh (IMM) brushes: small repeatable meshes inserted by stamp or along a curve, or used as boolean geometry. Integrates with DynaMesh.
- Knife brush "Split to Parts": slices a part into new component parts and keeps the sliced parts active.
- Retopo brush: rebuilds the mesh as low-poly topology that keeps roughly the same shape.
- History brush: applies Undo History only inside the brush area (local undo). In reverse it projects Redo History from one model onto another, regardless of topology.
- XTractor brushes (3): capture surface detail from a stroke into a new alpha or texture.
- VDM brushes: 3D stamps that allow undercuts and overhangs (for example a nose with nostrils in one stroke).
- UX NOTE: History brush (spatially local undo) is a notable pattern.

## [M] Sculptural Freedom
URL: https://www.maxon.net/en/zbrush/features/sculptural-freedom
- Slime Bridge: mask region A, mask an adjacent face group B, click Slime Bridge to create connecting geometry. Sliders: Tension, Bridges Calipers, Branches.
- Anchor Brush: place anchors, then MOVE / ROTATE / MOVEROTATE / SCALE / INFLATE / TWIST / BEND. Works with or without symmetry; no mask needed.
- Sculptris Pro: dynamic tessellation adds and removes triangles as you sculpt, so base poly count doesn't matter. Works with 400+ brushes. Subdivision Size Picker: hover over an area to sample the triangle size.
- Multi-Resolution Editing: switch subdivision levels at any time; edits propagate to all levels.
- Local Symmetry: uses the Gizmo so symmetry works off the world center.
- Masking: Crease/Uncrease Unmasked; Gizmo/Transpose masking; Grow All / Shrink All (stop at shell ends); Mask Region (Auto Region, Analyze Region, Fill Region).
- Apply Last Action: re-applies an undoable operation to many SubTools. Only SubTools with the Eye (visibility) icon on are affected. Folder-scoped.
- Repeat to Similar: repeats sculpting, mesh replacement, masking and polygroup changes on meshes with the same polycount.
- HD Geometry: up to 1 billion polys. About 20M on most computers, about 100M on high-end machines.
- PAIN POINTS: Repeat to Similar needs identical polycount. Apply Last Action skips hidden SubTools.

## [M] Polygon Modeling
URL: https://www.maxon.net/en/zbrush/features/polygon-modeling
- ZModeler: low-poly modeling brush with quick access to hole, edge-loop and extrude controls.
- Gizmo 3D Deformers: 27 deformers (bend, stretch, flatten, twist, slice, taper...); you can switch between them in one workflow.
- Project Primitive deformer: uses primitives to reshape, cut or build up a mesh (for example sphere to vehicle).
- Dynamic Subdivision: shows a smoothed preview without dividing polygons. Brushes edit the base cage while the smooth result displays, in real time. Intended for ZModeler/low-poly work.

## [M] Remeshing Options
URL: https://www.maxon.net/en/zbrush/features/remeshing-options
- ZRemesher: auto-retopology that produces clean edge loops and flow. Keeps creased edges and detects sharp angles (recommended for mechanical models). ZRemesher Retry: interactive comparison of topology variations. Keep PolyPaint: keeps color through a remesh.
- ZModeler: box-modeling from scratch or retopo over a sculpt; snapping to a target surface.
- Topology Brush: draw curves on the surface; topology is generated from the curve intersections. Thickness comes from Draw Size.
- ZSphere Retopology: each click places a vertex. Projects the original sculpt onto the new topology; can add thickness in real time.
- PAIN POINTS: none admitted (promotional page).

## [M] Flexible Workflows
URL: https://www.maxon.net/en/zbrush/features/flexible-workflows
- Proxy Pose: temporarily lowers density to pose high-res meshes, then converts back. Pairs with Transpose Master for posing multi-part meshes.
- Layers: blend shapes and keyframes; Timeline and Movie for animation; useful with scans.
- Drop 3D: Sculptris Pro combined with the 2.5D canvas. Drop 3D from IMM / from Alpha (converts ZTools or sculpts into IMM brushes; works with Stencils).
- Live Boolean: real-time add/subtract preview before committing, at any poly count. Works with NanoMesh/ArrayMesh. You can keep sculpting while it's live. Non-destructive (joints, print keys, hollowing, molds).
- Cloth Dynamics (same as brush page) plus instanced surface presets (canvas, denim, chainmail).
- Surface Noise: NoiseMaker (global or masked; multiple noise types combine) plus Maxon/C4D Noises.
- NanoMesh: ZModeler feature that scatters instanced geometry on polygons. Per-instance scale/offset/angle in real time; random mode. Editing the source updates all instances; layers can stack.
- ArrayMesh: pattern instancing that updates live. Controlled by sliders in the Array Mesh sub-palette or with TransPose. Can be nested in stages (tank treads, facades).
- FiberMesh: real geometry for hair/fur/vegetation, added as a new SubTool. Settings in the FiberMesh sub-palette. Groom brushes; fibers can be masked, transposed and polypainted; export with or without UVs.
- DATA STRUCTURES: ZTool, SubTool, IMM brush, instance source/instance relationships.

## [M] UV Editor
URL: https://www.maxon.net/en/zbrush/features/uv-editor
- Integrated UV Editor (ZBrush 2027) built on Cinema 4D UV technology, so you don't leave ZBrush for UVs. The page gives no tool details. References a Cineversity "UV Editor Part 1: UI Navigation" tutorial.

## [M] PolyPaint
URL: https://www.maxon.net/en/zbrush/features/polypaint
- Paint per vertex on the surface with no texture map or UVs. Map resolution doesn't need to be chosen up front; convert to a texture map with one click later. UVs and geometry can change without losing paint. Removing UVs frees resources, allowing more polygons.
- BEST PRACTICE: texture at high res before UVs or the final low-poly exist.
- DATA STRUCTURE: color stored per vertex (implied by its resolution independence from maps).

## [M] UV Master
URL: https://www.maxon.net/en/zbrush/features/uv-master
- One-click UVs: makes seams, unwraps, and packs islands to minimize distortion. Guided by a resolution scale setting and seam placement (control painting).
- Decimation Master (free plugin): cuts hundreds of thousands of polys "without visible quality loss".
- ZRemesher: one click for most environment models. For animated characters, guide edge loops and density manually.

## [M] SpotLight
URL: https://www.maxon.net/en/zbrush/features/spotlight
- Projection texturing. Load textures via the Texture palette or Light Box. Activate SpotLight, then set scale/rotation/position, nudge to fit features, clone, fill color, hue-match. Then paint the model in 3D through the texture.
- UI: Texture palette, Light Box.

## [M] Advanced Painting & Texturing
URL: https://www.maxon.net/en/zbrush/features/advanced-painting-texturing
- Crease Edge UV Unwrap: crease edges become UV seams.
- Dual Alphas & Textures: a brush holds two alphas/textures and pen pressure blends between them during a stroke.
- MorphUV: morphs the mesh into its flat UV shell. Sculpt and paint with ZAdd/ZSub/MRGB, then toggle off to go back to 3D with the detail applied. Use case: long strokes through tight corners or overlaps (waist to armpit to wrist).
- Dragstamp: drags surface detail across the surface in real time.
- Adjust by Color: edit PolyPaint/texture colors limited to selected colors; color picking can mask or unmask regions.
- DecoBrush/DecoCurve: uses Stroke >> Curve Mode to project an alpha.
- ZColor: color palette manager with shareable files. Path: Zplugin palette > ZColor sub-palette > ZColor button. Opens a floating window you can move and keep open.
- UI ELEMENTS: Stroke palette Curve Mode; Zplugin palette; floating window pattern.

## [M] Substance Bridge
URL: https://www.maxon.net/en/zbrush/features/substance-bridge
- One-click send to Substance Painter with automatic file management; keeps UVs and mesh detail; round trip back. No UI details.

## [M] Python Scripting Support
URL: https://www.maxon.net/en/zbrush/features/python-scripting-support
- Python is "the standard scripting language in ZBrush": workflow plugins, task automation, studio pipeline integration. No API details on the page.

## [H] ZBrush Online Help: welcome / table of contents
URL: https://help.maxon.net/zbr/en-us/Content/html/zbrush-online-help.html
- Doc structure (useful information architecture reference): Meet ZBrush (What's New, Main Features); ZBrushCore (incl. ZBrushCoreMini); Getting Started (install, interface, basic concepts: 2D vs 3D, the Pixol, ZTools and Edit mode, canvas document, saving, LightBox, Projects, navigation); User Guide (2D Illustration; 3D Modeling: primitives, ZModeler, Live Boolean, Snapshot3D, Remeshing, DynaMesh, Sculptris Pro, ZSpheres, ZSketch, SubTools, Stager, subdivision levels, dynamic subdivision, masking, polygroups, deformations, Transpose, Gizmo 3D; Sculpting: brushes, symmetry, morph targets, 3D layers, surface noise, projection master; Hard Surface: bevel/clip brushes, panel loops, clay polish, BevelPro; Painting: Polypaint, texture maps, Spotlight, ZAppLink; Other 3D: FiberMesh, MicroMesh, NanoMesh, ArrayMesh, cloth, Thick Skin, posing/rigging, topology, 3D printing, export; UV Mapping & UV Editor; Materials/Lights/Rendering: MatCap, LightCap, BPR, NPR, Redshift, KeyShot; GoZ; Movies; Plugins; Keyboard Shortcuts; Customizing ZBrush: hotkeys, macros, interface layout, file locations, ZScripting); Reference Guide (palette by palette: Alpha, Brush, Color, Document, Draw, Edit, File, Light, Material, Movie, Preferences, Render, Stroke, Texture, Tool, Transform, Zplugin...).
- UX NOTE: the reference guide is organized by palette (menu), mirroring the UI. ZBrush's UI is a set of named palettes.
- https://help.maxon.net/zbr/en-us/ itself returns only an empty JS shell (title "ZBrush").

## [M] ZBrush for iPad (product page)
URL: https://www.maxon.net/en/zbrush-for-ipad
- TOUCH: finger swipes and familiar Apple gestures control brush size, focal shift, undo and redo.
- APPLE PENCIL: double-tap, or Pencil Pro squeeze, is assignable to an action (for example frame mesh, or toggle PolyGroup display).
- UI: highly customizable, built on the desktop QuickMenu concept. A bottom bar holds favorite brushes, materials, alphas and textures. Custom hotkeys (keyboard).
- Brushes: 200+ (desktop plan lists 500+). Up to 92M polys per mesh on the latest M4 iPad (with 1TB or more storage); detail depends on iPad memory.
- Added from desktop: custom hotkeys, Retopo brush, 3D Print Hub, Scale Master, ZModeler, UV Master, Mask Adjust, Spotlight, 3D Layers.
- MISSING on iPad vs desktop: Plug-ins, UV Editor, Selection Sets.
- Free tier: 28 brushes, limited ZRemesher, PolyPaint only, no plug-ins, no brush load/save, Live Boolean preview-only.
- FILES: ZTL (ZTool) and ZPR (ZProject) move between iPad and desktop; GoZ.
- PAIN POINT: Maxon says the gap is "closing", not closed.

> CRAWL NOTE: help.maxon.net/zbr *.html pages return only the ~80KB nav tree; the article body is JS-injected. Appending ".md" (e.g. .../navigation.html.md) returns the article body as Markdown. All [H] entries below were read via the .html.md variant. Pages that came back body-less (finding-your-way-around, ztools-and-edit-mode, 2d-and-3d-navigation, universal-camera, customizing/navigation as .html) are logged in the CRAWL LOG.

## [H] Navigation (3D Modeling > Modeling Basics)
URL: https://help.maxon.net/zbr/en-us/Content/html/user-guide/3d-modeling/modeling-basics/navigation/navigation.html(.md)
- There are TWO navigation schemes.
- CLASSIC (best with RightClick Navigation OFF in Preferences > Interface):
  - Free rotate: left-click-drag on the background (empty canvas).
  - Move/pan: Alt + click-drag background.
  - Snap rotation to 90°: hold Shift while dragging.
  - Scale/zoom: Alt + click, release Alt, keep dragging background.
  - Roll around Z: Shift + click, release Shift, drag.
- RIGHT-CLICK (Preferences > Interface > RightClick Navigation ON). These work while over the model:
  - Rotate: right-drag. Move: Alt + right-drag. Zoom: Ctrl + right-drag.
- PAIN POINT: classic navigation needs empty background to start a drag, so it's hard when the model fills the screen. Mid-drag modifier-release chords are hard to discover.

## [H] ZBrush 2021 Cheat Sheet (PDF, official)
URL: https://help.maxon.net/zbr/en-us/Content/Resources/Uploads/ZBrush2021_CheatSheet.pdf
- GENERAL: Undo Ctrl+Z; Redo Shift+Ctrl+Z; QuickMenu Spacebar or right-click; Ctrl+N clear canvas pixels (not the model); Tab show/hide floating palettes; Ctrl+hover shows item description; draw tool on canvas then T = Edit mode; Shift+F Polyframe; Shift+P floor; P perspective.
- SAVE/LOAD: Ctrl+S save ZPR project (all tools + scene + canvas); Shift+Ctrl+T save ZTL (active tool only); ZBR = canvas document (Document > Save As); 9 = QuickSave; , (comma) = LightBox (double-click a thumbnail to open). Tool > Import: select the PolyMesh3D Star first to avoid scale issues.
- NAV (classic): F frame mesh; + / - zoom; Shift snaps rotation to 90°; Shift-click-release-drag rolls Z; click-drag background rotates; Alt+drag moves; Alt-click-release-drag zooms. When zoomed in, drag outside the thin white line near the canvas border. RIGHT-CLICK NAV: right-drag rotate, Alt+right-drag move, Ctrl+right-drag zoom.
- VISIBILITY/SELECT: Shift+Ctrl + pick = choose a Select brush; Shift+Ctrl stroke = selection area (green rectangle, keeps inside); add Alt = red (hides inside); Spacebar during drag moves the selection rectangle; Shift+Ctrl+click background = show all; Shift+Ctrl+click a polygroup = isolate it (click again to hide it); Shift+Ctrl+click-drag background = invert visibility; Shift+Ctrl+X grow visible; Shift+Ctrl+S shrink; Shift+Ctrl+A grow all; Shift+Ctrl+O outer ring; Shift+Ctrl+Q grow to polygroups.
- SUBTOOLS: Alt+click (or Shift+Alt+click) a subtool in the canvas to select it; N = subtool list popup; eye icon toggles visibility (Shift+click for all); paintbrush icon toggles polypaint (Shift+click for all).
- TRANSFORM: Q Draw, W Move, E Scale, R Rotate.
- BRUSHES: B, then first letter, then the highlighted (orange) letter = brush select (3-key chord). Ctrl held = mask brush; Shift+Ctrl = selection brush; X symmetry; \ Sculptris Pro; L Lazy Mouse; S draw size ([ ] steps); O focal shift; I RGB intensity; U Z intensity; Alt held = toggle ZAdd/ZSub; C pick color; V swap colors; 1 replay last stroke; Shift+1 replay relative; curve brushes: tap Alt once = soft corner, twice = sharp corner, hold = reverse; G XTractor; Spotlight: Texture > Add to Spotlight, Shift+Z toggle Spotlight, Z show/hide dial.
- GEOMETRY: Ctrl+D subdivide; D up a level; Shift+D down a level; DynaMesh resolution in Tool > Geometry > DynaMesh; Ctrl+drag background = re-DynaMesh (clear mask first); A over mesh = toggle HD sculpting, A over background = render all HD; curves: 6 smooth, 5 snapshot, Alt + draw across to delete; ShadowBox: turn off Solo first.
- IMM: M shows the IMM popup; Alt while inserting = negative mesh; Ctrl while inserting = fixed DrawSize.
- GIZMO 3D: drag axis arrows to move (grey = screen plane); drag rectangles to scale one axis (yellow center = uniform); drag circles to rotate (grey = screen axis); Ctrl+drag yellow center = inflate; Ctrl+drag arrow = clip/flatten (also documented as extrude unmasked polys); Ctrl+drag arrow = duplicate unmasked (release Ctrl and keep dragging to repeat); Ctrl+Alt+drag arrow = duplicate as negative (DynaMesh subtract); Alt+click mesh = reposition the gizmo; hold Alt over gizmo = unlock it from the mesh.
- MASKING: Ctrl + pick = choose mask brush; Ctrl+paint on mesh = mask; Ctrl+drag on empty space = area (lasso/rect) mask; Ctrl+click background = invert; Ctrl+Alt = erase mask; Ctrl+click-drag background = clear; Ctrl+click mesh = blur; Ctrl+Alt+click mesh = sharpen; Ctrl+drag on mesh in Move/Scale/Rotate mode = topological mask.
- MESH FROM MASK: Ctrl stroke starting on mesh = create mesh; starting in space = mask; Shift before release = add; Alt = subtract; Shift+Alt = intersect.
- LIVE BOOLEAN: Shift before releasing = additive subtool; Alt = subtractive; Shift+Alt = intersection.
- CANVAS/RENDER: 0 actual size; Ctrl+0 antialiased half size; Shift+S snapshot to canvas; Shift+R BPR render; Ctrl+R render area under cursor.
- UX NOTE: a heavily modifier-overloaded model. Ctrl = mask, Shift = smooth (implied), Ctrl+Shift = visibility, Alt = invert/subtract. A touch app needs mode toggles or a modifier wheel instead (see the iPad Modifier Wheel).

## [iPad] Navigation Settings (ZBrush for iPad)
URL: https://help.maxon.net/zbp/en-us/Content/html/3_interface-and-gestures_navigation-settings.html
- Two-finger pinch = zoom. Two-finger roll (if "Allow Roll Gesture" is on) = rotate/roll while pinching.
- One finger or Pencil drag in empty canvas = orbit (when Touch Navigation is on and roll is off).
- Horizontal drag rotates around the axis chosen in Rotation XYZ (Rotate X / Rotate Y / Rotate Z / Rotate XYZ, default XYZ). Vertical drag orbits freely until the drag returns to horizontal.
- "Center Navigation on Pinch": ON anchors zoom between the fingers at first touch; OFF zooms toward the selected subtool.
- PRO TIP: disable Allow Roll Gesture to keep a fixed angle while pinch-zooming.
- UI: User Settings > Navigation.
- iPad help sections: Interface & Gestures (Home, Canvas, Top Bar, Left Toolbar, Modifier Wheel, Bottom Toolbar, Right Toolbar, Quick Search, Palette Docking, Touch Gestures, Touch Gesture Settings, Navigation Settings, iOS Accessibility, Apple Pencil: Controls, Pressure Attributes, Haptics, Scribble, Hover Display; Keyboard; Long Press Directory), Palettes, Sculpting/Modeling/Painting, Rendering, Saving/Loading, UI Customization, FAQ.

## [iPad] Touch Gestures
URL: https://help.maxon.net/zbp/en-us/Content/html/3_interface-and-gestures_touch-gestures.html
- 1 finger drag in empty canvas = orbit. 1 finger on the model = sculpt/paint (touch acts as a brush by default), so navigation is "forced" into empty canvas space.
- 2 finger pinch = zoom, and also roll by default (Allow Roll Gesture).
- 3 finger drag up/down = draw size. 3 finger drag left/right = Focal Shift (shown inside the draw size cursor).
- PAIN POINTS: 3-finger gestures conflict with the iPadOS Accessibility Zoom setting. Pinch rolls the camera by default, which can be unwanted. Orbiting needs empty space.

## [iPad] Touch Gesture Settings
URL: https://help.maxon.net/zbp/en-us/Content/html/3_interface-and-gestures_touch-gestures-settings.html
- Touch Navigation: ON (default) means a finger on canvas orbits and a finger on the model sculpts. OFF means a finger anywhere orbits and touch never sculpts (Pencil-only sculpting, a palm/finger rejection model).
- Touch Strength slider: pressure sensitivity for finger sculpting (lower value = firmer press needed). The doc contradicts itself on which mode it applies in.
- Gestures: One-, Two-, Three- and Four-Finger Tap are each assignable to any action from a menu. Saved in preferences and persist across restarts. Defaults are not stated in text (likely undo/redo, per the product page).
- DOC PAIN POINT: defaults and the full action list exist only as images.

## [iPad] Modifier Wheel
URL: https://help.maxon.net/zbp/en-us/Content/html/3_interface-and-gestures_canvas-interface-modifier-wheel.html
- On-screen emulation of the desktop modifier keys: Shift = Smooth brush (blue cursor); Ctrl/Cmd = mask brushes (yellow cursor); Alt/Option = additive/subtractive inversion, combinable; Shift+Ctrl = Selection/Curve brush (white cursor); no modifier = sculpt/paint brush (red cursor); Space = customizable Quick Menu.
- INTERACTION: press-and-hold a button to activate; slide the finger to an adjacent button to combine modifiers. No latch/toggle mode is documented.
- Ring of buttons around a center handle. Drag the handle to move it; one finger on the handle plus a second finger dragged out/in to resize; a second finger dragged in a circle to rotate.
- Settings (User Settings > Modifier Wheel): Wheel Size Small through 3XL; Icon Set Action Icons (default) / Key Icons / Key Labels. Persisted.
- Quick Menu position: hold Shift and tap the arrows to slide it. The position resets after restart. Quick Menu customization is not in the free version.
- BEST PRACTICE: check the cursor color to confirm the mode before stroking.
- UX NOTE: this is the key touch translation of ZBrush's modifier-driven desktop model. It uses color-coded cursor state and hold-to-chord with the non-dominant hand.

## [iPad] Canvas Interface (index)
URL: https://help.maxon.net/zbp/en-us/Content/html/3_interface-and-gestures_canvas-interface.html
- Regions: Canvas, Top Bar, Left Toolbar, Modifier Wheel, Bottom Toolbar, Right Toolbar, Quick Search, Palette Tray Docking. Index page only.

## [iPad] Left Toolbar
URL: https://help.maxon.net/zbp/en-us/Content/html/3_interface-and-gestures_canvas-interface-left-toolbar.html
- Top to bottom (tap): Brushes, Strokes, Brush Alphas, Brush Textures, Materials (each opens a library plus modifiers); Color (picker); MRGB (polypaint channel control); Focal Shift slider; Draw Size slider; ZAdd/ZSub; Undo; Redo.
- UX NOTE: brush-definition pipeline (Brush > Stroke > Alpha > Texture > Material > Color) is laid out as a vertical strip, with undo/redo always visible.

## [iPad] Right Toolbar
URL: https://help.maxon.net/zbp/en-us/Content/html/3_interface-and-gestures_canvas-interface-right-toolbar.html
- Palettes (most features; toolbar items are child items of palettes); Subtool quick menu (= Palettes > Tool > Subtool); BPR Render; Perspective toggle; Floor Grid; Symmetry; Local Symmetry; Frame Model; Polyframe (tap toggles; long press opens Line/Fill toggles, both on by default); Transparency; Ghost Transparency (only when Transparency is on); Solo Mode (isolate the selected subtool).
- INTERACTIONS: tap toggles; long press opens sub-options.

## [iPad] Top Bar
URL: https://help.maxon.net/zbp/en-us/Content/html/3_interface-and-gestures_canvas-interface-top-bar.html
- Home (file loading, account); Save (tap = configured save action, shows a Name Sculpt dialog on first save; long press = Save options); Import; Export (models, textures, images, turntables, alphas, brushes, floor grid presets, materials, light presets); Screen Layout (full screen / split view / slide over); Undo History (slider plus submenu); Customize (edit the bottom Custom Toolbar and Quick Menu); Help (in-app manuals); User Settings.
- PAIN POINT: by default the second tap on Save overwrites the file silently. Check the Tap-to-Save setting.

## [iPad] Bottom Toolbar
URL: https://help.maxon.net/zbp/en-us/Content/html/3_interface-and-gestures_canvas-interface-bottom-toolbar.html
- Default: essential sculpt/paint brushes; Gizmo3D (tap activates, long press = settings); DynaMesh (tap activates, long press = settings; parent Tool > Geometry); SculptrisPro (same); ZRemesher (tap opens settings, doesn't run); Subdivide (tap opens subdivision settings); Live Boolean Render toggle.
- CUSTOMISATION: holds brushes, alphas, textures and materials; up to 5 unique bottom toolbars (licensed only). Press-hold and swipe up to move the bar to the top.
- PAIN POINT (doc admits inconsistency): some items activate on tap while ZRemesher/Subdivide open settings on tap.

## [iPad] Apple Pencil Controls
URL: https://help.maxon.net/zbp/en-us/Content/html/3_interface-and-gestures_apple-pencil-controls.html
- Scene Orbit: press-drag the Pencil in empty canvas around the model (default axis Rot XYZ).
- Long Press: on canvas buttons, subtools and sub-menus, opens extra options (see Long Press Directory).
- Pencil Roll (Pencil Pro barrel roll): while hovering over left-toolbar brush parameters, roll the pencil to raise or lower the value. Governed by Allow Roll Gesture (User Settings > Navigation > Multitouch).
- (Double-tap/squeeze assignment per the product page: frame mesh, polygroup toggle etc.)

## [iPad] Pressure Attributes
URL: https://help.maxon.net/zbp/en-us/Content/html/3_interface-and-gestures_apple-pencil-pressure-attributes.html
- User Settings > Pressure Attributes. Size Sensitivity (+ grows with pressure, - shrinks, 0 = constant size); Z Sensitivity (pressure to ZAdd/ZSub depth, 0 = intensity only); Color Sensitivity (pressure to RGB paint amount, 0 = constant at the RGB slider).
- CAVEAT: the M (material) channel has no pressure variation. No curve editor, defaults or ranges documented.

## [iPad] Hover Display
URL: https://help.maxon.net/zbp/en-us/Content/html/3_interface-and-gestures_apple-pencil-hover-display.html
- Pencil hover over canvas toolbar icons shows a tooltip plus the keyboard shortcut. Palette buttons and toggles also respond on compatible iPads. No settings.
- UX NOTE: hover as discoverability (the desktop equivalent is Ctrl+hover).

## [iPad] Long Press Directory
URL: https://help.maxon.net/zbp/en-us/Content/html/3_interface-and-gestures_long-press-directory.html
- Top: Save, which opens Save / Save As / Save Next / User Settings.
- Left: Brush/Alpha/Texture/Material add to the palette's Favorites. Color swaps primary/secondary. MRGB / Focal Shift / Draw Size / ZAdd-ZSub: long press THEN DRAG up/down to scrub the value (tap opens the full menu).
- Right: Perspective opens Focal Length/FOV; Floor Grid opens axis choice; Symmetry opens quick settings; Local Symmetry opens Dynamic mode; PolyFrame opens quick settings; Solo opens Dynamic Solo mode.
- Bottom: Brushes = Add to Favorites; Gizmo3D/DynaMesh/SculptrisPro/ZRemesher/Subdivisions = quick settings.
- Subtools: a selected subtool's long press = Rename, Copy/Paste, Duplicate, Bring to Top, Send to Bottom, New Folder, Boolean Process, Delete, Delete Other. An unselected subtool = Boolean Process submenu. Long press + drag = reorder. Folder long press = folder actions.
- UX NOTE: long press is the consistent "secondary action / settings / scrub value" gesture, replacing desktop right-click and modifier-click.

## [iPad] Quick Search
URL: https://help.maxon.net/zbp/en-us/Content/html/3_interface-and-gestures_quick-search.html
- Tap the search icon in the Palette menu, then type. Results update live; case-insensitive partial match across palettes, menus, subtools and options; results are grouped by category with icons and expandable submenus. Tapping a result jumps to its palette/menu. The panel can be dragged by its handle and collapses into a tray.
- Session memory: each query's picks persist as shortcuts for the session. They reset on project load/new or restart.
- PAIN POINT: string matching gives broad mixed results ("Poly" returns Polygroups and Polypaint).
- UX NOTE: a command palette / search over the huge palette tree is a key discoverability aid.

## [iPad] Palette Docking
URL: https://help.maxon.net/zbp/en-us/Content/html/3_interface-and-gestures_canvas-interface-palette-docking.html
- With Palettes or the Subtool palette open, drag its handle left and release to dock it into a Tray. Tap a Tray icon to toggle that palette. Drag horizontally to reposition. Horizontal only; undocking and persistence are not documented.

## [iPad] UI Customization (overview)
URL: https://help.maxon.net/zbp/en-us/Content/html/8_ui-customization.html
- Custom Toolbar: custom brush-library toolbars, reached by swiping the bottom toolbar left/right. Quick Menu: custom menus of buttons/sliders taken from palettes. Palette Trays. Hotkeys; User Settings; Reset Settings; UI.

## [iPad] Keyboard & Mouse
URL: https://help.maxon.net/zbp/en-us/Content/html/3_interface-and-gestures_keyboard.html
- iPadOS keyboards and mice are supported; shortcuts mirror desktop. Mouse is single-click only. "Right-click mouse navigation is not supported."

## [iPad] Sculpting | Modeling | Painting (chapter index)
URL: https://help.maxon.net/zbp/en-us/Content/html/5_sculpting-modeling-painting.html
- Chapter structure: Brushes (Retopology, ZModeler: overview, menu, temporary polygroups mode, presets, best practices, actions/modifiers, targets); Brush Customization (Brushes menu, Stroke, Stroke modifiers, Alpha, MRGB, Focal Shift, Draw Size, ZAdd/ZSub); Essentials guides: Selection Brush, Masking, Polygroups, DynaMesh, Sculptris Pro, Subdivision, ZRemesher, Polypaint, Spotlight, Live Boolean, Symmetry, Gizmo3D (basics, gizmo vs transpose line, IMM replacement), Transpose Line, Posing, ZSphere.
- iPad Palettes chapter mirrors the desktop Tool palette: Subtool, Geometry (Proxy Pose, Dynamic Subdiv, Edge Loop, Panel Loops, Crease, ShadowBox, Clay Polish, DynaMesh, Tessimate, ZRemesher, Modify Topology, Repeat Similar Parts, Stager, Position, Size, Mesh Integrity), ArrayMesh, NanoMesh, Layers, FiberMesh, Surface/NoiseMaker, Deformation, Masking (mask by topology/region/adjust/fibers/AO/cavity/depth/normals/smoothness/curvature/peaks-valleys/color), Visibility, Polygroups, Contact, Morph Target, Polypaint, Display Properties, Initialize, Export, UV Map, Texture Map, Displacement Map; plugins Decimation Master, UV Master, 3D Print Hub, Scale Master.

## [iPad] FAQ
URL: https://help.maxon.net/zbp/en-us/Content/html/10_faq.html
- 3-finger draw-size gesture conflicts with iPadOS Zoom: turn off Settings > Accessibility > Zoom.
- Known issue: lag and heat on M4 iPads from iPadOS setting conflicts. Workaround: enable Low Power ("Low Battery") mode.

## [iPad] Customize Quick Menu
URL: https://help.maxon.net/zbp/en-us/Content/html/8_ui-customization_customize-quick-menu.html
- Access: hold Spacebar (Modifier Wheel) for the Quick Menu, then swipe to Custom Menus.
- Edit: Customize (top-right) > Quick Menu > swipe to Custom Menu N > pick a palette in the left panel > long-press a button/slider and drag it into the menu. Multi-select: long-press-drag one item and tap others with the other hand, then drop them together. Remove: drag to the trash.
- LIMITS: 5 custom Quick Menus; only palette buttons/sliders can be added. Persisted in preferences. Reset, rename and reorder are not documented.
- UX NOTE: the desktop "custom UI by Ctrl+Alt-dragging palette buttons" model is carried over as long-press-drag.

## [iPad] Masking Essentials
URL: https://help.maxon.net/zbp/en-us/Content/html/5_sculpting-and-painting_masking-essentials.html
- Mask brushes need Ctrl/Cmd (Wheel). Alt subtracts. Masking respects Symmetry. Pick a brush from the Mask collection, or hold Ctrl and tap the Brushes icon (picks the brush that the modifier maps to).
- MaskPen: Ctrl+draw = add; Ctrl+Alt+draw = subtract; Ctrl+tap empty canvas = invert; Ctrl+tap surface = blur; Ctrl+drag empty canvas = clear; Ctrl on empty canvas = Rect mask, on surface = freehand.
- Shape brushes (Circle, CurvePen, Lasso, PerfectCircle, Rect, Square): Ctrl+draw, then lift to apply. Keep pressure and release Ctrl to hold the shape; Space+drag to move it; hold Alt before lifting = subtract. MaskSquare + alpha centers the alpha.
- MaskCurve: Ctrl+drag; release Ctrl while keeping pressure to lock; Alt tap = soft point; Alt double-tap = hard point; lift = apply. Ctrl+tap on an unmasked subtool = MaskAll.
- "Masks are applied to vertices": blur strength depends on point count (low-res meshes blur more). Sharpen = Ctrl+Alt+tap mask (repeatable up to a max).
- Edit Applied Mask options live in Tool > Masking and do nothing without a mask. Reset All Brushes (in the Brushes options menu) resets sculpt, selection and mask brushes together.
- DATA STRUCTURE: per-vertex mask scalar (0..1, blurrable/sharpenable).
- UX NOTE: "hold pressure, change modifier, then lift to commit" is a core touch pattern (staged commit).

## [iPad] Selection Brush Essentials (visibility)
URL: https://help.maxon.net/zbp/en-us/Content/html/5_sculpting-and-painting_selection-brush-essentials.html
- Ctrl+Shift = selection brushes (also used to select polygroups).
- Show: Ctrl+Shift draw green; release the modifiers while keeping pressure; Space+drag to move; lift = keep inside visible.
- Hide: same, then hold Alt before lifting (turns red) = hide inside.
- Reverse: Ctrl+Shift draw in empty canvas (not over the surface). Restore all: Ctrl+Shift tap canvas.
- Stroke type: Ctrl+Shift tap Strokes. Stroke settings reset on restart.
- PAIN POINTS: Symmetry is on by default (turn off for asymmetric hiding). The left toolbar can cover the Modifier Wheel. SelectLasso tap on an edge hides an edge loop; tap the canvas, not the model, to restore. Reset All Brushes resets everything together.
- DATA STRUCTURE: visibility is per polygon, per subtool (hidden polys are excluded from sculpting).

## [iPad] Gizmo3D Basics
URL: https://help.maxon.net/zbp/en-us/Content/html/5_sculpting-modeling-painting_gizmo3d-essentials-basics-guide.html
- Tap Gizmo3D (bottom bar) to activate; long press = settings. Cones = axis move; rectangles = axis scale; yellow center = uniform scale; grey corners = screen-space move; circles = rotate (Shift = 5° snap).
- Locked to the subtool by default. Hold Alt to unlock and reorient via the move/rotate wheels. Lock icon toggles. Alt+tap Reset Orientation = world axes. "Go To Unmasked Mesh Center" icon. Home returns the model to the origin.
- CAVEATS: affects only unmasked parts. With Symmetry on, two controllers exist (one hidden), so centering lands between them; turn symmetry off to center. Off-center gizmo plus symmetry pulls both sides; use Local Symmetry.
- BEST PRACTICE: clear masks and disable symmetry before centering.

## [iPad] DynaMesh Sculpting Essentials
URL: https://help.maxon.net/zbp/en-us/Content/html/5_sculpting-and-painting_dynamesh-sculpting-essentials.html
- Max DynaMesh is about 8M polys per subtool (subdivision can reach about 100M active points). Bottom Toolbar > DynaMesh (tap toggles; long press = settings). Starter project DynaMeshSphere128 (Home > New Sculpts > 3D Meshes).
- LOOP: sculpt big changes (e.g. SnakeHook), Ctrl-drag in empty canvas to draw a MaskRect, lift = remesh, check Polyframe, Shift-smooth, repeat; finish detail with alphas.
- Resolution slider default 128. Raising it affects the whole surface; re-mesh to apply. Only vertices changed since the last remesh are rebuilt (incremental).
- PAIN POINTS: uneven density after remesh needs cleanup; resolution is global, not local.
- BEST PRACTICE: start low-res, raise only when detail won't hold; remesh often. Desktop behaves the same.
- UX NOTE: remesh is triggered by an empty-canvas rect-mask gesture (desktop: Ctrl+drag background).

## [iPad] Brush Customization (index)
URL: https://help.maxon.net/zbp/en-us/Content/html/5_sculpting-and-painting_brush-customization.html
- Covers Strokes, Alpha and Texture modifiers. Highlighted Stroke types are brushes that "do not require modifier commands". Subpages: Brushes Menu & Settings, Stroke, Stroke Modifiers, Alphas, MRGB, Focal Shift, Draw Size, ZAdd & ZSub.

## [iPad] Brush Stroke
URL: https://help.maxon.net/zbp/en-us/Content/html/5_sculpting-and-painting_brush-1-stroke.html
- Stroke types: Dots (spacing 0.2), FreeHand (spacing 0.75), DragRect (drag to size/rotate an alpha stamp; ZAdd raises, ZSub carves), Color Spray, Spray, DragDot (drag to reposition a single alpha before placing), DragStamp.
- Spacing can't be changed directly. Use Lazy Mouse and raise the lazy step instead.
- Strokes and modifiers work the same as desktop. Color modifier: Strokes > Modifiers. RGB must be on to colorize Dots/FreeHand.

## [iPad] Brushes (categories)
URL: https://help.maxon.net/zbp/en-us/Content/html/5_sculpting-and-painting_brushes.html
- Categories: Anchor, Chisel (Alpha 3D projections), Clay, Clip (flatten within lasso/curve/circle/rect, no deletion), Cloth, Groom (FiberMesh only), Hard Surface (flatten/trim/polish/bevel), Insert Mesh/IMM, Knife (cuts and rebuilds geometry), Mask, Move, Paint (M/RGB/MRGB), Pattern, Sculptural (History Recall, MatchMaker, Morph...).
- Clip: Ctrl+Shift drag, lift to apply; curve mode Alt = soft point, double Alt = hard point, Space = pan; Ctrl then Alt reverses. Knife: Ctrl+Shift draw; Alt keeps outside. BevelArc/BevelFlat use Lazy Mouse Backtrack: drag one way then reverse; lifting cancels.
- IMM: drag outward to scale uniformly, out-then-in for non-uniform; then Gizmo3D to transform. Curve placement shows a BLUE cursor; tap the surface to delete a curve; the inserted part gets masked (others masked); Split Unmasked Points makes a separate subtool. Curve Snap: draw small, then raise Draw Size and tap the curve to resize.
- Move: camera-relative by default; Alt = along average normal. Move Infinite Depth. Morph brush: StoreMT, sculpt, Switch, then brush restores. MatchMaker: conforms to underlying shapes using the camera angle.
- CAVEATS: Cloth best under 100k active points (low res = big folds). Knife is destructive (unlike Clip). Anchor works only on the selected subtool.

## [iPad] Subdivision Sculpting Essentials
URL: https://help.maxon.net/zbp/en-us/Content/html/5_sculpting-and-painting_subdivision-sculpting-essentials.html
- Subdivision adds points without changing base topology. Each step is a level; the SDiv slider switches levels. Up to about 100M polys per subtool. Bottom bar Subdivide > Divide (base = level 1). Active point count shows top-left under the Thumbnail.
- Delete Higher / Delete Lower (slider must sit between min and max).
- Details at higher levels survive smoothing at lower levels (multires propagation).
- GESTURES (User Settings > Input > Gestures, example config): 2-finger tap = Higher Res; 3-finger tap = Lower Res.
- BEST PRACTICE: secondary forms at low SDiv, tertiary detail at high SDiv.
- DATA STRUCTURE: subdivision level stack per subtool (multiresolution mesh).

## [iPad] Sculptris Pro Essentials
URL: https://help.maxon.net/zbp/en-us/Content/html/5_sculpting-and-painting_sculpting-sculptis-pro-essentials.html
- Dynamic tessellation in which Draw Size controls triangle density (smaller brush = denser). Bottom bar toggle (long press = settings).
- Settings: SubDivide Size (tessellation per stroke); UnDivide Ratio (triangle size the Smooth brush produces, i.e. decimates); turn off ZAdd on Smooth so it re-tessellates without flattening.
- CAVEATS: Move brushes don't remesh under Sculptris Pro. A high SubDivide Size loses fine detail.
- TIP: check Polyframe after strokes; use Undo to compare settings.

## [iPad] Polygroups Essentials
URL: https://help.maxon.net/zbp/en-us/Content/html/5_sculpting-and-painting_polygroups-essentials.html
- Polygroups = colored group IDs per polygon, visible with Polyframe. Tool > Polygroups.
- Create: mask then Group Masked (Ctrl+W); or hide via selection then Group Visible (makes one group for the whole mesh if nothing is hidden).
- Select: Polyframe on, then Ctrl+Shift tap a group = isolate; tap a vertex shared by groups = select all of them; Ctrl+Shift tap canvas = restore.
- CAVEAT: polygroups are stored on the base subdivision level, so create them at the lowest level (groups made higher lose shape when changing levels). SelectLasso tap on an edge isolates an edge loop; use SelectRect for groups.
- DATA STRUCTURE: polygroup ID per face, stored at base level.

## [iPad] Symmetry Essentials
URL: https://help.maxon.net/zbp/en-us/Content/html/5_sculpting-and-painting_symmetry-essentials.html
- Right toolbar: tap toggles; long press = menu. X default; Y, Z, or all. CamView widget (top-right) snaps the camera to an axis (red X / green Y / blue Z).
- Local Symmetry (child of Symmetry): "Dynamic" (default) uses Gizmo3D center/orientation as the mirror plane, so symmetry follows the moved/rotated model.
- Radial Symmetry: axis X/Y/Z plus Radial Count. Works with Dynamic Local Symmetry.
- Setup: center the model (Deformation > Unify). Recenter the gizmo with Symmetry off: Alt-tap Gizmo3D > Go To Unmasked Mesh Center.
- CAVEAT: symmetry needs symmetric topology. Fix with Tool > Geometry > Modify Topology > Mirror & Weld.

## [iPad] Live Boolean Essentials
URL: https://help.maxon.net/zbp/en-us/Content/html/5_sculpting-and-painting_live-boolean-essentials.html
- Render-preview system: booleans display live without changing geometry. Mode is per subtool (long press subtool > Boolean Process): Additive (default; duplicates reset to it), Subtractive, Intersection.
- Workflow: Subtools Insert/Append Cube3D, Gizmo3D to place it, long press > Boolean Process > Subtraction, Live Boolean ON (bottom bar). Duplicate for more cuts (then reset the mode).
- Subtractive/Intersect subtools are hidden while live; show them with Polyframe. Subtool ORDER in the list determines targets (subtractors act on subtools above them).
- Commit: Tool > SubTool > Boolean > Make Boolean Mesh creates a new Tool "UMesh". DSDiv option bakes dynamic subdivision.
- PAIN POINTS: duplicating resets the mode; hidden cutters; order sensitivity; free tier is preview-only.
- DATA STRUCTURE: Boolean mode flag per subtool; list order = evaluation order.

## [iPad] ZRemesher Essentials
URL: https://help.maxon.net/zbp/en-us/Content/html/5_sculpting-and-painting_zremesher-essentials.html
- Purpose: clean, animation-ready base mesh, then subdivide. Bottom bar > ZRemesher.
- Symmetry: X sym plus Local Symmetry Dynamic mirrors around the Gizmo; otherwise around world center (send model Home). Symmetry off gives asymmetric flow.
- Target Polygon Count default 5 (about 5,000 polys). Retry remeshes from the original pre-remesh surface (recommended); the ZRemesher button remeshes the current result.
- Density painting: enable Use Polypaint, Color > FillObject, paint with the Paint brush at a Color Density (red = denser, blue = coarser), then ZRemesher.
- Demo: DemoAnimeHead.

## [iPad] Polypaint Essentials
URL: https://help.maxon.net/zbp/en-us/Content/html/5_sculpting-and-painting_polypaint-essentials.html
- Vertex painting: color resolution = active points. Top-left HUD shows Active Points (selected subtool) and Total Points (all).
- FillObject for a base color; Alt+draw paints the secondary color; Spray/Color Spray plus alpha for variation. If quality is low, raise DynaMesh Resolution and remesh (Ctrl-drag empty canvas). Paint brush preset; other brushes via MRGB.
- CAVEATS: low point count loses paint detail. A brush texture overrides the color.

## [iPad] Tool > Subtool palette (stub)
URL: https://help.maxon.net/zbp/en-us/Content/html/4_palettes_tool-2-subtool.html
- Palettes > Tool > Subtools, or the right-toolbar quick icon. No further content.

## [iPad] Tool > Layers (3D Layers)
URL: https://help.maxon.net/zbp/en-us/Content/html/4_palettes_tool-4-layers.html
- New layer starts in Record mode (red Record, grey eye); sculpt, polypaint and masking record into it. Tap the eye to stop (eye turns gold). Only red layers record.
- Row slider -1..1 (negative inverts). Multiplier slider (selected layer) up to 5x either way. Eye = visibility.
- Bake Current / Bake All (at current strength). Long press: Rename, Duplicate, Split (separates paint from sculpt), Invert, Merge Down, Move Up/Down, Delete.
- Layers are per SubTool. Import MDD is desktop-only.
- PAIN POINT: layers are memory-heavy and on iPad reduce undo history. Raise Reserved Undo Memory (User Settings > Undo History).
- DATA STRUCTURE: per-layer per-vertex displacement, color and mask deltas with a blend weight.

## [iPad] Undo History
URL: https://help.maxon.net/zbp/en-us/Content/html/7_saving-loading_undo-history.html
- Timeline stored PER SUBTOOL; scrub slider; Ctrl+Z / Ctrl+Shift+Z.
- Markers pin a history point. Morph and History Recall brushes revert to it. Repeat to Similar Parts uses Markers.
- Delete Older Undo History / Delete Undo History are irreversible.
- Undo history is saved only in ZPR (not ZTL). Settings: Enable Saving; Skip Loading; Max Undo History (per subtool).
- UX NOTE: per-object undo stacks plus a scrubbable timeline plus markers plus brush-based local undo.

## [H] SubTools
URL: https://help.maxon.net/zbr/en-us/Content/html/user-guide/3d-modeling/modeling-basics/subtools/subtools.html(.md)
- SubTools = separate polygon objects inside one ZTool. Each can reach the system max poly count, so the total multiplies (8M x 4 = 32M).
- LIMIT: "cannot sculpt or pose multiple SubTools at once". Use Polygroups for one object with separate parts.
- Eye icon in the SubTool list hides a subtool. Solo mode (right shelf and Transform palette; no default hotkey) isolates the selected one. Preferences > Edit > Click to Solo: click empty canvas to solo.
- Tool > SubTool > Append / Insert adds meshes.
- Apply Last Action: repeats the last undoable Tool-palette action on all other visible SubTools (e.g. disable Dynamic Subdiv, fill color/material).
- SubTool Folders (since 2019): Move/Scale/Rotate/Duplicate/Delete/Hide-Show PolyPaint/Live Boolean per folder.
- BEST PRACTICE: split along natural part boundaries (body vs clothing); work one SubTool at a time for performance.
- DATA STRUCTURE: ZTool = ordered list of SubTools; each has its own subdivision stack, polygroups, mask, polypaint, layers and undo history; one is "selected/active".

## [H] SubTool Folders
URL: https://help.maxon.net/zbr/en-us/Content/html/user-guide/3d-modeling/modeling-basics/subtools/subtool-folders/subtool-folders.html(.md)
- Tool >> SubTool >> New Folder (prompts for a name; holds the selected SubTool or all Gizmo-multi-selected ones). NOT undoable. No nesting; folders can't be empty (deleting the last child deletes the folder).
- Drag to reorder (cyan separator preview); drag SubTools in and out. Angled arrows move a SubTool into/out of open folders, or move a closed folder. Buttons under the list act on single SubTools; the folder gear icon holds folder actions. Auto Reorder acts on all.
- Folder eye toggles all children but individual states override. Folder PolyPaint toggle works the same way. Visible Count slider 1-24 (rows shown).
- Gear actions: TransPose Set/Add/Sub (Gizmo multi-select); Duplicate*; Merge Up*; Boolean Folder (first child = positive + Start Group; result placed below, children hidden); Boolean DSubDiv; Merge Folder* (includes hidden); Rename; Delete Folder* (children move out); Delete All*. (* = not undoable)
- LIMITS: about 1000 (also stated as 1024) SubTools per project; 100 per folder.
- PAIN POINTS: many folder ops are not undoable. A whole-list Boolean ignores folders unless each folder's top SubTool has the Start Group flag. Recommends alphanumeric names without spaces.

## [H] Subdivision Levels
URL: https://help.maxon.net/zbr/en-us/Content/html/user-guide/3d-modeling/modeling-basics/subdivision-levels/subdivision-levels.html(.md)
- Catmull-Clark. Polymeshes keep a subdivision history: N divides give N+1 levels. Changes propagate across all levels.
- WORKFLOW: big shapes at low levels (cage), detail at high levels. Example: bumps at high level survive flattening hills at low level. Pipeline: import low-res, subdivide to millions, detail, go to lowest, make normal/displacement maps, export low-res.
- Smooth UV switch: UVs smoothed on the next Divide/Edge Loop; borders frozen.
- UI: Tool > Geometry. (Hotkeys from the cheat sheet: Ctrl+D divide, D / Shift+D level up/down.)

## [H] HD Geometry
URL: https://help.maxon.net/zbr/en-us/Content/html/user-guide/3d-modeling/modeling-basics/subdivision-levels/hd-geometry/hd-geometry.html(.md)
- Up to about 1 billion polys; only the on-screen sculpt area is loaded. Tool > Geometry HD > DivideHD.
- Hover the area and press `a` to enter Sculpt HD: a circular region of about 10M polys (MaxPolyPerMesh) becomes editable. Press `a` again to exit (display drops back to the base level; detail is kept).
- Render HD: Sculpt HD button, or `A` with the cursor off the model. Holes: Tool > Display Properties > Double. BPR: Render > Render Properties > HDGeometry.
- BEST PRACTICE: subdivide normally to a comfortable level first.
- UX NOTE: spatial out-of-core windowing (sculpt a local region of a gigantic mesh).

## [H] Masking
URL: https://help.maxon.net/zbr/en-us/Content/html/user-guide/3d-modeling/modeling-basics/masking/masking.html(.md)
- Masks only in 3D Edit mode. Graded (per point 0..1); ops scale by mask intensity; shown as dark patches. Tool > Masking.
- Ctrl+paint (start on the model) = mask; Ctrl+drag starting outside the model = rectangle mask (an Alpha palette selection shapes it); Ctrl-click the Brush thumbnail to choose MaskLasso, then Ctrl-drag lasso; Ctrl-click canvas = invert; Ctrl-click masked area = blur; Ctrl+Alt paint = unmask; Ctrl+drag outside = clear; Transpose Ctrl-drag on surface = topology mask; W then Ctrl+Shift+click a polygroup = mask all other groups.
- TIP: invert an empty mask to mask everything. Topology masking suits limbs/tentacles; polygroups suit complex models.
- PAIN POINTS: where a stroke starts (on the model vs off it) changes its meaning. Repeated blur weakens the mask.

## [H] Polygroups
URL: https://help.maxon.net/zbr/en-us/Content/html/user-guide/3d-modeling/modeling-basics/polygroups/polygroups.html(.md)
- Polygroups = selection areas on ONE contiguous mesh (vs SubTools = separate geometry). Used by IMM brushes etc. Tool > Polygroups. Transform > Frame (Shift+F) shows them.
- Ctrl+Shift+click group = show only it; Ctrl+Shift+click outside = show all; Ctrl+Shift drag outside = invert. Multi-select recipe: isolate, invert, Ctrl+Shift+click more groups, invert again (clumsy, a pain point).
- W then Ctrl+Shift+click group = mask all others.
- Can't split geometry into independent pieces.

## [H] Mesh Visibility
URL: https://help.maxon.net/zbr/en-us/Content/html/user-guide/3d-modeling/modeling-basics/mesh-visibility/mesh-visibility.html(.md)
- Hide parts of the mesh to isolate work (e.g. hide body, work on head). Tool > Visibility.
- Shift+Ctrl pick in brush popup = Select/Clip brush. Shift+Ctrl click, release keys, drag = green area (show). Add Alt = red area (hide). Space (while still dragging) = move area. Shift+Ctrl click background = show all. Shift+Ctrl click a polygroup = show only it (fully visible mesh); twice = hide it; on a partially visible mesh once = hide. Shift+Ctrl click-drag background = reverse. Lasso option: Shift+Ctrl click on an edge = hide edge loop. ClipCurve: Alt once = soft corner, twice = sharp; hold Alt = reverse clip side.
- PAIN POINT (doc admits): the same Shift+Ctrl+Click gives different results depending on current visibility state (modal ambiguity).
- DATA STRUCTURE: hidden flag per polygon.

## [H] Transpose (Modeling Basics)
URL: https://help.maxon.net/zbr/en-us/Content/html/user-guide/3d-modeling/modeling-basics/transpose/transpose.html(.md)
- W/E/R switch to Move/Scale/Rotate, which auto-selects a Transpose brush. The Action Line has 3 circles; click the white ring at the far end to center on visible / unmasked / current polygroup.
- Smart Masking brush: Ctrl+drag the action line to mask by curvature (short line = fine, long = broad); Shift adds, Alt unmasks.
- Curve deformation: in Move, Alt-drag the center circle to bend the surface between the outer circles (uses Brush curve).
- Extrusion: Polymesh/DynaMesh only, no subdivision levels (use Freeze SubDivision Levels). Mask, W, draw the line from the unmasked area, Ctrl-drag the white circle inside the orange middle circle; the mask updates to the new geometry. LSym for symmetric extrusion.
- Duplication: no mask, Ctrl-drag in Move gives a copy merged into the same SubTool. IMM duplicate: mask all but the inserted piece (polygroup mask) and Ctrl-drag repeatedly. Missed points make it extrude instead.
- Negative mesh (DynaMesh): Ctrl+Alt drag center circle; subtracted on remesh (shells).
- PAIN POINTS: extrude/duplicate fail on subdivided models; incomplete masks are the main cause of errors.

## [H] Gizmo 3D (overview)
URL: https://help.maxon.net/zbr/en-us/Content/html/user-guide/3d-modeling/modeling-basics/gizmo-3d/gizmo-3d.html(.md)
- Universal move/rotate/scale manipulator; a compact alternative to the TransPose action line with most of its features. Also deformers and parametric primitive insertion.

## [H] Gizmo 3D: Basic Operations
URL: https://help.maxon.net/zbr/en-us/Content/html/user-guide/3d-modeling/modeling-basics/gizmo-3d/basic-operations/basic-operations.html(.md)
- Activate Move/Scale/Rotate (Transform palette or icons above canvas), then the Gizmo icon (right of Rotate). Gizmo is default. Y toggles Gizmo vs TransPose (shared position/orientation). With Gizmo active, the separate M/S/R modes don't matter.
- Short click on any model surface (even inactive SubTools) moves the gizmo there, oriented to that polygon. Click-drag sets position at the start point, blue Z along the drag direction.
- Reset: Mesh to Axis + Reset Mesh Orientation operators with Unlock mode.
- Move: drag R/G/B arrows; screen-plane arrows. Scale: drag rectangles (Alt = 2-axis planar); yellow center = uniform. Rotate: circles; grey = view axis; Shift = 5° snap.
- UX NOTE: click-to-place-pivot-on-surface is fast and touch-friendly.

## [H] Gizmo 3D: List of Deformers
URL: https://help.maxon.net/zbr/en-us/Content/html/user-guide/3d-modeling/modeling-basics/gizmo-3d/deformers/list-of-deformers/list-of-deformers.html(.md)
- Deformers (non-destructive, bounding-box based, with colored handles on the box): Bend Arc; Bend Curve (control curve, per-point twist/scale/squeeze); Bevel (crease angle); Crease; Deformer (FFD cage, X/Y/Z Divide, Shift-click multi-select points, Gizmo moves points); Deformer Hard/Soft; Extender (insert movable loop); Flatten (Slice Topology option); Inflate; Multi Slice (edge loops ignoring flow); Offset; Project Primitive (superquadric projection; colored handles: yellow type, blue axis, orange modifiers, white Accept, purple New Surface, pink Blend/Opacity; Tesselate; radial symmetry; Shift = snap / 0.1 steps; Shift-click resets to 0.5); Remesh by DynaMesh / Union / ZRemesher / Decimation; Rotate; Scale; Skew; Slice; Smooth (0-500); Smooth All; Stretch; Subdivide (smooth/faceted); Taper; Twist.
- CAVEATS: Remesh by Union ignores fully masked models. High Tesselate hurts performance. Subdivide deformer affects partially masked objects fully. Keep UVs in Decimation costs memory.
- UX NOTE: deformers = a parametric modifier stack on a box, with handle colors encoding parameter types.

## [H] Dynamic Subdivision
URL: https://help.maxon.net/zbr/en-us/Content/html/user-guide/3d-modeling/modeling-basics/dynamic-subdivision/dynamic-subdivision.html(.md)
- Smooth preview without dividing polygons; for ZModeler/low-poly. 1 dynamic level = 1 classic divide. Supports creases, chamfered edges, non-smoothed (flat) subdivision. Brushes edit the base cage; changes show live. QGrid with Bevel/Chamfer gives real-time bevels.

## [H] Dynamic Subdivision: Hotkeys
URL: https://help.maxon.net/zbr/en-us/Content/html/user-guide/3d-modeling/modeling-basics/dynamic-subdivision/hotkeys/hotkeys.html(.md)
- D / Shift+D are shared. With classic levels present they step levels. With only Dynamic, they toggle the Dynamic display. With both, they navigate classic levels. Dynamic modes have no default hotkeys (assignable).
- PAIN POINT: one key changes meaning by mesh state.

## [H] Keyboard Shortcuts by Category (authoritative full list)
URL: https://help.maxon.net/zbr/en-us/Content/html/user-guide/keyboard-shortcuts/shortcuts-by-category/shortcuts-by-category.html(.md)
- GENERAL: Ctrl+O open; Ctrl+S save; Ctrl+Z / Shift+Ctrl+Z; popups (PC, cursor off canvas): F1 Tools, F2 Brushes, F3 Strokes, F4 Alphas, F5 Textures, F6 Materials (NB: the Customizing>Hotkeys page lists a different F-key order, so the docs are inconsistent); Space or right-click = QuickMenu; Tab = floating palettes; Ctrl+hover = popup info; Ctrl+Alt+hover = alt info; Ctrl+Alt+click item = assign hotkey; G = Projection Master.
- LIGHTBOX/SPOTLIGHT: , = LightBox; Shift+Z = Spotlight on/off; Z = Spotlight dial.
- NAV: see Navigation entry.
- TRANSPOSE ACTION LINE: in W/E/R draw a line; Space while drawing moves it; drag orange line/center ring to move it; drag end rings to reposition ends; Alt+drag on mesh moves/scales the mesh. Move mode: drag center = move; Ctrl+drag center = duplicate (or edge loop + extrude on partially masked mesh); Alt+drag center/end = bend; drag far end = stretch; near end = flatten; right-drag far end ring = inflate. Scale mode: drag end = scale along line; center = axis scale; Ctrl+drag center = edgeloop + inflate. Rotate mode: drag end = rotate about other end; center = spin about line; Alt+drag end = joint bend.
- SCULPT/PAINT: S size; O focal; I RGB intensity; U Z intensity; ] / [ size; T edit mode; Q/W/E/R; Alt = ZAdd/ZSub.
- BRUSH CHORDS: B popup; B,S,T Standard; B,S,S Smooth Stronger; B,M,E Move Elastic; B,M,P MPolish; B,C,C ClipCurve; B,C,L ClayLine. IMM: M shows all meshes.
- COLOR: C pick; V swap. STROKE: L Lazy Mouse; 1 replay last; 3 record; 2 replay all recorded. CURVES: 6 smooth; 5 snapshot; Alt+draw across = delete.
- 3D: Shift+Ctrl+T save tool; F frame; P perspective; Shift+P floor (also listed as clear pivot); X symmetry; Shift+F polyframe/polygroups; Shift+Ctrl+P point selection mode; Ctrl+P set pivot; Shift+S snapshot.
- SUBTOOLS: N list; Alt+click select; Shift+Alt+click frame (Preferences > Edit > Enable Auto Center 0/1/2); paintbrush icon (Shift = all).
- GEOMETRY: Ctrl+D divide; Shift+D lower; D higher; Ctrl+E edge loop (partially hidden mesh). DYNAMESH: Ctrl+drag background. HD: A over mesh / A over background.
- MASKING: Ctrl+H view mask; Ctrl+I invert; Ctrl+A mask all; Ctrl when picking a brush = mask brush; Ctrl paint; Ctrl+Alt erase; Ctrl+click bg invert; Ctrl+click-drag bg clear; Ctrl+click, release, drag from off mesh = constant-intensity mask; select alpha while holding Ctrl = alpha-intensity mask; Ctrl+click mesh blur; Ctrl+Alt+click sharpen. Topological: Ctrl+drag action line on model. Ctrl+W = group masked and clear mask.
- VISIBILITY: as in Mesh Visibility, plus Ctrl+Shift+X/S/A/O grow/shrink/grow-all/outer ring.
- STENCIL: Alt+H on; Ctrl+H hide; Space = Coin Controller.
- ZSPHERES: A preview adaptive skin. Draw: drag = child; Alt+click = delete; Shift while dragging = same size; Ctrl+drag = scale link spheres; click link sphere = insert. Move: drag link = pose; Alt+drag link = move chain. Scale: Alt+drag link = inflate chain. Rotate: drag sphere = spin; Alt+drag link = twist.
- ZSKETCH: Shift+A edit; A unified skin.
- CANVAS 2.5D: Alt reverses; Shift+Ctrl+F crop & fill; Shift+Ctrl+G grab texture; layers Ctrl+N clear / Ctrl+F fill / Ctrl+B bake; ~ (US) or @ (UK) + click/drag = select/move layer; Ctrl+M remove marker; 0 / Ctrl+0 / + / - zoom.
- TIMELINE: click = keyframe; drag dot off = delete; Shift+Ctrl+click = store; Shift+click copy; Ctrl+click = transition key; Alt+click = rigid key; Left/Right arrows = camera keys; Shift+click cursor = play; Esc stop; Shift+Ctrl+click cursor = record movie.
- RENDER: Shift+R BPR; Shift+Ctrl+R render all; Ctrl+R cursor selective.
- CUSTOM UI: Ctrl+Alt+drag (Enable Customize) move; Ctrl+Alt+drag to canvas removes; Shift+Ctrl+I store config; Ctrl+L load UI; Shift+Ctrl+Alt+I save UI.
- ZSCRIPTS: Shift+Ctrl+L load; Ctrl+U reload; H ZScript window.
- UX NOTE: about 200 bindings, heavy on mid-drag modifier changes and "where you click" semantics (background vs mesh vs action-line ring).

## [H] Customizing ZBrush: Hotkeys
URL: https://help.maxon.net/zbr/en-us/Content/html/user-guide/customizing-zbrush/hotkeys/hotkeys.html(.md)
- Ctrl+Alt+click any button/slider/palette, then press a key (Esc cancels). Brushes: Ctrl+Alt+click in the Brush palette/popup. The mouse wheel can be bound to a slider (e.g. Draw Size) since 4R5. Change a brush's chord letter: B, letter, Ctrl+Alt+click icon, new key.
- Palette hotkeys open the palette centered under the cursor.
- Preferences > Hotkeys: Store (permanent, StartupHotkeys.txt in Public/ZBrushData/ZStartup/Hotkeys), Save, Load, Restore (DefaultHotkeys.txt; unavailable after Store).
- PAIN POINTS: no documented single-hotkey removal; Restore unavailable after Store; files live in a shared public folder.

## [H] Interface Operation
URL: https://help.maxon.net/zbr/en-us/Content/html/user-guide/customizing-zbrush/interface-operation/interface-operation.html(.md)
- Palettes can be moved into left/right Trays (click the palette icon, or drag it). Shift+Ctrl+I or Preferences > Config > Store Config saves the layout.
- Auto Collapse (Preferences > Interface > Palettes). Left Tray allows one expanded palette by default; Right Tray allows several.
- Sub-palettes: one open at a time by default; Shift+click opens several (Preferences > Interface > Palettes > Open One Subpalette). Sections (UI Groups) likewise (AutoClose UI Groups).
- Popup modes: Subpalette Popup / Palette Popup show one at a time with an alphabetical picker list.
- PAIN POINT (admitted): "ZBrush does not save preferences automatically". Must Store Config; disabling popup modes may need a restart.
- UI ELEMENTS: Palettes (top menu bar of master menus) > Sub-palettes > UI Groups (sections) > buttons/sliders; Trays (left/right); Shelves (around canvas).

## [H] Custom Interface
URL: https://help.maxon.net/zbr/en-us/Content/html/user-guide/customizing-zbrush/interface-layout/custom-interface/custom-interface.html(.md)
- Preferences > Config > Enable Customize, then Ctrl+Alt+drag items onto highlighted boxes. Invalid drop from a custom location removes the item; from a master menu nothing happens (master menus are editable only via ZScript/plugins). Overlaps are possible.
- Areas: Trays (whole menus only; handle click sends a menu to the top), Shelves around the canvas (single elements), Custom menu list above the status bar (menus only, collapsed; title bar "Menus" button hides master menus).
- Custom UI > Create New Menu (appears far right; move it into a tray; rename with Ctrl+Alt+click). Items fill left-to-right then top-to-bottom. Widths full/3/4/1/2/1/4/(1/3); default height 1/8. Separators and Custom SubPalette from Preferences > Custom UI.
- Ctrl+Shift+I = save as default; Alt+Ctrl+Shift+I = save alternate; Ctrl+L or Preferences > Config > Load UI.
- PAIN POINTS: a menu can be removed only by restarting without saving config; contextual items may vanish on reopen; dragging items off loses them.

## [H] Customizing ZBrush: Navigation
URL: https://help.maxon.net/zbr/en-us/Content/html/user-guide/customizing-zbrush/navigation/navigation.html(.md)
- Same as Navigation entry: Preferences > Interface > RightClick Navigation toggle; classic vs right-click mappings. No sensitivity or remap options documented.

## [H] DynaMesh
URL: https://help.maxon.net/zbr/en-us/Content/html/user-guide/3d-modeling/modeling-basics/creating-meshes/dynamesh/dynamesh.html(.md)
- Free-form base mesh tool for low/mid-resolution stages. Keeps uniform polygon distribution as volume is added. Push/pull, add pieces (union), remove (boolean-like).
- DynaMesh is a mode on primitives, or convert existing geometry (Resolution slider). Conversion discards the original topology.
- Remesh: hold Ctrl and drag on open canvas, any time. Only edited surface is re-distributed.
- Tool > Geometry. Fuse via inserted meshes, SubTools, or Mesh Fusion.
- BEST PRACTICE: use early (not after detailing); remesh regularly to avoid stretching.

## [H] DynaMesh Options
URL: https://help.maxon.net/zbr/en-us/Content/html/user-guide/3d-modeling/modeling-basics/creating-meshes/dynamesh/options/options.html(.md)
- Resolution (density vs speed; detail kept while the mesh fits inside the resolution cube, given as 2048 or 1024^3; a high resolution limits how far the bounds can grow between remeshes). Group (split by polygroups into separate pieces within one SubTool). Project (re-project details onto the new DynaMesh) plus Blur (smoothing with Project). Polish (applies ClayPolish each update). Thickness (shell thickness, relative to resolution).
- PAIN POINT: detail loss when the mesh outgrows the voxel cube; the docs give conflicting cube sizes.
- DATA STRUCTURE: voxel grid resolution relative to bounding box (volumetric remesh).

## [H] Using Sculptris Pro
URL: https://help.maxon.net/zbr/en-us/Content/html/user-guide/3d-modeling/modeling-basics/creating-meshes/sculptris-pro/using-sculptris-pro/using-sculptris-pro.html(.md)
- Requires a PolyMesh3D with NO subdivision levels (not primitive or ZSphere). Otherwise brushes behave normally and the cursor stays red. Toggle: button above canvas / Stroke >> Sculptris Pro (cheat sheet hotkey \).
- CURSOR COLOR: purple = active and compatible; orange = smooth brush (smooth + tessimate); red = incompatible. Colors set in Preferences >> Edit.
- Draw Size controls density (large brush = large tris); global options: constant tessimation independent of size, tessellate-only (no decimation), size influence.
- PolyPaint works (adds tris for fine paint). Masks modulate tessimation.
- UNSUPPORTED: backface masking; DragRect/DragDot strokes (only Dots/FreeHand/Spray); content-generating brushes (IMM, Curve...); UVs not preserved; Mask By Polygroups auto-masking. 2021.6 added partially hidden meshes, Chisel3D/VDM, Snake Curve.
- UX NOTE: cursor color as compatibility/mode feedback.

## [H] ZRemesher: Introduction
URL: https://help.maxon.net/zbr/en-us/Content/html/user-guide/3d-modeling/topology/zremesher/introduction/introduction.html(.md)
- Auto retopology with flow control and a global target count (e.g. 200k DynaMesh to 10k in seconds); one button. Tool > Geometry.
- Input must be PolyMesh3D (Make PolyMesh3D for primitives; make adaptive/unified skin for ZSpheres/ZSketch).
- Control curves drawn on the model guide edge flow.
- Downstream: project detail from the original, UV Master, maps.

## [H] Live Boolean: Important Information
URL: https://help.maxon.net/zbr/en-us/Content/html/user-guide/3d-modeling/modeling-basics/creating-meshes/live-boolean/important-information/important-information.html(.md)
- Rules differ from DynaMesh (the preview is unaffected). Avoid coplanar faces (offset slightly). Use watertight volumes, not single-sided surfaces. Keep density consistent (dense vs low-poly makes slivers that break later booleans). Lower Dynamic Subdiv levels (they become real geometry first). Remove non-manifold edges.

## [H] Live Boolean: Performance
URL: https://help.maxon.net/zbr/en-us/Content/html/user-guide/3d-modeling/modeling-basics/creating-meshes/live-boolean/performance/performance.html(.md)
- The preview processes all SubTools in real time and slows display/navigation. Avoid high Dynamic Subdiv; keep document size reasonable on Retina; turn off Render > Render Booleans > Show Coplanar. "3D display is CPU-based, not GPU-based", so big pixel counts are slow.
- Final mesh: about 60M polys needs 24GB+ RAM and about 4-5 min (i7). About 1M is under a minute.
- BEST PRACTICE: lower subdiv/DynaMesh resolution if fine detail isn't needed.

## [H] Live Boolean: Basic Process
URL: https://help.maxon.net/zbr/en-us/Content/html/user-guide/3d-modeling/modeling-basics/creating-meshes/live-boolean/basic-process/basic-process.html(.md)
- PolySphere.ZPR; Tool >> SubTool >> Duplicate (Ctrl+Shift+D); Gizmo to move/scale; click the Subtraction operator icon in the SubTool list row; Render >> Render Booleans >> Live Boolean; edit or sculpt live; Tool >> SubTool >> Boolean >> Make Boolean Mesh produces a new Tool.
- CAVEATS: Make Boolean Mesh is unavailable unless Live Boolean is on and there are 2+ SubTools.
- UI ELEMENT: per-row boolean operator icons in the SubTool list (add / subtract / intersect).

## [H] ZModeler: Introduction (Essentials)
URL: https://help.maxon.net/zbr/en-us/Content/html/user-guide/3d-modeling/modeling-basics/creating-meshes/zmodeler/introduction/introduction.html(.md)
- Brush chord B, Z, M. Hover over the model and press Space (recommended) or right-click to get the ZModeler popup. Over empty canvas or a non-selected SubTool you get the default popup instead (pain point).
- Popup sections: Actions, Targets, Options, Modifiers (overlapping concepts).
- Workflow: hover over a point/edge/polygon/curve (contextual menu), choose Action + Target, set options, click and drag (horizontal vs vertical drag gives different results). Replay repeats the last action with one click.
- ZModeler is a brush, not a mode. PolyMesh3D only; not for very high poly counts; best without subdivision levels (Freeze SubDivision Levels); quads and tris only (n-gons auto-split).
- BEST PRACTICE: work at base level with Dynamic Subdivision preview.
- UX NOTE: a hover-context radial/popup menu that changes by element under cursor is a good touch analogue (long press on element).

## [H] ZModeler: Actions and Targets
URL: https://help.maxon.net/zbr/en-us/Content/html/user-guide/3d-modeling/modeling-basics/creating-meshes/zmodeler/actions-and-targets/actions-and-targets.html(.md)
- Action (Extrude, Move, Bridge, Split, Poly Move...) x Target (point, edge, polygon, border, polygroup, edge loop, island...). Poly Move targets: Move Poly, Move All Mesh, Move Brush Radius, Move Curved Island, Move Flat Island, Move Island, Move PolyGroup All, Move PolyGroup Island.
- PAIN POINT: missing functions usually mean you hovered over the wrong element type.
- DATA STRUCTURE: action/target matrix (verb x selection scope), a composable command grammar.

## [H] Sculpting Brushes
URL: https://help.maxon.net/zbr/en-us/Content/html/user-guide/3d-modeling/sculpting/sculpting-brushes/sculpting-brushes.html(.md)
- Modifiers (Gravity, Wrap Mode, Density...); save brush variants. Categories: Sculpting, Smooth, Clip, Curve, Planar/Trim/Polish, Groom, Pen, InsertMesh, Curve Bridge, ZSketch, Alpha 3D.
- Brushes: Standard (Alt inverts to carve), Smooth, Move (ignores strokes), Inflat (per-vertex normals), Elastic, Displace, Magnify (inverse Pinch), Blob, Pinch, Flatten (plane from surface under brush center; white alpha for perfectly flat), Clay, Morph (needs morph target), Layer (fixed height; with morph target = constant depth), Nudge (slides along surface), SnakeHook (pair with DynaMesh), ZProject.
- WORKFLOW TIPS: Smooth then Flatten; Pinch with LazyMouse in multiple passes; Spray + Inflat for spikes.
- CAVEATS: Flatten plane shifts; Morph brush needs a stored morph target.

## [H] Lazy Mouse 2.0
URL: https://help.maxon.net/zbr/en-us/Content/html/user-guide/3d-modeling/sculpting/sculpting-brushes/lazy-mouse-2-0/lazy-mouse-2-0.html(.md)
- LazySnap (Stroke >> Lazy Mouse >> LazySnap): a new stroke starting near the previous end continues it. Backtrack and Line mode give straight lines.
- Straight line: during a stroke hold Shift, a preview line with angle readout snaps to 45°; release Shift while holding the click to draw it.
- Stroke pause: while holding the click, hold Space (cross cursor), reposition, release to resume with the same brush/pressure.
- Non-buildup crossings (Chisel/Layer only): Lazy Mouse on, Tool >> Morph Target >> StoreMT first.
- PAIN POINT: pen pressure doesn't carry across joined strokes, leaving seams. Fix: flatten the Brush >> Tablet Pressure curves (Size/Z Intensity at 100) or use a mouse.
- (Lazy Mouse hotkey L; LazyStep/LazySmooth/LazyRadius not documented on this page.)

## [H] Alphas
URL: https://help.maxon.net/zbr/en-us/Content/html/user-guide/3d-modeling/sculpting/sculpting-brushes/alphas/alphas.html(.md)
- Alpha = 16-bit grayscale intensity map. It shapes strokes, masks, color/material application; can become Stencils. Displacement/bump export as alphas.
- Alpha palette or Current Alpha thumbnail popup; Load Alpha (color converted to gray). Use 16-bit uncompressed grayscale (PSD without compression; TIFF compression NONE) to avoid stairstepping. GrabDoc captures canvas depth as an alpha. Saved at full source resolution.

## [H] Strokes (sculpting strokes tutorial)
URL: https://help.maxon.net/zbr/en-us/Content/html/user-guide/3d-modeling/sculpting/sculpting-brushes/strokes/strokes.html(.md)
- DragDot (single alpha at the drag end, for logos/text); Dots (closely spaced instances; slow = uniform, fast = blotchy); DragRect (centered at the start; drag distance = size, circling = rotation; Draw Size ignored); Freehand + LazyStep (repeat alpha at intervals, e.g. rivets; LazyMouse on, LazyStep 1.5); Freehand + Roll (stretch tileable alpha along the stroke, Roll Dist; Shift after click constrains the line); Spray / Colorized Spray (scatter; spacing, scale fluctuation, density).
- Tutorial uses Symmetry with Radial (R) and RadialCount; new named layer per stroke type (best practice). Reset All Brushes at the bottom of the Brush palette.
- Setup facts: draw Cylinder3D, T = Edit mode; Tool > Initialize sizes; Make Polymesh3D; Divide x5 is about 525k polys.

## [H] Symmetry
URL: https://help.maxon.net/zbr/en-us/Content/html/user-guide/3d-modeling/sculpting/symmetry/symmetry.html(.md)
- Types: axis (X/Y/Z), Poseable (topology-based via SmartResym), Radial (R + Radial Count). Transform palette > Activate Symmetry, then press X/Y/Z, Use Poseable Symmetry, R.
- Poseable: set SDiv to the highest level, then Use Poseable Symmetry. Brush radius GREEN = active, RED = not.
- CAVEATS: poseable needs 100% symmetric topology; fails on meshes symmetric on several axes (sphere); dividing reverts to normal symmetry (re-press it); axis symmetry fails on posed models; n-gon base meshes cause around 50% breaks.

## [H] 3D Layers
URL: https://help.maxon.net/zbr/en-us/Content/html/user-guide/3d-modeling/sculpting/3d-layers/3d-layers.html(.md)
- Non-linear workflow: detail on its own layer, hide it to refine forms; store poses/expressions (Maya Blend Shapes plugin export); geometry + polypaint + mask; animate via Timeline. Order matters (read top to bottom). Tool > Layers; REC icon, eye, Intensity slider per row.
- New layers turn Record on. Sculpting without Record shows a prompt.
- SUBDIV RULES: create layers at the TOP subdivision level; in Record you can sculpt at any level but must return to the top to turn Record off; adding levels transfers layers to the top (one-way).
- Erase polypaint on a layer: Alt-stroke. Erase sculpt: hide layer, StoreMT, unhide, Morph brush.
- Bake one layer: top level, set intensity, StoreMT, delete layer, Switch. CAVEAT: baking loses polypaint/mask (split first).
- PAIN POINTS: many subdivision-level constraints and one-way transfers.

## [H] Morph Targets
URL: https://help.maxon.net/zbr/en-us/Content/html/user-guide/3d-modeling/sculpting/morph-targets/morph-targets.html(.md)
- Stores a geometry configuration (one per SubTool, tied to the subdivision level). Uses: restore base before map generation; partial restore with the Morph brush. Tool > Morph Target (StoreMT / Switch / Delete).
- CAVEAT: any point add/delete destroys it. For variations, use 3D Layers.

## [H] Polypaint
URL: https://help.maxon.net/zbr/en-us/Content/html/user-guide/3d-modeling/painting-your-model/polypaint/polypaint.html(.md)
- Paint without a texture map; transfer later; defer resolution and UVs; removing UVs frees resources.
- Setup: enough polygons; Tool > Polypaint > Colorize ON; Zadd/Zsub OFF; Rgb ON, RGB Intensity 100; pick color, paint. Gradient button (Color palette / below picker) blends main and secondary colors.
- UX NOTE: painting = the same brush with Zadd off and Rgb on (channel toggles rather than separate tools).

## [H] SpotLight (painting)
URL: https://help.maxon.net/zbr/en-us/Content/html/user-guide/3d-modeling/painting-your-model/spotlight/spotlight.html(.md)
- Dial widget: move it by clicking a texture/document; drag between the orange circle and the outer ring to move the texture + widget; icons toggle functions (Hue, Clone, Smudge...); center = pivot for rotate/scale; red outline = affected texture; lock = group control.
- Shift+Z toggles SpotLight (Texture palette > Turn On SpotLight); Z toggles 3D paint mode vs edit; double-click in LightBox adds a texture. Save/Load SpotLight in the Texture palette.
- Workflow: enough polys (it uses PolyPaint; no UVs needed); hide texture maps; Texture palette load; Add to SpotLight; arrange; Z paint; Shift+Z exit. Multiple textures: click one to select, click empty canvas to select all (temporary group).
- CAVEATS: a visible texture map hides polypaint; Z does nothing if Spotlight Radius = 0; loading a set overwrites the current one.

## [H] MatCap Basics
URL: https://help.maxon.net/zbr/en-us/Content/html/user-guide/materials-lights-rendering/materials/matcap/matcap-basics/matcap-basics.html(.md)
- MatCap = material captured from a photo: samples of normal plus color build a lookup (lighting baked in). MatCap tool: load the photo (Texture > CropandFill with Flat Color), pick a MatCap material, click-drag on the image to set 4-8 normals; Ctrl-drag on a highlight sets specularity; fine-tune in Material > MatCap Maker. A lightball previews the result.
- CAVEATS: non-uniform materials capture poorly; don't put diffuse normals on highlights.

## [H] Materials
URL: https://help.maxon.net/zbr/en-us/Content/html/user-guide/materials-lights-rendering/materials/materials.html(.md)
- Types: Flat Color, FastShader, BasicMaterial family (Toy Plastic, Double/Tri/QuadShader), Fiber, MatCap (ignores the Light palette).
- 3D: a new material applies to the whole model in Edit mode by default. To embed per-vertex materials, turn on M or MRGB (Draw palette), Color > Fill Object with a base material, then paint other materials. Embedding Flat Color clears embedded materials.
- ZStartup/Materials loads at startup (keep to 25 or fewer for performance). Material > Load replaces the selected slot (destructive to its uses). Slot count is fixed after startup.
- DATA STRUCTURE: per-vertex material index (M channel) plus RGB.

## [H] BPR (Best Preview Render)
URL: https://help.maxon.net/zbr/en-us/Content/html/user-guide/materials-lights-rendering/rendering/bpr/bpr.html(.md)
- Renders the model in Edit mode with high-quality AA at full document size; all SubTools; polyframes if on; SSS, fibers. Render > BPR RenderPass; BPR button + SPix slider top-right in the default UI (Shift+R). Document > Export saves; per-pass export icons in BPR RenderPass.

## [H] Undo History (desktop)
URL: https://help.maxon.net/zbr/en-us/Content/html/user-guide/3d-modeling/undo-history/undo-history.html(.md)
- ZPR only (not OBJ/ZTL); persists across sessions; replay as movie. Max 10,000 steps; Max Undo History slider; Warn When Deleting slider (confirm before discarding many steps).
- Linear: a new action after undo truncates forward steps (even invisible ones like StoreMT). Some ops (Merge SubTools) clear ALL history (with warning).
- UI: Undo selector bar at the top of the document (one rectangle per step; click to jump, drag marker to scrub); Edit > Tool: Undo Counter slider, Del UH (current Tool/SubTool), Restore Placement (camera at that step), Store (camera).
- Preferences > Undo History: Show Undo Selector (default on), Show Time Stamp, Enable Saving, Skip Loading.
- PAIN POINTS: history grows file size; destructive ops wipe history.

## [H] Selection Sets (2027)
URL: https://help.maxon.net/zbr/en-us/Content/html/user-guide/selection-sets/selection-sets.html(.md)
- Tool > Selection Sets (below Geometry). Rows: Polygroups, Masking, Polypainting, UVs, MorphTargets. Unlimited named sets per row. "+" stores, list/arrows recall (orange field = selected). Row icons act on the live SubTool (clear/invert/hide mask, fill polypaint, delete UVs, polyframe toggle).
- Buttons: Update, Reload (refit to current subdiv level), Duplicate, Rename, Switch, Edit (reorder), Copy All Sets/Paste/Clear (paste only to identical topology). Delete options include "invalid sets".
- Polygroup sets use their own reprojection (borders closer to high-res). Masks reload at any level. MorphTargets: Store/Switch/Morph brush; sliders Morph, Width, Height, Project.
- CAVEATS: DynaMesh, ZRemesher and Sculptris Pro change topology and BREAK sets (broken polygon icon; must delete or overwrite). Stored in ZTL/ZPR (file size). Clipboard copies of dense meshes take memory (50M polys is about hundreds of MB).
- DATA STRUCTURE: named snapshots of per-vertex/per-face attribute layers keyed to topology.

## [H] UV Editor (2027, desktop only)
URL: https://help.maxon.net/zbr/en-us/Content/html/user-guide/uv-editor/uv-editor.html(.md)
- Tool > UV Map > UV Editor with scope All / Visible / Selected. Tabs: Create UVs, Unwrap Tools, Edit UV Tools, Packing Tools. Apply UV Edits / Cancel UV Edits (prompt "send back?").
- Layout 1: Objects panel (top-left, SubTools + tags), 3D view (bottom-left), UV view (center; View/Display/Filter/Textures menus; Resolution, TD), UV toolbar (selection modes, M/R/S, Rect select), Attributes (right), Options (90° rotations, nudge, move to tile). Layouts 1-4; save custom layouts.
- Tags: Polygroup, Material, Normal, UVW; Unwrap by PolyGroup creates a "Seams" edge selection tag.
- NAV (C4D-style, differs from ZBrush canvas!): right-drag rotate, Ctrl+right-drag zoom, Alt+right-drag pan.
- HOTKEYS: 1/2/3/4 Model/Poly/Edge/Point; W/E/R Move/Rotate/Scale (NB: in ZBrush canvas E = Scale, R = Rotate, so this conflicts); C disconnect (cut); P pack; S frame selected; H frame all; double-click = island; Command Manager for custom keys; right-click > Show Help.
- PAIN POINTS: ZBrush is locked while the editor is open; Visible scope skips hidden SubTools; the 3D view doesn't auto-refresh; it is an embedded C4D UI with different conventions.

## [H] NanoMesh
URL: https://help.maxon.net/zbr/en-us/Content/html/user-guide/3d-modeling/nanomesh/nanomesh.html(.md)
- Part of ZModeler; extends InsertMesh/MicroMesh. Populates selected polygons with instanced geometry; per-instance scale/offset/angle live; random mode; layered NanoMeshes; UV/texture during editing; edit the source (any brush) and all instances update.

## [H] ArrayMesh
URL: https://help.maxon.net/zbr/en-us/Content/html/user-guide/3d-modeling/array-mesh/array-mesh.html(.md)
- Pattern instancing, real time; multi-stage nesting (treads, facades); source edits cascade. Array Mesh sub-palette sliders (Tool > PolyMesh > Array Mesh); pairs with TransPose. Subtopics: Stages, Transpose, Pivot Point, with NanoMesh, Presets.
- DATA STRUCTURE: source mesh + stack of array stages (procedural instancing, non-destructive until converted).

## [H] Decimation Master
URL: https://help.maxon.net/zbr/en-us/Content/html/user-guide/zbrush-plugins/decimation-master/decimation-master.html(.md)
- Zplugin palette. Steps: options, then Preprocess current/all (builds temporary progressive meshes 100% to 0%), then Decimate / Decimate all by % or k-points/k-polys.
- Options: Freeze Borders, Keep UVs (+50% memory), Polypaint Weight, Keep & Use PolyPainting. Masks redistribute density (same count). Symmetry plane from Transform > Activate Symmetry. Unique SubTool names needed.
- Quality: 40-100% looks nearly identical; about 2% still good; below about 1% loss is visible.
- Utilities: Delete Caches (not undoable), Export All SubTools to one OBJ (no polygroups).
- Prefs saved separately (DecimationMaster.cfg; Store Config doesn't save them): Uniform Mesh, threads, delete caches at start, 64-bit.
- PAIN POINTS: polygroups lost; decimation uses the preprocess-time state (re-preprocess after edits); huge temp files not auto-deleted; duplicate names show the wrong SubTool; Esc to stop.

## [H] UV Master
URL: https://help.maxon.net/zbr/en-us/Content/html/user-guide/zbrush-plugins/uv-master/uv-master.html(.md)
- One-click UV creator (not an editor; no manual seam painting). Work on Clone (CL_ prefix, lowest level, Skin4 material); Unwrap / Unwrap All; Flatten (sculpt the 2D layout with Move; Smooth stretches) / UnFlatten; Check Seams (orange seams, brown openings, as polypaint); Copy/Paste UVs.
- Options: Symmetry, Use Existing UV Seams, Polygroups (islands from groups; faster and better).
- Control Painting: Protect (about 70-100% strength; a full protected loop still forces a seam), Attract (100%), Attract from AO, Erase, Density (x/÷ 1-4; cyan negative, green-white positive). Save/Load/Clear control maps (data folder wiped at startup; tied to the Tool name).
- LIMITS: about 100-150k polys recommended; 3k polys takes seconds, 150k up to about 5 min. One UV space only.
- CAVEATS: no feature awareness (seams can cross a face); seams prefer cavities and long paths; non-manifold edges add seams; holes/handles need cuts; Flatten is temporary (UnFlatten before switching Tools).

## [H] GoZ: About
URL: https://help.maxon.net/zbr/en-us/Content/html/user-guide/zbrush-other-programs/goz/about-goz/about-goz.html(.md)
- One-click round trip of meshes + maps. Tool palette top buttons: GoZ (current Tool/SubTool), All, Visible, R (reset target app). Native: 3ds Max (Win), Maya, C4D R15-17, Photoshop CC; third party: C4D R20+, Character Creator, Marvelous Designer, Modo, LightWave, Poser, DAZ, Houdini...
- CAVEATS: version-specific, partly outdated list; Photoshop 3D deprecated.

## [H] Transpose Master
URL: https://help.maxon.net/zbr/en-us/Content/html/user-guide/zbrush-plugins/transpose-master/transpose-master.html(.md)
- Zplugin > Transpose Master. TPoseMesh (combine all SubTools at low res into one posable mesh), pose with Transpose/ZSphere rig, TPose>SubT (transfer back). Options: ZSphere Rig, Grps (keep polygroups vs one per SubTool), Layer (new 3D layer per SubTool), StoreTM Rig / PasteTM Rig. Data saved in ZPR (4R6+).
- BEST PRACTICE: low-poly meshes with subdivision levels; for Sculptris Pro meshes, ZRemesh + project first.
- PAIN POINTS: partially hidden SubTools give a "Vertex Mismatch"; Gizmo3D modifiers can change point order and destroy SubTools; it can pick the wrong model; workaround is to load into a clean DefaultCube.ZPR.
- UX NOTE: shows the "cannot pose multiple SubTools at once" limitation needing a plugin workaround.

## [H] ZScripting (overview)
URL: https://help.maxon.net/zbr/en-us/Content/html/user-guide/customizing-zbrush/zscripting/zscripting.html(.md)
- ZScript = built-in scripting language underlying recordings, tutorials, macros and plugins. Learning paths: Getting Started, Nuts & Bolts, Advanced, Technical; interfaces: ZPlugin, Note, Tutorial Window; Command Reference; FileUtils. Python isn't mentioned here (the marketing page says Python is now standard).

## [H] Macros
URL: https://help.maxon.net/zbr/en-us/Content/html/user-guide/customizing-zbrush/macros/macros.html(.md)
- Macro > New Macro records everything (buttons, rotations, strokes); Macro > End Macro. Save into a SUBFOLDER of ZStartup\Macros with a name of 8+ characters (the file name becomes the button label); a new subfolder appears only after restart. Reload All Macros. Macros are plain ZScript text, can be placed in a custom UI and bound to hotkeys. Esc aborts.
- PAIN POINTS: strict naming/folder rules; recordings capture unintended actions.

## [H] ZTools and Edit Mode
URL: https://help.maxon.net/zbr/en-us/Content/html/getting-started/basic-concepts/ztools-and-edit-mode/ztools-and-edit-mode.html(.md)
- Tools add/modify pixols on the canvas. After click-dragging a primitive onto the canvas, the last stroke stays in a "waiting state" with Move/Scale/Rotate/Edit. Turn on Edit (T) right after drawing to sculpt in 3D.
- PITFALL (major beginner pain point the doc admits): any other action "drops" the object to the canvas as 2.5D pixols, after which it can't be edited in 3D. Recovery: clear the canvas (Ctrl+N) or Ctrl+Z, reselect the Tool, redraw, then Edit.
- Transform > Snapshot leaves an instance copy on the canvas.
- UX NOTE: the hybrid 2.5D canvas/3D tool model is a well-known onboarding hazard; a new app should avoid it.

## [H] Finding Your Way Around (interface)
URL: https://help.maxon.net/zbr/en-us/Content/html/getting-started/finding-your-way-around/finding-your-way-around.html(.md)
- Layout: palette buttons (top menu row, grouped by feature); Canvas/Document (center); Shelves left/top/right around the canvas with frequent items (TAB shows/hides); Trays left/right for docked palettes (click the inner-edge divider; double-click to open).
- Sub-palettes and UI Groups: one open by default; Shift+click for more (Preferences toggles).
- CAVEAT: preferences don't auto-save (Shift+Ctrl+I / Store Config). "Hotkeys and mouse actions are used extensively."

## [H] Saving Your Work
URL: https://help.maxon.net/zbr/en-us/Content/html/getting-started/basic-concepts/saving-your-work/saving-your-work.html(.md)
- Document = canvas 2.5D pixols only (no 3D). ZTool = one 3D object with SubTools, subdivisions, settings, 3D layers. Project (ZPR) = multiple ZTools + scene (large).
- QuickSave (9): saves a Project to Public/ZBrushData/QuickSave as QSave###; MaxQuickSave pref; LightBox QuickSave tab; "UH" suffix = includes undo history. AutoSave periodic or on idle to a dedicated AutoSaveProject.ZPR; offered after a crash.
- BEST PRACTICE (doc): save incrementally about every hour under new names, keep 3+ versions ("files can corrupt"); save ZTools for 3D, not Documents.
- PAIN POINT: three overlapping file concepts (ZBR/ZTL/ZPR) confuse beginners; undo history only in ZPR.

## [H] Universal Camera
URL: https://help.maxon.net/zbr/en-us/Content/html/user-guide/3d-modeling/modeling-basics/perspective/universal-camera/universal-camera.html(.md)
- Default since 2019. Real focal length (mm) and FOV (°). Draw palette toggle (off = legacy camera). Only works in Edit mode (not 2.5D).
- Auto Crop (AC): too close to the model it switches to a 2D zoom (crop) to avoid distortion/navigation problems. "AC" indicator near QuickSave. The boundary depends on lens and model volume.
- Settings: Camera Mode, Horizontal/Vertical, Focal Length presets 18/24/28/35/50/85, FOV, Crop Factor, Lock Camera (Draw palette + right shelf; "Prevents accidental model rotation when a stroke starts off the mesh").
- Camera undo/redo is a SEPARATE stack, limited to 14 steps (no default hotkeys).
- Store Camera (named, many), Select Camera popup, Left/Right arrows step through, Rename, Delete (not undoable). FBX/KeyShot export.
- UX NOTE: Lock Camera exists because off-mesh strokes rotate the view (a touch-relevant mis-gesture). A separate camera undo stack is worth copying.

## [H] 3Dconnexion Devices
URL: https://help.maxon.net/zbr/en-us/Content/html/user-guide/3d-modeling/modeling-basics/navigation/3dconnexion-devices/3dconnexion-devices.html(.md)
- 3D mouse knob for simultaneous rotate/zoom/pivot while sculpting with the other hand. System requirements may differ from ZBrush's. No settings documented.

## [H] LightBox
URL: https://help.maxon.net/zbr/en-us/Content/html/getting-started/basic-concepts/lightbox/lightbox.html(.md)
- Asset browser strip. Top tabs Maxon (shipped) / User; categories Projects, Tools, Brushes, Materials, Alphas, Textures, LightCaps, QuickSave, Recent. Comma (,) toggles it. Double-click loads (textures/alphas go to Spotlight; RGB to Texture, gray to Alpha). Drag to scrub sideways; 1-4 rows; back/forward arrows; New/Close preview areas.
- Prefs: Open At Launch, MultiProcessing, Placement (top/bottom), rows, glow/text, Recent files, Auto Create Shortcuts.
- CAVEAT: assets opened from LightBox aren't permanently loaded (gone after restart).

## [H] Stager
URL: https://help.maxon.net/zbr/en-us/Content/html/user-guide/3d-modeling/modeling-basics/stager/stager.html(.md)
- Tool > Geometry: Home (centered, symmetric working stage), Target (posed placement), Switch, Interpolate + Stages Count (in-between copies; closed circle = even spacing, open circle = by size), Copy/Paste. SubTool: All To Home / All To Target.
- Purpose: sculpt symmetrically at Home, view in place at Target.
- CAVEATS: to reset a stage, toggle its button off and on; topology must match.

## [H] Mask Region
URL: https://help.maxon.net/zbr/en-us/Content/html/user-guide/3d-modeling/modeling-basics/masking/mask-region/mask-region.html(.md)
- Tool > Masking > Mask Region: draw outlines with MaskPen, then Auto Region fills them (nested outlines work). Manual: Analyze Region, mark areas with mask dots, Fill Region.
- UX NOTE: "outline then fill" is similar to the paint-bucket model and touch-friendly.

## [H] Gizmo 3D: Topology Masking
URL: https://help.maxon.net/zbr/en-us/Content/html/user-guide/3d-modeling/modeling-basics/gizmo-3d/topology-masking/topology-masking.html(.md)
- Ctrl+drag the Gizmo: the mask follows topology in the drag direction, masking points beyond the origin; edges auto-blur; gizmo orientation updates live. Best on clean (ZRemesher) topology, for bending limbs at joints.
- Ctrl+click a PolyGroup (in Gizmo/TransPose mode) masks all others.

## [H] Gizmo 3D: Operators
URL: https://help.maxon.net/zbr/en-us/Content/html/user-guide/3d-modeling/modeling-basics/gizmo-3d/operators/operators.html(.md)
- Icon column: Customize (deformers/primitives menu); Sticky Mode (gizmo stays put; Repeat Last repeats a duplicate at the same offset for even spacing); Unmasked Center Mesh; Mesh to Axis; Reset Mesh Orientation (with Lock on these also move the SubTool; Alt+click = gizmo only); Lock/Unlock (hold Alt for temporary unlock / pivot setting); Multiple SubTools (operate on all selected SubTools).
- PAIN POINT: Lock is on by default, so the "reset" buttons move the model unexpectedly.

## [H] Project Undo History
URL: https://help.maxon.net/zbr/en-us/Content/html/user-guide/3d-modeling/sculpting/project-undohistory/project-undohistory.html(.md)
- Restore sculpt and/or polypaint detail from any timeline point onto the current state (works with DynaMesh). Move the timeline slider to the source and Ctrl+click it (grey hash = source), set the destination (orange cursor), then SubTool >> Project >> Project History. Switches: Geometry, Color, Farthest. A mask protects areas (undo, mask, invert, undo again, then project).
- CAVEATS: distance-based, so it can fail if vertices are too far; undo-then-project overwrites the undone step.
- UX NOTE: history as a projection source (non-linear recovery even after topology change).

## [H] Projection Master
URL: https://help.maxon.net/zbr/en-us/Content/html/user-guide/3d-modeling/sculpting/projection-master/projection-master.html(.md)
- G or button: Drop the model to canvas pixols, paint/sculpt with 2.5D tools, Pick up to transfer depth/color/material. Needs a texture map. Options: Colors, Material, Fade, Deformation, Normalize, Shade (bake lighting).
- CAVEATS: scale model so polygon size is about pixel size; doesn't add polygons; effects are hidden until pick up; materials aren't exported unless baked. Legacy 2.5D workflow.

## [H] LightCap
URL: https://help.maxon.net/zbr/en-us/Content/html/user-guide/materials-lights-rendering/lights/lightcap/lightcap.html(.md)
- Real-time MatCap/material authoring by editing simulated lights (position by dragging a red dot on a preview sphere; Color, Aperture (180 = ambient), Falloff, Strength; Specular mode; Opacity diffuse/specular). Lights can be generated from a background image; Create Environment. Light > LightCap; Material > Modifier.
- CAVEATS: edits modify the active material until restart (save as new); MatCap lighting is baked; ambient/diffuse/specular must be 100%; Render Properties Details 1/2/3 = 512/1024/2048 maps (memory).

## [H] Insert Mesh
URL: https://help.maxon.net/zbr/en-us/Content/html/user-guide/3d-modeling/sculpting/sculpting-brushes/insert-mesh/insert-mesh.html(.md)
- Inserts a mesh into the surface (negative capable, DynaMesh-compatible). Z Intensity 100 = original height. Projection Strength (Brush >> Modifiers) conforms the mesh to the surface.
- During drag-insert: Alt = stretch perpendicular; Ctrl = keep 1:1 proportions; Shift = snap orientation to the nearest world plane (remembered); Space = slide across the surface.
- CAVEATS: Projection Strength causes surprises. To keep embedded polypaint/material: Colorize on, Rgb/M/Mrgb off.

## [H] Smooth Brush
URL: https://help.maxon.net/zbr/en-us/Content/html/user-guide/3d-modeling/sculpting/sculpting-brushes/smooth/smooth.html(.md)
- Neighbor averaging; reach depends on SDiv level (smooth at low SDiv to remove big forms but keep fine detail).
- Variants: Smooth Peaks/Valleys (cavity), Smooth Valance/Subdivision/Groups...
- SHIFT: the chosen Smooth brush becomes the Shift brush (persistent until another is picked); hold Shift and change sliders to adjust the smooth brush's own settings. Press Shift to see which is bound.
- Alternate algorithm for poles: start with Shift then release Shift mid-stroke. Strength via Slider Volume Smooth.
- Weighted Smooth Mode 0-7: Standard, Stronger, Valance, Subdiv, Stroke Direction, Perpendicular, Groups Border, Creased Edges. Weight Strength.
- UX NOTE: a modifier-bound secondary brush with its own remembered settings (a "quasi-mode").

## [H] User Content (2026.1+)
URL: https://help.maxon.net/zbr/en-us/Content/html/user-guide/customizing-zbrush/user-content/user-content.html(.md)
- Per-user root (AppData/Roaming/Maxon/ZBrush_[hash] or Library/Application Support/...); Preferences > Asset Directory > Open/Change Location; env var ZBRUSH_USER_ASSETS_DIR. ZStartup/ holds BrushPresets, Hotkeys, UserInterfaceColors, UserInterfaceLayouts, CustomUserInterface cfg, ZModelerPresets, Alphas, Textures, Materials, Gizmo3D, Macros, CamViews, ZPlugs64. Also LightBox/, Quicksaves/, PluginData/.
- CAVEATS: ZBrush can't write to the install root since 2026.1, so legacy items need manual migration; not all save paths were updated.

## [H] Adjust Last
URL: https://help.maxon.net/zbr/en-us/Content/html/user-guide/3d-modeling/sculpting/sculpting-brushes/strokes/adjust-last/adjust-last.html(.md)
- Stroke palette AdjustLast slider: after a sculpt/paint/mask stroke, scale its intensity (negative = inward like ZSub; polypaint fades). For a series: Ctrl+click an undo marker on the top undo slider to set the start point.
- UX NOTE: post-hoc stroke strength editing ("adjust last operation" pattern, like Blender's redo panel).

## [H] Dynamic Symmetry
URL: https://help.maxon.net/zbr/en-us/Content/html/user-guide/3d-modeling/sculpting/symmetry/dynamic-symmetry/dynamic-symmetry.html(.md)
- Transform > Local Symmetry, then click "Dynamic" on top of the button. The symmetry plane follows the Gizmo position/orientation while moving/rotating/scaling. Shift+click a gizmo axis arrow rotates the view to look down that axis.
- Compatible with Radial, XYZ, Mirror and Weld, Delete Half by Symmetry, Curve brushes. Poseable Symmetry can recenter the gizmo (symmetric topology). ZModeler "Set Symmetry" defines the plane from 2 points/edges/polys.

## [H] CamView
URL: https://help.maxon.net/zbr/en-us/Content/html/user-guide/3d-modeling/modeling-basics/camview/camview.html(.md)
- A small orientation figure (40 pre-rendered images over 360°) that rotates with the model. Clickable cones: red X left/right, green Y top/bottom, blue Z front/back (second click = opposite view). Preferences: CamView On, Next (presets), Size, Make CamView (custom figure from a ZTool; needs front facing +Z).
- UX NOTE: a view-cube equivalent, cheaply drawn from sprites.

## [H] Remesh SubTools (Remesh All)
URL: https://help.maxon.net/zbr/en-us/Content/html/user-guide/3d-modeling/modeling-basics/creating-meshes/remeshing/remesh-subtools/remesh-subtools.html(.md)
- Tool > SubTool > Remesh All: remesh visible SubTools into a new appended SubTool with per-SubTool Add (default) / Subtract / Intersection icons; combinable with symmetry.
- CAVEATS: hidden SubTools are excluded; evaluated top to bottom (order matters).

## [H] ZRemesher: Using Curves
URL: https://help.maxon.net/zbr/en-us/Content/html/user-guide/3d-modeling/topology/zremesher/using-curves/using-curves.html(.md)
- ZRemesherGuide brush (curve brush) draws guides. Tool > ZRemesher > Curve Strength (low = suggestions, high = "the guides become rules"). Curves can only be extended (from endpoints), not reshaped. Alt + draw across deletes a curve. Large redirections need many curves.

## [H] ZRemesher: Adaptive Size
URL: https://help.maxon.net/zbr/en-us/Content/html/user-guide/3d-modeling/topology/zremesher/adaptive-size/adaptive-size.html(.md)
- Adaptive Size default 50; 0 = uniform square quads (respects count, may fail on small extrusions); high = curvature-following rectangles with variable density (less count control). Adaptive Density mode forces the count close to Target Polygon Count. Good across 3K-40K.

## [iPad] Gizmo3D vs Transpose Line
URL: https://help.maxon.net/zbp/en-us/Content/html/5_sculpting-modeling-painting_gizmo3d-essentials-gizmo-and-transpose-line.html
- Mutually exclusive (Transpose Line toggle). They share origin/orientation: the Gizmo x-axis aligns with the last drawn Transpose Line path. With Transpose Line active, the bottom-bar Gizmo icon becomes an MSR (Move/Scale/Rotate) icon. Same behavior as desktop.

## [iPad] ZModeler: Performing Actions
URL: https://help.maxon.net/zbp/en-us/Content/html/5_sculpting-and-painting_brushes_zmodeler-brush-performing-actions.html
- Choose Action + Target + Modifiers, then tap/drag on the model; drag direction changes the effect; modifier keys (Wheel) during the action. Replay: a single tap repeats the last action on another element.
- Hover (Pencil hover-capable iPad or mouse) previews: polygon = orange edges; edge = orange; vertex = blue point. Non-hover devices are supported but hover is recommended.
- UX NOTE: without hover, a touch app loses ZModeler's preview of which element is targeted. Needs an alternative (e.g. touch-down preview before commit).

## [iPad] Home Interface
URL: https://help.maxon.net/zbp/en-us/Content/html/3_interface-and-gestures_home-interface.html
- Home: Account; New Sculpt (3D Meshes starter files, Primitives, ZSpheres armatures); My Sculpts (All, ZTools, ZProjects, Quicksaves); ZBrushCentral; Pro Projects (downloadable scenes); Resources. Tap to load.
- CAVEAT: uninstalling a Pro Project deletes the brushes/textures it installed.

## [iPad] User Settings > UI
URL: https://help.maxon.net/zbp/en-us/Content/html/8_ui-customization_customize-user-settings-ui.html
- Left Hand Mode; Modifier Wheel icons/size; Thumbnail and CamView visibility (top-left/top-right corners); Show Tooltips on Hover (Pencil); Show Keyboard Shortcuts (Always / with keyboard / Never); Shortcut Format (Windows Labels / Apple Icons / Apple Labels).

## [iPad] Canvas
URL: https://help.maxon.net/zbp/en-us/Content/html/3_interface-and-gestures_canvas-interface-canvas.html
- Background color/gradient (User Settings > Canvas). Thumbnail (silhouette preview; drag to resize). CamView (tap cones to snap axis). Align the model to the CamView head with Gizmo3D or symmetry may misbehave.
- UX NOTE: a silhouette thumbnail is a classic sculpting aid (judging form).

## [iPad] Custom Toolbar
URL: https://help.maxon.net/zbp/en-us/Content/html/8_ui-customization_customize-toolbar.html
- Customize menu or swipe the bottom toolbar to Custom Toolbar 1-5 (licensed only; persisted). The default toolbar is not editable. Pick a Palette dropdown (Brushes/Alphas/Textures/Materials), long-press drag items in; second-finger taps multi-select; drag to trash to remove.

## [Community] ZBrushCentral (skim)
URL: https://www.zbrushcentral.com
- Official Discourse community forum (art sharing). Main category ZBrush Artworks; tags sculpture/character/creature/etc. Current activity: ZBrush 2027 beta tester posts; staff-pick tags. No documentation content.

## [H] Meet ZBrush (features overview)
URL: https://help.maxon.net/zbr/en-us/Content/html/features/features.html(.md)
- Sculpting up to a billion polygons, millions without expensive GPUs; 2D/2.5D/3D in one app; in-app rendering; export for print.
- Claims menus follow a "circular design that is non-linear and mode-free" (this contrasts with the documented modal pitfalls, e.g. Edit mode and drop-to-canvas).

## [H] Polygrouping Additions (2021.7+)
URL: https://help.maxon.net/zbr/en-us/Content/html/user-guide/3d-modeling/modeling-basics/polygroups/polygrouping-additions/polygrouping-additions.html(.md)
- Tool >> Polygroups: ReGroupVisible (new IDs for visible existing groups); Groups Changed Points (last stroke becomes a polygroup; with a Ctrl+clicked undo marker, all strokes since the marker; closed circle = new group each time, open circle = add to previous).
- UX NOTE: "select by what I just changed" uses undo history as a selection source.

## [H] Masking Additions (2021.7+)
URL: https://help.maxon.net/zbr/en-us/Content/html/user-guide/3d-modeling/modeling-basics/masking/masking-additions/masking-additions.html(.md)
- Tool >> Masking: Boost Mask (raise intensity without growing); Dilute Mask; Mask Changed Points (last stroke(s) since an undo marker; closed circle = gradient by change amount, open = full); Flip / Mirror By Posable Symmetry (needs symmetric topology).

## [H] Curve Mode (Stroke)
URL: https://help.maxon.net/zbr/en-us/Content/html/user-guide/3d-modeling/sculpting/sculpting-brushes/strokes/curve-mode/curve-mode.html(.md)
- Draw a curve, then the brush sweeps along it; the curve can be deformable/movable; moving it updates the stroke. Works with any 3D brush. Sample brushes in the Brush palette / LightBox > Brush > Curves.
- CAVEAT: only the current curve is editable; a new curve or other operation freezes the previous one. Differs from LazyMouse Spline/Path.

## [H] HistoryRecall Brush
URL: https://help.maxon.net/zbr/en-us/Content/html/user-guide/3d-modeling/sculpting/sculpting-brushes/historyrecall/historyrecall.html(.md)
- Ctrl+click the latest orange hash mark of the source model's Undo History, select another model (any topology), then brush to project the stored surface detail. Both models must overlap closely in space.

## [H] ZModeler: Polygon Actions
URL: https://help.maxon.net/zbr/en-us/Content/html/user-guide/3d-modeling/modeling-basics/creating-meshes/zmodeler/zmodeler-actions/polygon-actions/polygon-actions.html(.md)
- Hover a polygon, then right-click/Space. An Edge Indicator shows direction. Actions: Add to Curve; Bevel; Bridge (two polys / connected; horizontal drag = curvature, vertical = tessellation; Shift-drag optimizes); Crease (Alt AFTER clicking = uncrease, Alt BEFORE = temporary polygroup); Delete; Do Nothing; Equalize; Extrude (Ctrl = move, Shift = disconnect, Alt = change polygroup); Flip Faces; Inflate; Insert NanoMesh; Insert Point; Insert Polyloops (Loops/Grid/SunBurst; masked polys block); Inset (Alt = polygroup, Shift = square); Mask; Mesh to Brush; Move; Polygroup (many fill options); QMesh (extrude and fuse; negative deletes); Scale; Selection (temporary multi-select; double-click to clear); Spherize; Spin; Spin Edges; Split; TransPose; Unweld.
- PAIN POINT: modifier timing (before vs after click) changes meaning.

## [H] Topology (overview)
URL: https://help.maxon.net/zbr/en-us/Content/html/user-guide/3d-modeling/topology/topology.html(.md)
- Tools: ZRemesher (auto), Topology Brush (manual), Mesh Fusion, ZSphere Topology. Beginners can ignore topology. Good topology is task-relative (sculpting vs animation).
- BEGINNER vs ADVANCED: the doc explicitly says beginners can let ZBrush handle topology.

## [H] Clip Brushes
URL: https://help.maxon.net/zbr/en-us/Content/html/user-guide/3d-modeling/hard-surface/clip-brushes/clip-brushes.html(.md)
- Cut perpendicular to the screen by pushing polygons (no topology change). Clip, UnClip, Slice, Trim Curve, Crease; differ only by stroke. Ctrl+Space shows stroke options (Brush Radius, By Polygroup).
- Ctrl+Shift with a normal brush = last Clip brush (quasi-mode). ClipCurve: Alt tap = curve, double-tap = sharp. Circle/Rect + Alt = cut inside. Space during stroke = move. Alt reverses push side (the shadow side shows direction).
- CAVEATS: acts through the full depth (far side too); respects masks.

## [H] Surface Noise
URL: https://help.maxon.net/zbr/en-us/Content/html/user-guide/3d-modeling/sculpting/surface-noise/surface-noise.html(.md)
- Tool > Surface > Noise: parametric, non-destructive bump-like preview (Noise Scale, Strength, Noise Curve, ColorBlend); masks blend multiple noises; Apply to Mesh bakes to geometry (SNormal). Needs Transform > Quick 3D Edit on.
- CAVEATS: the preview differs from the real displacement (surprise heights); it may not show on very large models; quality depends on resolution.

## [H] ZSpheres (intro)
URL: https://help.maxon.net/zbr/en-us/Content/html/user-guide/3d-modeling/modeling-basics/creating-meshes/zspheres/zspheres.html(.md)
- Sketch an organic model as a sphere chain, then skin it into a mesh (Classic Skinning, Adaptive Skin). "Mastery comes mainly through experience" (an advanced concept). Keys: see Shortcuts entry (A preview, drag = child, Alt+click = delete).

## [H] Exporting Your Model
URL: https://help.maxon.net/zbr/en-us/Content/html/user-guide/3d-modeling/exporting-your-model/exporting-your-model.html(.md)
- Tool palette Export; GoZ; 3D Printing Exporter. Texture/normal/displacement/vector displacement maps need UVs; otherwise only geometry transfers.

## [iPad] Stroke Modifiers
URL: https://help.maxon.net/zbp/en-us/Content/html/5_sculpting-and-painting_brush-2-stroke-modifiers.html
- Left toolbar Strokes menu or Palettes > Stroke. Interpolate (morph between the last two strokes; Stroke Count). Lazy Mouse: Lazy Step (spacing), Lazy Radius (length of the lag line that delays application; longer = more accurate paths). Curve (first stroke becomes a draggable curve). Same as desktop.

## [iPad] ZProjects & ZTools
URL: https://help.maxon.net/zbp/en-us/Content/html/7_saving-loading_zproj-ztools.html
- ZTL: Tools, subtools, folders, subtool settings, Geometry settings, polypaint, materials. ZPR: everything in ZTL plus camera, floor grid, canvas background, assigned textures/alphas (and undo history per the Undo page).

## [iPad] Free vs Subscription
URL: https://help.maxon.net/zbp/en-us/Content/html/2_installation-and-activation_Free-vs-subscription.html
- Free: 28 brushes (sculptural, paint, selection, mask, Chisel3D, IMM); no brush save/load; DynaMesh max res 1024; full SculptrisPro; Dynamic Subdiv only Smooth/Flat; ZRemesher only Target + Retry; no ZTL/ZPR import onto canvas; no 3D export; 2D export PNG/JPG/PSD/TIFF; no Quick Menu or Custom Toolbar (palette trays OK); Transpose Line + Gizmo3D but no TransposeMaster; only floor grid presets. Subscription: 210+ more brushes, everything plus GoZ to desktop, 125+ more features.

## [iPad] Technical Requirements
URL: https://help.maxon.net/zbp/en-us/Content/html/1_technical-requirements.html
- iPadOS 17+, A12 Bionic+ (A14 + LiDAR for photogrammetry). iPad 10th gen+, Air 4+, Pro 12.9 4th+, Pro 11 2nd+. FINGER SCULPTING SUPPORTED. Recommended: Apple Pencil 1/2/Pro, M-series. A USB Pencil has no pressure.

## [iPad] Apple Pencil Haptics
URL: https://help.maxon.net/zbp/en-us/Content/html/3_interface-and-gestures_apple-pencil-haptics.html
- Haptic on Pencil double-tap (enable in Settings > Input) and on long press of buttons that have a secondary menu (supported devices).
- UX NOTE: haptics confirm long-press secondary actions.

## [iPad] Customize Hotkeys
URL: https://help.maxon.net/zbp/en-us/Content/html/8_ui-customization_customize-hot-keys.html
- Needs a physical keyboard. Tap/long-press an element, then "Add User Hotkey" and press keys; or Customize > Hotkeys tab (Pickers/Palettes/Toolbars dropdown), press keys, checkmark. A conflict prompt lets you override. Swipe left to delete (restores the default). Export/Import/Restore Defaults (Restore is permanent). Changes auto-save. No desktop sync (export/import files). Picker chords stay B + letter + user key.
- UX NOTE: iPad improves on desktop (conflict detection, swipe delete, auto-save, per-item delete).

## [H] ZModeler: Edge Selector Widget
URL: https://help.maxon.net/zbr/en-us/Content/html/user-guide/3d-modeling/modeling-basics/creating-meshes/zmodeler/edge-selector-widget/edge-selector-widget.html(.md)
- Hover feedback for directional actions. Point = orange line whose direction rotates as the cursor circles the point. Polygon = orange line from center to the edge nearest the cursor. Edge = no widget (the edge defines direction). Direction is purely cursor position (hover-dependent, a touch challenge).

## [H] Live Boolean (overview)
URL: https://help.maxon.net/zbr/en-us/Content/html/user-guide/3d-modeling/modeling-basics/creating-meshes/live-boolean/live-boolean.html(.md)
- Per-SubTool operator Addition/Subtraction/Intersection. Live Boolean toggle (Render >> Render Booleans; left of the Edit button) previews while you transform/duplicate/sculpt. Make Boolean Mesh (Tool >> SubTool >> Boolean) gives a new Tool. Works with DynaMesh, subdivision levels, ZModeler low-poly, ArrayMesh, NanoMesh.
- CAVEAT: primitives, ZSpheres/ZSketch and render-time effects (MicroMesh) must be converted to PolyMesh first.

## [H] Proxy Pose
URL: https://help.maxon.net/zbr/en-us/Content/html/user-guide/3d-modeling/posing-your-model/proxy-pose/proxy-pose.html(.md)
- Edit a high-res mesh through a temporary reduced proxy (Sculptris Pro tessellation); form changes carry up while detail is kept; vertex order is preserved. Settings: Keep Details (set BEFORE entering), Reduction Amount, Freeze Border, Polish, Keep Current / Overwrite Pose, Proxy Groups (auto polygroups).
- CAVEATS: settings changes require re-entering the mode; the doc duplicates descriptions (unclear).

## [H] Fade Opacity
URL: https://help.maxon.net/zbr/en-us/Content/html/user-guide/3d-modeling/modeling-basics/fade-opacity/fade-opacity.html(.md)
- Render > Fade Opacity slider (0-100%) plus Fade Color fades polypaint/texture to judge form. The Fade Color is independent of the primary/secondary colors.

## [H] See-through Mode
URL: https://help.maxon.net/zbr/en-us/Content/html/user-guide/3d-modeling/reference-images/see-through-mode/see-through-mode.html(.md)
- Top-right See-through slider makes the whole ZBrush window transparent, to sculpt over a reference in another window. It turns opaque when the cursor leaves the canvas.

## [H] Thumbnail
URL: https://help.maxon.net/zbr/en-us/Content/html/user-guide/3d-modeling/modeling-basics/thumbnail/thumbnail.html(.md)
- Top-left live preview (Silhouette mode default, or color/material). Preferences > Thumbnail: on/off, Silhouette, Size, Magnify, Export, Import background, Background color. Shift+drag = magnify; click = import background; Alt+drag = pan; Alt+drag then release Alt = scale; Ctrl+click = canvas snapshot as background.
- UX NOTE: a silhouette-check widget is a valued sculpting aid. Hidden multi-step modifier chords again.

## [H] Reference Guide (index)
URL: https://help.maxon.net/zbr/en-us/Content/html/reference-guide/reference-guide.html(.md)
- 24 palettes: Alpha, Brush, Color, Document, Draw, Edit, File, Layer (canvas layers), Light, Macro, Marker, Material, Movie, Picker, Preferences, Render, Stencil, Stroke, Texture, Tool (primary 3D workspace), Transform, Zplugin, Zscript, Help. Palette > default items + collapsible sub-palettes.
- UX NOTE: a flat, feature-grouped menu taxonomy. "Tool" is overloaded (the 3D model itself and its huge settings palette).

## [H] Gizmo 3D: Multiple SubTools
URL: https://help.maxon.net/zbr/en-us/Content/html/user-guide/3d-modeling/modeling-basics/gizmo-3d/multiple-subtools/multiple-subtools.html(.md)
- "Transform All Selected SubTools" toggle on the gizmo: move/scale/rotate several SubTools together (no sculpting or deformers on multi-selection; ZRemesher, Inflate and Divide act on the current one only).
- Selection: visible SubTools, or temporary: Ctrl+Shift+click a SubTool to add/remove (unselected show hash lines); Ctrl+Shift+click empty canvas = invert; Ctrl+Shift+drag empty = clear.
- PAIN POINT: the visibility-based method disrupts visibility organization; multi-object editing is transform-only.

## [H] Primitives
URL: https://help.maxon.net/zbr/en-us/Content/html/user-guide/3d-modeling/modeling-basics/creating-meshes/primitives/primitives.html(.md)
- Parametric primitives are generators and can't be sculpted. Tool > Make PolyMesh3D converts them. Tool > Initialize holds parameters (only while parametric).
- PAIN POINT: the parametric vs polymesh state is invisible to beginners; many features require PolyMesh3D.

## [H] Mesh Extract
URL: https://help.maxon.net/zbr/en-us/Content/html/user-guide/3d-modeling/modeling-basics/creating-meshes/mesh-extract/mesh-extract.html(.md)
- Mask (or hide) a region, then Tool > SubTool > Extract (preview), then Accept to get a new SubTool shell with cleaned edges (jackets, helmets). The mask stays on the source (clear it).

---

# CRAWL LOG

Method: WebFetch + WebSearch only (curl has no web access). Crawl date 2026-10-25.

KEY DISCOVERY: help.maxon.net/zbr/en-us/Content/html/**/X.html pages return only the JS navigation tree (about 82KB of nav links; the body is injected client-side), so offset reading also failed. Appending `.md` (X.html.md) returns the article body. All desktop help pages listed below as read were read via the .md variant. ZBrush for iPad help (help.maxon.net/zbp/...) renders server-side and was readable directly.

## Fetched successfully, content recorded (entries above)
Maxon marketing (15):
- https://www.maxon.net/en/zbrush
- https://www.maxon.net/en/product-detail/zbrush/features?categories=1200575|1200576|1200577|1200578 (category headings only; list is JS-rendered)
- https://www.maxon.net/en/zbrush/features/base-mesh-creation
- https://www.maxon.net/en/zbrush/features/brush-system
- https://www.maxon.net/en/zbrush/features/sculptural-freedom
- https://www.maxon.net/en/zbrush/features/polygon-modeling
- https://www.maxon.net/en/zbrush/features/remeshing-options
- https://www.maxon.net/en/zbrush/features/flexible-workflows
- https://www.maxon.net/en/zbrush/features/uv-editor
- https://www.maxon.net/en/zbrush/features/polypaint
- https://www.maxon.net/en/zbrush/features/uv-master
- https://www.maxon.net/en/zbrush/features/spotlight
- https://www.maxon.net/en/zbrush/features/advanced-painting-texturing
- https://www.maxon.net/en/zbrush/features/substance-bridge
- https://www.maxon.net/en/zbrush/features/python-scripting-support
- https://www.maxon.net/en/zbrush-for-ipad
Desktop help (help.maxon.net/zbr/en-us/Content/html/... ; all via .html.md unless noted):
- zbrush-online-help.html (.html, TOC only)
- Resources/Uploads/ZBrush2021_CheatSheet.pdf
- features/features
- reference-guide/reference-guide
- getting-started/finding-your-way-around; basic-concepts/ztools-and-edit-mode; basic-concepts/saving-your-work; basic-concepts/lightbox
- user-guide/3d-modeling/modeling-basics/: navigation; navigation/3dconnexion-devices; perspective/universal-camera; camview; thumbnail; subtools; subtools/subtool-folders; stager; subdivision-levels; subdivision-levels/hd-geometry; dynamic-subdivision; dynamic-subdivision/hotkeys; masking; masking/mask-region; masking/masking-additions; polygroups; polygroups/polygrouping-additions; mesh-visibility; transpose; gizmo-3d; gizmo-3d/basic-operations; gizmo-3d/topology-masking; gizmo-3d/operators; gizmo-3d/multiple-subtools; gizmo-3d/deformers/list-of-deformers; fade-opacity
- .../creating-meshes/: primitives; mesh-extract; dynamesh; dynamesh/options; sculptris-pro/using-sculptris-pro; zmodeler/introduction; zmodeler/actions-and-targets; zmodeler/edge-selector-widget; zmodeler/zmodeler-actions/polygon-actions; live-boolean; live-boolean/important-information; live-boolean/performance; live-boolean/basic-process; remeshing/remesh-subtools; zspheres
- user-guide/3d-modeling/sculpting/: sculpting-brushes; sculpting-brushes/smooth; sculpting-brushes/insert-mesh; sculpting-brushes/alphas; sculpting-brushes/lazy-mouse-2-0; sculpting-brushes/historyrecall; sculpting-brushes/strokes; strokes/adjust-last; strokes/curve-mode; symmetry; symmetry/dynamic-symmetry; 3d-layers; morph-targets; project-undohistory; projection-master; surface-noise
- user-guide/3d-modeling/: painting-your-model/polypaint; painting-your-model/spotlight; nanomesh; array-mesh; topology; topology/zremesher/introduction; topology/zremesher/using-curves; topology/zremesher/adaptive-size; hard-surface/clip-brushes; posing-your-model/proxy-pose; reference-images/see-through-mode; exporting-your-model; undo-history
- user-guide/: selection-sets; uv-editor; keyboard-shortcuts/shortcuts-by-category; customizing-zbrush/hotkeys; customizing-zbrush/navigation; customizing-zbrush/interface-operation; customizing-zbrush/interface-layout/custom-interface; customizing-zbrush/macros; customizing-zbrush/user-content; customizing-zbrush/zscripting
- user-guide/materials-lights-rendering/: materials; materials/matcap/matcap-basics; lights/lightcap; rendering/bpr
- user-guide/zbrush-plugins/: decimation-master; uv-master; transpose-master
- user-guide/zbrush-other-programs/goz/about-goz
ZBrush for iPad help (help.maxon.net/zbp/en-us/Content/html/...):
- 3_interface-and-gestures_: navigation-settings; touch-gestures; touch-gestures-settings; canvas-interface; canvas-interface-canvas; canvas-interface-top-bar; canvas-interface-left-toolbar; canvas-interface-right-toolbar; canvas-interface-bottom-toolbar; canvas-interface-modifier-wheel; canvas-interface-palette-docking; quick-search; keyboard; long-press-directory; apple-pencil-controls; apple-pencil-pressure-attributes; apple-pencil-hover-display; apple-pencil-haptics; home-interface
- 5_sculpting-*: sculpting-modeling-painting (index); brushes; brush-customization; brush-1-stroke; brush-2-stroke-modifiers; masking-essentials; selection-brush-essentials; polygroups-essentials; dynamesh-sculpting-essentials; sculpting-sculptis-pro-essentials; subdivision-sculpting-essentials; zremesher-essentials; polypaint-essentials; live-boolean-essentials; symmetry-essentials; gizmo3d-essentials-basics-guide; gizmo3d-essentials-gizmo-and-transpose-line; brushes_zmodeler-brush-performing-actions
- 4_palettes_tool-2-subtool (stub); 4_palettes_tool-4-layers
- 7_saving-loading_undo-history; 7_saving-loading_zproj-ztools
- 8_ui-customization; 8_ui-customization_customize-quick-menu; customize-toolbar; customize-hot-keys; customize-user-settings-ui
- 1_technical-requirements; 2_installation-and-activation_Free-vs-subscription; 10_faq
Community:
- https://www.zbrushcentral.com (skim)
WebSearch queries used: "site:help.maxon.net zbr navigation rotate ALT drag canvas" (found the cheat sheet PDF and the zbp iPad help), "docs.pixologic.com user guide 3d modeling navigation" (no useful hits).

Total page entries: 162 (17 marketing, about 90 desktop help incl. cheat sheet, about 55 iPad help, 1 community).

## Failed / body-less / blocked
- https://help.maxon.net/zbr/en-us/ (JS app shell; title only)
- .html (non-.md) versions of: getting-started/finding-your-way-around, basic-concepts/ztools-and-edit-mode, basic-concepts/2d-and-3d-navigation, modeling-basics/navigation (offsets 40000/70000/76000 also tried), perspective/universal-camera, customizing-zbrush/navigation. All nav-only; resolved by re-fetching the .md variant (except 2d-and-3d-navigation, which was not retried).
- Features category page: feature cards JS-rendered (no descriptions).
- Some iPad pages are stubs (canvas-interface index, 4_palettes_tool-2-subtool, brush-customization index) and some put content only in images (gesture defaults, action lists).
- docs.pixologic.com legacy docs were not found via search.

## Not reached (time/budget; URLs known from TOC in /tmp/claude-0/-home-claude-Implicit-sculpt-modeler/55997ecf-4ea5-525a-a26c-7d0e59ae3906/scratchpad/crawl/helpurls.txt)
- Desktop: ZModeler edge/point/curve action pages, targets, presets; DynaMesh methods/with-subtools/polygroups; Sculptris Pro global settings; ZSpheres sub-pages; ZSketch; Mannequins; Snapshot3D sub-pages; Live Boolean advanced/main-functions/warnings/preferences; ZRemesher hard-surfaces/partial/symmetry; FiberMesh; MicroMesh; cloth simulation; Thick Skin; rigging; Drop 3D; 3D printing; BPR settings/passes/filters; NPR; Redshift; KeyShot; posterization; morph UV; Bas-relief; Slime Bridge; VDM pages; keyboard-shortcuts/shortcuts-by-palette and defaulthotkeys-file; ZScript sub-pages (getting-started, command reference); SubTool Master; GoZ workflow/restrictions/troubleshooting; per-palette Reference Guide pages (e.g. Preferences > Performance/Interface); Python API docs (not located in this help set; only the marketing page states Python support).
- iPad: ZModeler sub-pages, retopology brush, Spotlight, posing, transpose line, ZSphere essentials, rendering pages, import/export pages, palette tray customization, reset settings, iOS accessibility, Pencil Scribble, Masking sub-option pages, What's New.
