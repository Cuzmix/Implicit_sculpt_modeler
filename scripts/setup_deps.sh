#!/usr/bin/env bash
# Fetches and builds pinned dependencies into deps/ (Linux).
# System packages needed (Ubuntu 24.04):
#   clang cmake ninja-build git python3 glslang-tools
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

echo "Dependencies ready in $DEPS"
