package render

import "../gpu"

// The shader code render embeds, picked per platform when the app is compiled. Render draws
// with Metal on Apple's platforms, which takes Metal source, and with Vulkan elsewhere,
// which takes SPIR-V: build.sh and build.bat compile each shaders/name.stage.slang to
// name.stage.spv, scripts/shaders_msl.py turns that into name.stage.msl with SDL_shadercross,
// and both are committed, as is the WGSL scripts/shaders_wgsl.py makes for the web
// version's WebGPU. Each build embeds only its own kind, so none grows another's binary. Each
// shader's description, NAME_STAGE in shaders_gen.odin, holds its code
// (`#load("shaders/name.stage" + SHADER_EXT, string)`, as a string because Odin's wasm64p32
// code generation stops on #load as bytes: README "Web") and the counts its bindings take, which
// scripts/shaders_gen.py reads from slangc's reflection of the source, so a pipeline is made
// from the description alone.

@(private)
SHADER_EXT :: ".msl" when ODIN_OS == .Darwin else ".wgsl" when ODIN_OS == .JS else ".spv"

// The language of the embedded shaders, which the running backend checks it reads.
@(private)
SHADER_FORMAT :: gpu.Shader_Format.Msl when ODIN_OS == .Darwin else gpu.Shader_Format.Wgsl when ODIN_OS == .JS else gpu.Shader_Format.Spirv

// The entry point every shader's create info names: SDL_shadercross renames `main`, which
// Metal refuses as a function name, to `main0`.
@(private)
SHADER_ENTRY :: cstring("main0") when ODIN_OS == .Darwin else cstring("main")

// A ray query kernel's code (a "// ray query" first line): on Apple's platforms the Metal
// source slangc's own Metal target makes, with its slot table on the second line
// (scripts/shaders_msl.py), since SDL_shadercross's Metal cannot name a ray tracing
// structure; slangc renames `main` to `main_0`.
@(private)
RQ_EXT :: ".metal" when ODIN_OS == .Darwin else ".wgsl" when ODIN_OS == .JS else ".spv"

@(private)
RQ_ENTRY :: cstring("main_0") when ODIN_OS == .Darwin else cstring("main")
