package render

import sdl "vendor:sdl3"

// The shader code render embeds, picked per platform when the app is compiled. SDL_GPU draws
// through Metal on Apple's platforms, which takes Metal source, and through Vulkan elsewhere,
// which takes SPIR-V: build.sh and build.bat compile each shaders/name.stage.slang to
// name.stage.spv, scripts/shaders_msl.py turns that into name.stage.msl with SDL_shadercross,
// and both are committed. Each build embeds only its own kind, so neither grows the other's
// binary; a shader's constant is `#load("shaders/name.stage" + SHADER_EXT)`.

@(private)
SHADER_EXT :: ".msl" when ODIN_OS == .Darwin else ".spv"

@(private)
SHADER_FORMAT :: sdl.GPUShaderFormat{.MSL} when ODIN_OS == .Darwin else sdl.GPUShaderFormat{.SPIRV}

// The entry point every shader's create info names: SDL_shadercross renames `main`, which
// Metal refuses as a function name, to `main0`.
@(private)
SHADER_ENTRY :: cstring("main0") when ODIN_OS == .Darwin else cstring("main")
