#!/usr/bin/env bash
# Usage: scripts/sdl_ios.sh IOS_MIN SDL_SOURCE OUT
# Builds SDL3 as a static library for the iPad (arm64, iPadOS IOS_MIN and later) from the
# source in SDL_SOURCE, installed into OUT/sdl, as `./build.sh ios` links it. It lives apart
# from build.sh so that the iPad workflow (.github/workflows/ipad.yml) can key its cache of
# OUT/sdl on this recipe, SDL's tag and IOS_MIN alone: a change anywhere else in build.sh
# keeps the cached SDL, and a change here builds it anew.
set -euo pipefail
ios_min=$1
src=$2
out=$3
# CMake's default generator, as SDL's own iOS builds use; an Xcode-generated build's install
# is not a path SDL tests.
cmake -S "$src" -B "$out/sdl-build" -DCMAKE_BUILD_TYPE=Release \
	-DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_ARCHITECTURES=arm64 \
	-DCMAKE_OSX_DEPLOYMENT_TARGET="$ios_min" -DCMAKE_INSTALL_PREFIX="$out/sdl" \
	-DSDL_SHARED=OFF -DSDL_STATIC=ON -DSDL_TEST_LIBRARY=OFF -DSDL_TESTS=OFF -DSDL_EXAMPLES=OFF
cmake --build "$out/sdl-build" --parallel
cmake --install "$out/sdl-build"
