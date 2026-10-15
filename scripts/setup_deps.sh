#!/usr/bin/env bash
# Fetches and builds pinned dependencies into deps/ (Linux).
# System packages needed (Ubuntu 24.04):
#   clang cmake ninja-build git python3 glslang-tools libc++-18-dev libc++abi-18-dev
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

# Dear ImGui bindings, built with only the SDL3 + SDL_GPU backends
if [ ! -f "$DEPS/odin-imgui/imgui_linux_x64.a" ]; then
	echo "== odin-imgui $ODIN_IMGUI_COMMIT"
	rm -rf "$DEPS/odin-imgui"
	git clone -q https://gitlab.com/L-4/odin-imgui.git "$DEPS/odin-imgui"
	git -C "$DEPS/odin-imgui" -c advice.detachedHead=false checkout -q "$ODIN_IMGUI_COMMIT"
	sed -i 's/^wanted_backends = .*/wanted_backends = ["sdl3", "sdlgpu3"]/; /^\t\t\t\t   "dx11", "dx12"/d' \
		"$DEPS/odin-imgui/build.py"
	(cd "$DEPS/odin-imgui" && python3 build.py)
fi
echo "Dependencies ready in $DEPS"
