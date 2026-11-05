# 00 · Source index

Every claim in files 01-13 cites an ID from this table. Full per-page extraction notes (features, tools, hotkeys, UI, data structures, pain points, best practices) are in `raw/zbrush.md`, `raw/nomad.md` and `raw/3dcoat.md`. Crawled 2026-10-25 with a summarising fetcher, so notes are dense paraphrase, not quotes.

| Product | Pages read | Notes |
|---|---|---|
| ZBrush (desktop help, iPad help, maxon.net) | 162 | Desktop help read via the `.html.md` variant (the HTML is a JS shell). Not reached: ZModeler sub-pages, FiberMesh, cloth, BPR passes, Redshift, per-palette reference pages, ZScript sub-pages, Python API docs (only the marketing page mentions Python). |
| Nomad Sculpt (manual + forum) | 21 manual pages + 17 forum pages | Manual is flat (no child pages). It lags the app: v2.9 (Dec 2025) features are only in the forum change log. |
| 3DCoat (manual, library, FAQ, blog, licensing) | 102 | UV tools page returned a server error; system requirements are images only. No touch or multitouch documentation exists anywhere in the 3DCoat docs. |


## ZBrush

| ID | Page | URL |
|---|---|---|
| Z001 | [M] ZBrush product page | https://www.maxon.net/en/zbrush |
| Z002 | [M] Features overview (category filter) | https://www.maxon.net/en/product-detail/zbrush/features?categories=1200575|1200576|1200577|1200578 |
| Z003 | [M] Base Mesh Creation | https://www.maxon.net/en/zbrush/features/base-mesh-creation |
| Z004 | [M] Brush System | https://www.maxon.net/en/zbrush/features/brush-system |
| Z005 | [M] Sculptural Freedom | https://www.maxon.net/en/zbrush/features/sculptural-freedom |
| Z006 | [M] Polygon Modeling | https://www.maxon.net/en/zbrush/features/polygon-modeling |
| Z007 | [M] Remeshing Options | https://www.maxon.net/en/zbrush/features/remeshing-options |
| Z008 | [M] Flexible Workflows | https://www.maxon.net/en/zbrush/features/flexible-workflows |
| Z009 | [M] UV Editor | https://www.maxon.net/en/zbrush/features/uv-editor |
| Z010 | [M] PolyPaint | https://www.maxon.net/en/zbrush/features/polypaint |
| Z011 | [M] UV Master | https://www.maxon.net/en/zbrush/features/uv-master |
| Z012 | [M] SpotLight | https://www.maxon.net/en/zbrush/features/spotlight |
| Z013 | [M] Advanced Painting & Texturing | https://www.maxon.net/en/zbrush/features/advanced-painting-texturing |
| Z014 | [M] Substance Bridge | https://www.maxon.net/en/zbrush/features/substance-bridge |
| Z015 | [M] Python Scripting Support | https://www.maxon.net/en/zbrush/features/python-scripting-support |
| Z016 | [H] ZBrush Online Help: welcome / table of contents | https://help.maxon.net/zbr/en-us/Content/html/zbrush-online-help.html |
| Z017 | [M] ZBrush for iPad (product page) | https://www.maxon.net/en/zbrush-for-ipad |
| Z018 | [H] Navigation (3D Modeling > Modeling Basics) | https://help.maxon.net/zbr/en-us/Content/html/user-guide/3d-modeling/modeling-basics/navigation/navigation.html(.md) |
| Z019 | [H] ZBrush 2021 Cheat Sheet (PDF, official) | https://help.maxon.net/zbr/en-us/Content/Resources/Uploads/ZBrush2021_CheatSheet.pdf |
| Z020 | [iPad] Navigation Settings (ZBrush for iPad) | https://help.maxon.net/zbp/en-us/Content/html/3_interface-and-gestures_navigation-settings.html |
| Z021 | [iPad] Touch Gestures | https://help.maxon.net/zbp/en-us/Content/html/3_interface-and-gestures_touch-gestures.html |
| Z022 | [iPad] Touch Gesture Settings | https://help.maxon.net/zbp/en-us/Content/html/3_interface-and-gestures_touch-gestures-settings.html |
| Z023 | [iPad] Modifier Wheel | https://help.maxon.net/zbp/en-us/Content/html/3_interface-and-gestures_canvas-interface-modifier-wheel.html |
| Z024 | [iPad] Canvas Interface (index) | https://help.maxon.net/zbp/en-us/Content/html/3_interface-and-gestures_canvas-interface.html |
| Z025 | [iPad] Left Toolbar | https://help.maxon.net/zbp/en-us/Content/html/3_interface-and-gestures_canvas-interface-left-toolbar.html |
| Z026 | [iPad] Right Toolbar | https://help.maxon.net/zbp/en-us/Content/html/3_interface-and-gestures_canvas-interface-right-toolbar.html |
| Z027 | [iPad] Top Bar | https://help.maxon.net/zbp/en-us/Content/html/3_interface-and-gestures_canvas-interface-top-bar.html |
| Z028 | [iPad] Bottom Toolbar | https://help.maxon.net/zbp/en-us/Content/html/3_interface-and-gestures_canvas-interface-bottom-toolbar.html |
| Z029 | [iPad] Apple Pencil Controls | https://help.maxon.net/zbp/en-us/Content/html/3_interface-and-gestures_apple-pencil-controls.html |
| Z030 | [iPad] Pressure Attributes | https://help.maxon.net/zbp/en-us/Content/html/3_interface-and-gestures_apple-pencil-pressure-attributes.html |
| Z031 | [iPad] Hover Display | https://help.maxon.net/zbp/en-us/Content/html/3_interface-and-gestures_apple-pencil-hover-display.html |
| Z032 | [iPad] Long Press Directory | https://help.maxon.net/zbp/en-us/Content/html/3_interface-and-gestures_long-press-directory.html |
| Z033 | [iPad] Quick Search | https://help.maxon.net/zbp/en-us/Content/html/3_interface-and-gestures_quick-search.html |
| Z034 | [iPad] Palette Docking | https://help.maxon.net/zbp/en-us/Content/html/3_interface-and-gestures_canvas-interface-palette-docking.html |
| Z035 | [iPad] UI Customization (overview) | https://help.maxon.net/zbp/en-us/Content/html/8_ui-customization.html |
| Z036 | [iPad] Keyboard & Mouse | https://help.maxon.net/zbp/en-us/Content/html/3_interface-and-gestures_keyboard.html |
| Z037 | [iPad] Sculpting, Modeling, Painting (chapter index) | https://help.maxon.net/zbp/en-us/Content/html/5_sculpting-modeling-painting.html |
| Z038 | [iPad] FAQ | https://help.maxon.net/zbp/en-us/Content/html/10_faq.html |
| Z039 | [iPad] Customize Quick Menu | https://help.maxon.net/zbp/en-us/Content/html/8_ui-customization_customize-quick-menu.html |
| Z040 | [iPad] Masking Essentials | https://help.maxon.net/zbp/en-us/Content/html/5_sculpting-and-painting_masking-essentials.html |
| Z041 | [iPad] Selection Brush Essentials (visibility) | https://help.maxon.net/zbp/en-us/Content/html/5_sculpting-and-painting_selection-brush-essentials.html |
| Z042 | [iPad] Gizmo3D Basics | https://help.maxon.net/zbp/en-us/Content/html/5_sculpting-modeling-painting_gizmo3d-essentials-basics-guide.html |
| Z043 | [iPad] DynaMesh Sculpting Essentials | https://help.maxon.net/zbp/en-us/Content/html/5_sculpting-and-painting_dynamesh-sculpting-essentials.html |
| Z044 | [iPad] Brush Customization (index) | https://help.maxon.net/zbp/en-us/Content/html/5_sculpting-and-painting_brush-customization.html |
| Z045 | [iPad] Brush Stroke | https://help.maxon.net/zbp/en-us/Content/html/5_sculpting-and-painting_brush-1-stroke.html |
| Z046 | [iPad] Brushes (categories) | https://help.maxon.net/zbp/en-us/Content/html/5_sculpting-and-painting_brushes.html |
| Z047 | [iPad] Subdivision Sculpting Essentials | https://help.maxon.net/zbp/en-us/Content/html/5_sculpting-and-painting_subdivision-sculpting-essentials.html |
| Z048 | [iPad] Sculptris Pro Essentials | https://help.maxon.net/zbp/en-us/Content/html/5_sculpting-and-painting_sculpting-sculptis-pro-essentials.html |
| Z049 | [iPad] Polygroups Essentials | https://help.maxon.net/zbp/en-us/Content/html/5_sculpting-and-painting_polygroups-essentials.html |
| Z050 | [iPad] Symmetry Essentials | https://help.maxon.net/zbp/en-us/Content/html/5_sculpting-and-painting_symmetry-essentials.html |
| Z051 | [iPad] Live Boolean Essentials | https://help.maxon.net/zbp/en-us/Content/html/5_sculpting-and-painting_live-boolean-essentials.html |
| Z052 | [iPad] ZRemesher Essentials | https://help.maxon.net/zbp/en-us/Content/html/5_sculpting-and-painting_zremesher-essentials.html |
| Z053 | [iPad] Polypaint Essentials | https://help.maxon.net/zbp/en-us/Content/html/5_sculpting-and-painting_polypaint-essentials.html |
| Z054 | [iPad] Tool > Subtool palette (stub) | https://help.maxon.net/zbp/en-us/Content/html/4_palettes_tool-2-subtool.html |
| Z055 | [iPad] Tool > Layers (3D Layers) | https://help.maxon.net/zbp/en-us/Content/html/4_palettes_tool-4-layers.html |
| Z056 | [iPad] Undo History | https://help.maxon.net/zbp/en-us/Content/html/7_saving-loading_undo-history.html |
| Z057 | [H] SubTools | https://help.maxon.net/zbr/en-us/Content/html/user-guide/3d-modeling/modeling-basics/subtools/subtools.html(.md) |
| Z058 | [H] SubTool Folders | https://help.maxon.net/zbr/en-us/Content/html/user-guide/3d-modeling/modeling-basics/subtools/subtool-folders/subtool-folders.html(.md) |
| Z059 | [H] Subdivision Levels | https://help.maxon.net/zbr/en-us/Content/html/user-guide/3d-modeling/modeling-basics/subdivision-levels/subdivision-levels.html(.md) |
| Z060 | [H] HD Geometry | https://help.maxon.net/zbr/en-us/Content/html/user-guide/3d-modeling/modeling-basics/subdivision-levels/hd-geometry/hd-geometry.html(.md) |
| Z061 | [H] Masking | https://help.maxon.net/zbr/en-us/Content/html/user-guide/3d-modeling/modeling-basics/masking/masking.html(.md) |
| Z062 | [H] Polygroups | https://help.maxon.net/zbr/en-us/Content/html/user-guide/3d-modeling/modeling-basics/polygroups/polygroups.html(.md) |
| Z063 | [H] Mesh Visibility | https://help.maxon.net/zbr/en-us/Content/html/user-guide/3d-modeling/modeling-basics/mesh-visibility/mesh-visibility.html(.md) |
| Z064 | [H] Transpose (Modeling Basics) | https://help.maxon.net/zbr/en-us/Content/html/user-guide/3d-modeling/modeling-basics/transpose/transpose.html(.md) |
| Z065 | [H] Gizmo 3D (overview) | https://help.maxon.net/zbr/en-us/Content/html/user-guide/3d-modeling/modeling-basics/gizmo-3d/gizmo-3d.html(.md) |
| Z066 | [H] Gizmo 3D: Basic Operations | https://help.maxon.net/zbr/en-us/Content/html/user-guide/3d-modeling/modeling-basics/gizmo-3d/basic-operations/basic-operations.html(.md) |
| Z067 | [H] Gizmo 3D: List of Deformers | https://help.maxon.net/zbr/en-us/Content/html/user-guide/3d-modeling/modeling-basics/gizmo-3d/deformers/list-of-deformers/list-of-deformers.html(.md) |
| Z068 | [H] Dynamic Subdivision | https://help.maxon.net/zbr/en-us/Content/html/user-guide/3d-modeling/modeling-basics/dynamic-subdivision/dynamic-subdivision.html(.md) |
| Z069 | [H] Dynamic Subdivision: Hotkeys | https://help.maxon.net/zbr/en-us/Content/html/user-guide/3d-modeling/modeling-basics/dynamic-subdivision/hotkeys/hotkeys.html(.md) |
| Z070 | [H] Keyboard Shortcuts by Category (authoritative full list) | https://help.maxon.net/zbr/en-us/Content/html/user-guide/keyboard-shortcuts/shortcuts-by-category/shortcuts-by-category.html(.md) |
| Z071 | [H] Customizing ZBrush: Hotkeys | https://help.maxon.net/zbr/en-us/Content/html/user-guide/customizing-zbrush/hotkeys/hotkeys.html(.md) |
| Z072 | [H] Interface Operation | https://help.maxon.net/zbr/en-us/Content/html/user-guide/customizing-zbrush/interface-operation/interface-operation.html(.md) |
| Z073 | [H] Custom Interface | https://help.maxon.net/zbr/en-us/Content/html/user-guide/customizing-zbrush/interface-layout/custom-interface/custom-interface.html(.md) |
| Z074 | [H] Customizing ZBrush: Navigation | https://help.maxon.net/zbr/en-us/Content/html/user-guide/customizing-zbrush/navigation/navigation.html(.md) |
| Z075 | [H] DynaMesh | https://help.maxon.net/zbr/en-us/Content/html/user-guide/3d-modeling/modeling-basics/creating-meshes/dynamesh/dynamesh.html(.md) |
| Z076 | [H] DynaMesh Options | https://help.maxon.net/zbr/en-us/Content/html/user-guide/3d-modeling/modeling-basics/creating-meshes/dynamesh/options/options.html(.md) |
| Z077 | [H] Using Sculptris Pro | https://help.maxon.net/zbr/en-us/Content/html/user-guide/3d-modeling/modeling-basics/creating-meshes/sculptris-pro/using-sculptris-pro/using-sculptris-pro.html(.md) |
| Z078 | [H] ZRemesher: Introduction | https://help.maxon.net/zbr/en-us/Content/html/user-guide/3d-modeling/topology/zremesher/introduction/introduction.html(.md) |
| Z079 | [H] Live Boolean: Important Information | https://help.maxon.net/zbr/en-us/Content/html/user-guide/3d-modeling/modeling-basics/creating-meshes/live-boolean/important-information/important-information.html(.md) |
| Z080 | [H] Live Boolean: Performance | https://help.maxon.net/zbr/en-us/Content/html/user-guide/3d-modeling/modeling-basics/creating-meshes/live-boolean/performance/performance.html(.md) |
| Z081 | [H] Live Boolean: Basic Process | https://help.maxon.net/zbr/en-us/Content/html/user-guide/3d-modeling/modeling-basics/creating-meshes/live-boolean/basic-process/basic-process.html(.md) |
| Z082 | [H] ZModeler: Introduction (Essentials) | https://help.maxon.net/zbr/en-us/Content/html/user-guide/3d-modeling/modeling-basics/creating-meshes/zmodeler/introduction/introduction.html(.md) |
| Z083 | [H] ZModeler: Actions and Targets | https://help.maxon.net/zbr/en-us/Content/html/user-guide/3d-modeling/modeling-basics/creating-meshes/zmodeler/actions-and-targets/actions-and-targets.html(.md) |
| Z084 | [H] Sculpting Brushes | https://help.maxon.net/zbr/en-us/Content/html/user-guide/3d-modeling/sculpting/sculpting-brushes/sculpting-brushes.html(.md) |
| Z085 | [H] Lazy Mouse 2.0 | https://help.maxon.net/zbr/en-us/Content/html/user-guide/3d-modeling/sculpting/sculpting-brushes/lazy-mouse-2-0/lazy-mouse-2-0.html(.md) |
| Z086 | [H] Alphas | https://help.maxon.net/zbr/en-us/Content/html/user-guide/3d-modeling/sculpting/sculpting-brushes/alphas/alphas.html(.md) |
| Z087 | [H] Strokes (sculpting strokes tutorial) | https://help.maxon.net/zbr/en-us/Content/html/user-guide/3d-modeling/sculpting/sculpting-brushes/strokes/strokes.html(.md) |
| Z088 | [H] Symmetry | https://help.maxon.net/zbr/en-us/Content/html/user-guide/3d-modeling/sculpting/symmetry/symmetry.html(.md) |
| Z089 | [H] 3D Layers | https://help.maxon.net/zbr/en-us/Content/html/user-guide/3d-modeling/sculpting/3d-layers/3d-layers.html(.md) |
| Z090 | [H] Morph Targets | https://help.maxon.net/zbr/en-us/Content/html/user-guide/3d-modeling/sculpting/morph-targets/morph-targets.html(.md) |
| Z091 | [H] Polypaint | https://help.maxon.net/zbr/en-us/Content/html/user-guide/3d-modeling/painting-your-model/polypaint/polypaint.html(.md) |
| Z092 | [H] SpotLight (painting) | https://help.maxon.net/zbr/en-us/Content/html/user-guide/3d-modeling/painting-your-model/spotlight/spotlight.html(.md) |
| Z093 | [H] MatCap Basics | https://help.maxon.net/zbr/en-us/Content/html/user-guide/materials-lights-rendering/materials/matcap/matcap-basics/matcap-basics.html(.md) |
| Z094 | [H] Materials | https://help.maxon.net/zbr/en-us/Content/html/user-guide/materials-lights-rendering/materials/materials.html(.md) |
| Z095 | [H] BPR (Best Preview Render) | https://help.maxon.net/zbr/en-us/Content/html/user-guide/materials-lights-rendering/rendering/bpr/bpr.html(.md) |
| Z096 | [H] Undo History (desktop) | https://help.maxon.net/zbr/en-us/Content/html/user-guide/3d-modeling/undo-history/undo-history.html(.md) |
| Z097 | [H] Selection Sets (2027) | https://help.maxon.net/zbr/en-us/Content/html/user-guide/selection-sets/selection-sets.html(.md) |
| Z098 | [H] UV Editor (2027, desktop only) | https://help.maxon.net/zbr/en-us/Content/html/user-guide/uv-editor/uv-editor.html(.md) |
| Z099 | [H] NanoMesh | https://help.maxon.net/zbr/en-us/Content/html/user-guide/3d-modeling/nanomesh/nanomesh.html(.md) |
| Z100 | [H] ArrayMesh | https://help.maxon.net/zbr/en-us/Content/html/user-guide/3d-modeling/array-mesh/array-mesh.html(.md) |
| Z101 | [H] Decimation Master | https://help.maxon.net/zbr/en-us/Content/html/user-guide/zbrush-plugins/decimation-master/decimation-master.html(.md) |
| Z102 | [H] UV Master | https://help.maxon.net/zbr/en-us/Content/html/user-guide/zbrush-plugins/uv-master/uv-master.html(.md) |
| Z103 | [H] GoZ: About | https://help.maxon.net/zbr/en-us/Content/html/user-guide/zbrush-other-programs/goz/about-goz/about-goz.html(.md) |
| Z104 | [H] Transpose Master | https://help.maxon.net/zbr/en-us/Content/html/user-guide/zbrush-plugins/transpose-master/transpose-master.html(.md) |
| Z105 | [H] ZScripting (overview) | https://help.maxon.net/zbr/en-us/Content/html/user-guide/customizing-zbrush/zscripting/zscripting.html(.md) |
| Z106 | [H] Macros | https://help.maxon.net/zbr/en-us/Content/html/user-guide/customizing-zbrush/macros/macros.html(.md) |
| Z107 | [H] ZTools and Edit Mode | https://help.maxon.net/zbr/en-us/Content/html/getting-started/basic-concepts/ztools-and-edit-mode/ztools-and-edit-mode.html(.md) |
| Z108 | [H] Finding Your Way Around (interface) | https://help.maxon.net/zbr/en-us/Content/html/getting-started/finding-your-way-around/finding-your-way-around.html(.md) |
| Z109 | [H] Saving Your Work | https://help.maxon.net/zbr/en-us/Content/html/getting-started/basic-concepts/saving-your-work/saving-your-work.html(.md) |
| Z110 | [H] Universal Camera | https://help.maxon.net/zbr/en-us/Content/html/user-guide/3d-modeling/modeling-basics/perspective/universal-camera/universal-camera.html(.md) |
| Z111 | [H] 3Dconnexion Devices | https://help.maxon.net/zbr/en-us/Content/html/user-guide/3d-modeling/modeling-basics/navigation/3dconnexion-devices/3dconnexion-devices.html(.md) |
| Z112 | [H] LightBox | https://help.maxon.net/zbr/en-us/Content/html/getting-started/basic-concepts/lightbox/lightbox.html(.md) |
| Z113 | [H] Stager | https://help.maxon.net/zbr/en-us/Content/html/user-guide/3d-modeling/modeling-basics/stager/stager.html(.md) |
| Z114 | [H] Mask Region | https://help.maxon.net/zbr/en-us/Content/html/user-guide/3d-modeling/modeling-basics/masking/mask-region/mask-region.html(.md) |
| Z115 | [H] Gizmo 3D: Topology Masking | https://help.maxon.net/zbr/en-us/Content/html/user-guide/3d-modeling/modeling-basics/gizmo-3d/topology-masking/topology-masking.html(.md) |
| Z116 | [H] Gizmo 3D: Operators | https://help.maxon.net/zbr/en-us/Content/html/user-guide/3d-modeling/modeling-basics/gizmo-3d/operators/operators.html(.md) |
| Z117 | [H] Project Undo History | https://help.maxon.net/zbr/en-us/Content/html/user-guide/3d-modeling/sculpting/project-undohistory/project-undohistory.html(.md) |
| Z118 | [H] Projection Master | https://help.maxon.net/zbr/en-us/Content/html/user-guide/3d-modeling/sculpting/projection-master/projection-master.html(.md) |
| Z119 | [H] LightCap | https://help.maxon.net/zbr/en-us/Content/html/user-guide/materials-lights-rendering/lights/lightcap/lightcap.html(.md) |
| Z120 | [H] Insert Mesh | https://help.maxon.net/zbr/en-us/Content/html/user-guide/3d-modeling/sculpting/sculpting-brushes/insert-mesh/insert-mesh.html(.md) |
| Z121 | [H] Smooth Brush | https://help.maxon.net/zbr/en-us/Content/html/user-guide/3d-modeling/sculpting/sculpting-brushes/smooth/smooth.html(.md) |
| Z122 | [H] User Content (2026.1+) | https://help.maxon.net/zbr/en-us/Content/html/user-guide/customizing-zbrush/user-content/user-content.html(.md) |
| Z123 | [H] Adjust Last | https://help.maxon.net/zbr/en-us/Content/html/user-guide/3d-modeling/sculpting/sculpting-brushes/strokes/adjust-last/adjust-last.html(.md) |
| Z124 | [H] Dynamic Symmetry | https://help.maxon.net/zbr/en-us/Content/html/user-guide/3d-modeling/sculpting/symmetry/dynamic-symmetry/dynamic-symmetry.html(.md) |
| Z125 | [H] CamView | https://help.maxon.net/zbr/en-us/Content/html/user-guide/3d-modeling/modeling-basics/camview/camview.html(.md) |
| Z126 | [H] Remesh SubTools (Remesh All) | https://help.maxon.net/zbr/en-us/Content/html/user-guide/3d-modeling/modeling-basics/creating-meshes/remeshing/remesh-subtools/remesh-subtools.html(.md) |
| Z127 | [H] ZRemesher: Using Curves | https://help.maxon.net/zbr/en-us/Content/html/user-guide/3d-modeling/topology/zremesher/using-curves/using-curves.html(.md) |
| Z128 | [H] ZRemesher: Adaptive Size | https://help.maxon.net/zbr/en-us/Content/html/user-guide/3d-modeling/topology/zremesher/adaptive-size/adaptive-size.html(.md) |
| Z129 | [iPad] Gizmo3D vs Transpose Line | https://help.maxon.net/zbp/en-us/Content/html/5_sculpting-modeling-painting_gizmo3d-essentials-gizmo-and-transpose-line.html |
| Z130 | [iPad] ZModeler: Performing Actions | https://help.maxon.net/zbp/en-us/Content/html/5_sculpting-and-painting_brushes_zmodeler-brush-performing-actions.html |
| Z131 | [iPad] Home Interface | https://help.maxon.net/zbp/en-us/Content/html/3_interface-and-gestures_home-interface.html |
| Z132 | [iPad] User Settings > UI | https://help.maxon.net/zbp/en-us/Content/html/8_ui-customization_customize-user-settings-ui.html |
| Z133 | [iPad] Canvas | https://help.maxon.net/zbp/en-us/Content/html/3_interface-and-gestures_canvas-interface-canvas.html |
| Z134 | [iPad] Custom Toolbar | https://help.maxon.net/zbp/en-us/Content/html/8_ui-customization_customize-toolbar.html |
| Z135 | [Community] ZBrushCentral (skim) | https://www.zbrushcentral.com |
| Z136 | [H] Meet ZBrush (features overview) | https://help.maxon.net/zbr/en-us/Content/html/features/features.html(.md) |
| Z137 | [H] Polygrouping Additions (2021.7+) | https://help.maxon.net/zbr/en-us/Content/html/user-guide/3d-modeling/modeling-basics/polygroups/polygrouping-additions/polygrouping-additions.html(.md) |
| Z138 | [H] Masking Additions (2021.7+) | https://help.maxon.net/zbr/en-us/Content/html/user-guide/3d-modeling/modeling-basics/masking/masking-additions/masking-additions.html(.md) |
| Z139 | [H] Curve Mode (Stroke) | https://help.maxon.net/zbr/en-us/Content/html/user-guide/3d-modeling/sculpting/sculpting-brushes/strokes/curve-mode/curve-mode.html(.md) |
| Z140 | [H] HistoryRecall Brush | https://help.maxon.net/zbr/en-us/Content/html/user-guide/3d-modeling/sculpting/sculpting-brushes/historyrecall/historyrecall.html(.md) |
| Z141 | [H] ZModeler: Polygon Actions | https://help.maxon.net/zbr/en-us/Content/html/user-guide/3d-modeling/modeling-basics/creating-meshes/zmodeler/zmodeler-actions/polygon-actions/polygon-actions.html(.md) |
| Z142 | [H] Topology (overview) | https://help.maxon.net/zbr/en-us/Content/html/user-guide/3d-modeling/topology/topology.html(.md) |
| Z143 | [H] Clip Brushes | https://help.maxon.net/zbr/en-us/Content/html/user-guide/3d-modeling/hard-surface/clip-brushes/clip-brushes.html(.md) |
| Z144 | [H] Surface Noise | https://help.maxon.net/zbr/en-us/Content/html/user-guide/3d-modeling/sculpting/surface-noise/surface-noise.html(.md) |
| Z145 | [H] ZSpheres (intro) | https://help.maxon.net/zbr/en-us/Content/html/user-guide/3d-modeling/modeling-basics/creating-meshes/zspheres/zspheres.html(.md) |
| Z146 | [H] Exporting Your Model | https://help.maxon.net/zbr/en-us/Content/html/user-guide/3d-modeling/exporting-your-model/exporting-your-model.html(.md) |
| Z147 | [iPad] Stroke Modifiers | https://help.maxon.net/zbp/en-us/Content/html/5_sculpting-and-painting_brush-2-stroke-modifiers.html |
| Z148 | [iPad] ZProjects & ZTools | https://help.maxon.net/zbp/en-us/Content/html/7_saving-loading_zproj-ztools.html |
| Z149 | [iPad] Free vs Subscription | https://help.maxon.net/zbp/en-us/Content/html/2_installation-and-activation_Free-vs-subscription.html |
| Z150 | [iPad] Technical Requirements | https://help.maxon.net/zbp/en-us/Content/html/1_technical-requirements.html |
| Z151 | [iPad] Apple Pencil Haptics | https://help.maxon.net/zbp/en-us/Content/html/3_interface-and-gestures_apple-pencil-haptics.html |
| Z152 | [iPad] Customize Hotkeys | https://help.maxon.net/zbp/en-us/Content/html/8_ui-customization_customize-hot-keys.html |
| Z153 | [H] ZModeler: Edge Selector Widget | https://help.maxon.net/zbr/en-us/Content/html/user-guide/3d-modeling/modeling-basics/creating-meshes/zmodeler/edge-selector-widget/edge-selector-widget.html(.md) |
| Z154 | [H] Live Boolean (overview) | https://help.maxon.net/zbr/en-us/Content/html/user-guide/3d-modeling/modeling-basics/creating-meshes/live-boolean/live-boolean.html(.md) |
| Z155 | [H] Proxy Pose | https://help.maxon.net/zbr/en-us/Content/html/user-guide/3d-modeling/posing-your-model/proxy-pose/proxy-pose.html(.md) |
| Z156 | [H] Fade Opacity | https://help.maxon.net/zbr/en-us/Content/html/user-guide/3d-modeling/modeling-basics/fade-opacity/fade-opacity.html(.md) |
| Z157 | [H] See-through Mode | https://help.maxon.net/zbr/en-us/Content/html/user-guide/3d-modeling/reference-images/see-through-mode/see-through-mode.html(.md) |
| Z158 | [H] Thumbnail | https://help.maxon.net/zbr/en-us/Content/html/user-guide/3d-modeling/modeling-basics/thumbnail/thumbnail.html(.md) |
| Z159 | [H] Reference Guide (index) | https://help.maxon.net/zbr/en-us/Content/html/reference-guide/reference-guide.html(.md) |
| Z160 | [H] Gizmo 3D: Multiple SubTools | https://help.maxon.net/zbr/en-us/Content/html/user-guide/3d-modeling/modeling-basics/gizmo-3d/multiple-subtools/multiple-subtools.html(.md) |
| Z161 | [H] Primitives | https://help.maxon.net/zbr/en-us/Content/html/user-guide/3d-modeling/modeling-basics/creating-meshes/primitives/primitives.html(.md) |
| Z162 | [H] Mesh Extract | https://help.maxon.net/zbr/en-us/Content/html/user-guide/3d-modeling/modeling-basics/creating-meshes/mesh-extract/mesh-extract.html(.md) |

