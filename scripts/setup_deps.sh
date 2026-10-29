#!/usr/bin/env bash
# Fetches and builds pinned dependencies into deps/ (Linux).
# System packages needed (Ubuntu 24.04):
#   clang cmake ninja-build git python3 curl xz-utils
#   libvulkan-dev mesa-vulkan-drivers libx11-dev libxext-dev libxrandr-dev libxcursor-dev
#   libxi-dev libxss-dev libxtst-dev libwayland-dev libxkbcommon-dev libdecor-0-dev
#   libegl-dev libdrm-dev libgbm-dev
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/scripts/versions.env"
DEPS="$ROOT/deps"
mkdir -p "$DEPS"

# Odin compiler
if [ ! -x "$DEPS/odin/odin" ]; then
	echo "== Odin $ODIN_TAG"
	tmp="$(mktemp -d)"
	curl -fsSL -o "$tmp/odin.tar.gz" \
		"https://github.com/odin-lang/Odin/releases/download/$ODIN_TAG/odin-linux-amd64-$ODIN_TAG.tar.gz"
	tar -xzf "$tmp/odin.tar.gz" -C "$tmp"
	rm -rf "$DEPS/odin"
	mv "$tmp"/odin-linux-amd64-* "$DEPS/odin"
	rm -rf "$tmp"
fi
"$DEPS/odin/odin" version

# stb's C libraries: vendor:fontstash (the UI's text) links stb_truetype and
# stb_rect_pack, which the Linux release of Odin does not ship compiled.
if [ ! -f "$DEPS/odin/vendor/stb/lib/stb_truetype.a" ]; then
	echo "== stb (vendor/stb/src/build_stb.sh)"
	sh "$DEPS/odin/vendor/stb/src/build_stb.sh" unix
fi

# SDL3, built from source (Ubuntu 24.04 does not package SDL3)
if [ ! -f "$DEPS/sdl3/lib/libSDL3.so" ]; then
	echo "== SDL $SDL_TAG"
	rm -rf "$DEPS/sdl3-src"
	git clone -q --depth 1 -b "$SDL_TAG" https://github.com/libsdl-org/SDL.git "$DEPS/sdl3-src"
	cmake -S "$DEPS/sdl3-src" -B "$DEPS/sdl3-src/build" -G Ninja \
		-DCMAKE_BUILD_TYPE=Release -DSDL_TESTS=OFF -DSDL_EXAMPLES=OFF \
		-DCMAKE_INSTALL_PREFIX="$DEPS/sdl3" > "$DEPS/sdl3-configure.log"
	ninja -C "$DEPS/sdl3-src/build" install > "$DEPS/sdl3-build.log"
fi

# Slang's compiler (slangc) and its libraries from the LunarG Vulkan SDK, checked against
# the pinned hash. Only shader authors need it: build.sh compiles src/render/shaders/*.slang
# when deps/slang/bin/slangc exists, and otherwise the committed .spv files are used.
if [ ! -x "$DEPS/slang/bin/slangc" ]; then
	echo "== Slang (Vulkan SDK $VULKAN_SDK)"
	tmp="$(mktemp -d)"
	curl -fsSL -o "$tmp/sdk.tar.xz" \
		"https://sdk.lunarg.com/sdk/download/$VULKAN_SDK/linux/vulkan-sdk-linux-x86_64-$VULKAN_SDK.tar.xz"
	echo "$VULKAN_SDK_SHA256  $tmp/sdk.tar.xz" | sha256sum -c --quiet
	tar -xJf "$tmp/sdk.tar.xz" -C "$tmp" --wildcards "$VULKAN_SDK/x86_64/bin/slangc" "$VULKAN_SDK/x86_64/lib/libslang*"
	rm -rf "$DEPS/slang"
	mkdir -p "$DEPS/slang"
	mv "$tmp/$VULKAN_SDK/x86_64/bin" "$tmp/$VULKAN_SDK/x86_64/lib" "$DEPS/slang/"
	rm -rf "$tmp"
fi
"$DEPS/slang/bin/slangc" -version

# Luau, the language of script plugins, built from source (scripts/build_luau.py)
python3 "$ROOT/scripts/build_luau.py"

# ufbx, the FBX reader Import uses, with the app's shim round it (scripts/build_ufbx.py)
python3 "$ROOT/scripts/build_ufbx.py"

# SDL_shadercross, which turns each .spv build.sh makes into the Metal source the iPad build
# embeds (scripts/build_shadercross.py, scripts/shaders_msl.py). Shader authors need it as they
# need slangc: `check` fails when a .spv changed without its .msl.
python3 "$ROOT/scripts/build_shadercross.py"

echo "Dependencies ready in $DEPS"
