#!/usr/bin/env bash
# Usage: scripts/sdl_mac.sh MAC_MIN SDL_SOURCE OUT
# Builds SDL3 as a static library for the Mac (Apple silicon, macOS MAC_MIN and later) from
# the source in SDL_SOURCE, installed into OUT/sdl, as `./build.sh mac` links it. It lives
# apart from build.sh, as scripts/sdl_ios.sh does for the iPad, so that the Mac workflow
# (.github/workflows/mac.yml) can key its cache of OUT/sdl on this recipe, SDL's tag and
# MAC_MIN alone.
set -euo pipefail
mac_min=$1
src=$2
out=$3
cmake -S "$src" -B "$out/sdl-build" -DCMAKE_BUILD_TYPE=Release \
	-DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET="$mac_min" \
	-DCMAKE_INSTALL_PREFIX="$out/sdl" \
	-DSDL_SHARED=OFF -DSDL_STATIC=ON -DSDL_TEST_LIBRARY=OFF -DSDL_TESTS=OFF -DSDL_EXAMPLES=OFF
cmake --build "$out/sdl-build" --parallel
cmake --install "$out/sdl-build"