## Nomad Sculpt

| ID | Page | URL |
|---|---|---|
| N001 | Overview (Manual index) | https://nomadsculpt.com/manual/ |
| N002 | Getting Started | https://nomadsculpt.com/manual/gettingstarted |
| N003 | Interface Menu | https://nomadsculpt.com/manual/interface |
| N004 | Tools | https://nomadsculpt.com/manual/tools  (page complete; ends with Toolbox context menu; pager prev=Interface Menu, next=History) |
| N005 | Files | https://nomadsculpt.com/manual/files  (complete; ends at Render "Export png") |
| N006 | Scene | https://nomadsculpt.com/manual/scene  (complete; ends with Bottom toolbar) |
| N007 | Topology | https://nomadsculpt.com/manual/topology  (main content complete; ends at thin "Primitive" section; "Vertex extrapolation" heading has no body; booleans are on Scene page, not here) |
| N008 | Material | https://nomadsculpt.com/manual/material  (complete; ends with Uniform scale) |
| N009 | Shading | https://nomadsculpt.com/manual/shading  (complete; ends with Instance ID Randomise id) |
| N010 | Post process | https://nomadsculpt.com/manual/postprocess  (complete; ends with Dithering) |
| N011 | Background | https://nomadsculpt.com/manual/background  (complete; ends with camera-linking tip + video) |
| N012 | Camera | https://nomadsculpt.com/manual/camera  (complete; ends with Double tap on background) |
| N013 | Stroke | https://nomadsculpt.com/manual/stroke  (complete; ends with Pressure smoothing) |
| N014 | Pressure | https://nomadsculpt.com/manual/pressure  (exists, short; not linked in sidebar) |
| N015 | Painting | https://nomadsculpt.com/manual/painting  (complete; ends with Global material) |
| N016 | Symmetry | https://nomadsculpt.com/manual/symmetry  (complete; ends with Show options) |
| N017 | Layers | https://nomadsculpt.com/manual/layers  (complete; ends with Advanced) |
| N018 | Settings | https://nomadsculpt.com/manual/settings  (complete; "Primitive/Repeaters" heading empty) |
| N019 | History | https://nomadsculpt.com/manual/history  (complete; Memory stats section has no detail) |
| N020 | FAQ | https://nomadsculpt.com/manual/faq  (complete) |
| N021 | Tips | https://nomadsculpt.com/manual/tips  (complete; ends with Daylight lighting) |
| N022 | forum.nomadsculpt.com (pain points, requests, complaints) | https://forum.nomadsculpt.com (categories), /top?period=all, /c/feature-request/7 (+ ?page=1, /l/top?period=all), /c/bug-report/5 (+ /l/top?period=all), /c/tips-tutorials/10, plus threads listed in crawl log. |

## 3DCoat

| ID | Page | URL |
|---|---|---|
| C001 | 3DCoat Documentation (landing hub) | https://3dcoat.com/documentation/ |
| C002 | Interface (Interface, Navigation & Applinks) | https://3dcoat.com/documentation/manual/interface-and-navigation/ |
| C003 | Getting started | https://3dcoat.com/documentation/manual/getting-started/ |
| C004 | Hotkeys | https://3dcoat.com/documentation/manual/navigation/hotkeys/ |
| C005 | Camera and Navigation | https://3dcoat.com/documentation/manual/navigation/camera-and-navigation/ |
| C006 | Customize Navigation as Blender | https://3dcoat.com/documentation/manual/navigation/camera-and-navigation/customize-navigation-as-blender/ |
| C007 | Navigation Panel | https://3dcoat.com/documentation/manual/navigation/navigation-panel/ |
| C008 | Quick Access Menu (Spacebar Menu) | https://3dcoat.com/documentation/manual/navigation/space-bar-menu/ |
| C009 | Sculpt (room overview) | https://3dcoat.com/documentation/manual/workspaces-rooms/sculpt/ |
| C010 | Sculpt Tree (VoxTree) | https://3dcoat.com/documentation/manual/workspaces-rooms/sculpt/sculpt-tree/ |
| C011 | Sculpt Layer | https://3dcoat.com/documentation/manual/workspaces-rooms/sculpt/sculpt-layer/ |
| C012 | Voxel mode | https://3dcoat.com/documentation/manual/workspaces-rooms/sculpt/voxel-mode/ |
| C013 | Surface mode | https://3dcoat.com/documentation/manual/workspaces-rooms/sculpt/surface-mode/ |
| C014 | Voxel Tools | https://3dcoat.com/documentation/manual/workspaces-rooms/sculpt/voxel-mode/voxel-tools/ |
| C015 | Surface Tools | https://3dcoat.com/documentation/manual/workspaces-rooms/sculpt/surface-mode/surface-tools/ |
| C016 | Live Booleans | https://3dcoat.com/documentation/manual/workspaces-rooms/sculpt/live-booleans/ |
| C017 | Voxel Objects Tools | https://3dcoat.com/documentation/manual/workspaces-rooms/sculpt/voxel-mode/voxel-objects-tools/ |
| C018 | Density and Resolution | https://3dcoat.com/documentation/manual/workspaces-rooms/sculpt/voxel-mode/density-and-resolution/ |
| C019 | Brush engine | https://3dcoat.com/documentation/manual/workspaces-rooms/sculpt/brush-engine/ |
| C020 | Brush Components | https://3dcoat.com/documentation/manual/brush-components/ |
| C021 | Strokes (Stroke Mode / E panel) | https://3dcoat.com/documentation/manual/brush-components/strokes/ |
| C022 | Brush Options panel | https://3dcoat.com/documentation/manual/brush-components/brush-options/ |
| C023 | Conditions (Height/Color) Limiter | https://3dcoat.com/documentation/manual/brush-components/conditions-limiter/ |
| C024 | Brushes general use (Alphas) | https://3dcoat.com/documentation/manual/brush-components/brushes-alphas/ |
| C025 | Brush Top Bar | https://3dcoat.com/documentation/manual/brush-components/brush-top-bar/ |
| C026 | Freeze menu | https://3dcoat.com/documentation/manual/interface-and-navigation/freeze-menu/ |
| C027 | Symmetry | https://3dcoat.com/documentation/manual/interface-and-navigation/symmetry-menu/ |
| C028 | Room Customization | https://3dcoat.com/documentation/manual/interface-and-navigation/customization/ |
| C029 | Modify or Create new Room | https://3dcoat.com/documentation/manual/interface-and-navigation/modify-or-create-new-room/ |
| C030 | Preferences | https://3dcoat.com/documentation/manual/interface-and-navigation/edit-menu/preferences/ |
| C031 | Tablet on Window | https://3dcoat.com/documentation/manual/getting-started/tablet-on-window/ |
| C032 | Stylus doesn't work in sculpting | https://3dcoat.com/documentation/manual/navigation/stylus-doesnt-work-in-sculpting/ |
| C033 | Activity Bar | https://3dcoat.com/documentation/manual/navigation/activity-bar/ |
| C034 | Retopology (room) | https://3dcoat.com/documentation/manual/workspaces-rooms/retopology/ |
| C035 | AUTORETOPO (Autopo) | https://3dcoat.com/documentation/manual/workspaces-rooms/retopology/autoretopo/ |
| C036 | Add Geometry (Retopo tools) | https://3dcoat.com/documentation/manual/workspaces-rooms/retopology/left-tool-panel-in-retopology/add-geometry/ |
| C037 | UV (room) | https://3dcoat.com/documentation/manual/workspaces-rooms/uv-workspace/ |
| C038 | UV workflow example | https://3dcoat.com/documentation/manual/workspaces-rooms/uv-workspace/uv-workflow-example/ |
| C039 | Paint (room) | https://3dcoat.com/documentation/manual/workspaces-rooms/paint/ |
| C040 | The Layers Panel (Paint) | https://3dcoat.com/documentation/manual/workspaces-rooms/paint/the-layers-panel/ |
| C041 | Smart Materials | https://3dcoat.com/documentation/manual/brush-components/smart-materials/ |
| C042 | Painting Modes | https://3dcoat.com/documentation/manual/workspaces-rooms/paint/texture-painting-and-modes/ |
| C043 | Multi Level Resolution | https://3dcoat.com/documentation/manual/workspaces-rooms/sculpt/surface-mode/multi-level-resolution/ |
| C044 | Transform tools | https://3dcoat.com/documentation/manual/workspaces-rooms/sculpt/transform-tools/ |
| C045 | Right-Click Menu (Sculpt Tree, voxel) | https://3dcoat.com/documentation/manual/workspaces-rooms/sculpt/voxel-right-click-menu/ |
| C046 | Geometry menu (Sculpt) | https://3dcoat.com/documentation/manual/workspaces-rooms/sculpt/geometry-submenu/ |
| C047 | Clay Engine | https://3dcoat.com/documentation/manual/workspaces-rooms/sculpt/voxel-mode/clay-engine/ |
| C048 | Commands for Sculpt room | https://3dcoat.com/documentation/manual/workspaces-rooms/sculpt/commands-for-sculpt-room/ |
| C049 | Scripting & Core API | https://3dcoat.com/documentation/manual/scripting-and-core-api/ |
| C050 | Core API | https://3dcoat.com/documentation/manual/scripting-and-core-api/core-api/ |
| C051 | Python API | https://3dcoat.com/documentation/manual/scripting-and-core-api/python-api/ |
| C052 | Introduction to 3DCoat | https://3dcoat.com/documentation/manual/introduction-to-3dcoat/ |
| C053 | Workspaces Rooms (overview) | https://3dcoat.com/documentation/manual/workspaces-rooms/ |
| C054 | Modeling (room) | https://3dcoat.com/documentation/manual/workspaces-rooms/modeling/ |
| C055 | Render (room) | https://3dcoat.com/documentation/manual/workspaces-rooms/render/ |
| C056 | Simplest (room) | https://3dcoat.com/documentation/manual/workspaces-rooms/simplest/ |
| C057 | Different Forms of "Resolution" | https://3dcoat.com/documentation/manual/getting-started/different-forms-of-resolution/ |
| C058 | System requirements | https://3dcoat.com/documentation/manual/getting-started/system-requirements/ |
| C059 | Questions & Answers (FAQ) | https://3dcoat.com/documentation/faq/ |
| C060 | Training Tutorials | https://3dcoat.com/documentation/training-tutorials/ |
| C061 | Library: Sculpt | https://3dcoat.com/documentation/library/sculpt/ |
| C062 | Licensing (Pilgway) | https://pilgway.com/licensing |
| C063 | Quick Start Menu (opening dialog) | https://3dcoat.com/documentation/manual/navigation/opening-dialog-menu/ |
| C064 | Color management | https://3dcoat.com/documentation/manual/color-management/ |
| C065 | Free 3DCoatPrint | https://3dcoat.com/documentation/manual/3dcoat-print/ |
| C066 | Node System | https://3dcoat.com/documentation/manual/nodesystem/ |
| C067 | GPU Texturing | https://3dcoat.com/documentation/manual/texturing/ |
| C068 | Library: Retopology | https://3dcoat.com/documentation/library/retopology/ |
| C069 | Top Bar (Sculpt) | https://3dcoat.com/documentation/manual/workspaces-rooms/sculpt/top-bar/ |
| C070 | Sculpt Brush options | https://3dcoat.com/documentation/manual/workspaces-rooms/sculpt/sculpt-brush-options/ |
| C071 | Pose tool | https://3dcoat.com/documentation/manual/workspaces-rooms/sculpt/transform-tools/pose/ |
| C072 | Hide menu | https://3dcoat.com/documentation/manual/interface-and-navigation/hide-menu/ |
| C073 | Windows Panels (tabbed/popup) | https://3dcoat.com/documentation/manual/interface-and-navigation/windows-menu/tabbed-windows-popup-panels/ |
| C074 | Pure Voxel Sculpting (What are Voxels) | https://3dcoat.com/documentation/manual/workspaces-rooms/sculpt/voxel-mode/pure-voxel-sculpting/ |
| C075 | Surface tools on Voxels | https://3dcoat.com/documentation/manual/workspaces-rooms/sculpt/voxel-mode/surface-tools-on-voxels/ |
| C076 | Surface Layer | https://3dcoat.com/documentation/manual/workspaces-rooms/sculpt/surface-mode/surface-layer/ |
| C077 | Left tool panel | https://3dcoat.com/documentation/manual/navigation/left-tool-panel/ |
| C078 | Navigation using 3DConnexion devices | https://3dcoat.com/documentation/manual/navigation/navigation-using-3dconnexion-devices/ |
| C079 | Voxel Adjust | https://3dcoat.com/documentation/manual/workspaces-rooms/sculpt/voxel-mode/voxel-adjustment-tools/ |
| C080 | Surface adjust tools | https://3dcoat.com/documentation/manual/workspaces-rooms/sculpt/surface-mode/surface-adjust-tools/ |
| C081 | Primitives (Sculpt) | https://3dcoat.com/documentation/manual/workspaces-rooms/sculpt/voxel-primitives-import-tools/ |
| C082 | Import to Sculpt Room | https://3dcoat.com/documentation/manual/workspaces-rooms/sculpt/import-to-sculpt-room/ |
| C083 | Extensions and Addons | https://3dcoat.com/documentation/manual/scripting-and-core-api/extensions-and-addons/ |
| C084 | Surface custom tools | https://3dcoat.com/documentation/manual/workspaces-rooms/sculpt/surface-mode/surface-custom-tools/ |
| C085 | Poly Groups (Retopo) | https://3dcoat.com/documentation/manual/workspaces-rooms/retopology/poly-groups/ |
| C086 | Presets for Brush alphas | https://3dcoat.com/documentation/manual/brush-components/presets/ |
| C087 | Kitbash (room) | https://3dcoat.com/documentation/manual/workspaces-rooms/kitbash/ |
| C088 | View menu | https://3dcoat.com/documentation/manual/interface-and-navigation/view-menu/ |
| C089 | Navigation (overview) | https://3dcoat.com/documentation/manual/navigation/ |
| C090 | Vector Displacement | https://3dcoat.com/documentation/manual/workspaces-rooms/sculpt/vector-displacement/ |
| C091 | Layers menu | https://3dcoat.com/documentation/manual/interface-and-navigation/layers-menu/ |
| C092 | Edit menu | https://3dcoat.com/documentation/manual/interface-and-navigation/edit-menu/ |
| C093 | Library: Getting Started | https://3dcoat.com/documentation/library/getting-started/ |
| C094 | Library: Painting | https://3dcoat.com/documentation/library/painting/ |
| C095 | Library: Modeling | https://3dcoat.com/documentation/library/modeling/ |
| C096 | Library: UV | https://3dcoat.com/documentation/library/uv/ |
| C097 | Library (index) | https://3dcoat.com/documentation/library/ |
| C098 | 2026 Key Features and Improvements (blog) | https://3dcoat.com/documentation/2026/07/27/2026-key-features-and-improvements/ |
| C099 | Paint Tool Panel | https://3dcoat.com/documentation/manual/workspaces-rooms/paint/paint-room-tools/ |
| C100 | Select Geometry (Retopo top bar) | https://3dcoat.com/documentation/manual/workspaces-rooms/retopology/top-bar/select-geometry/ |
| C101 | Curves menu | https://3dcoat.com/documentation/manual/interface-and-navigation/curves-menu/ |
| C102 | Retopo Tweak Tools | https://3dcoat.com/documentation/manual/workspaces-rooms/retopology/left-tool-panel-in-retopology/retopo-tweak-tools/ |
