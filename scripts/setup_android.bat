@echo off
rem Fetches what the Android build needs on top of setup_deps.bat: SDL's source, which the
rem Android app builds libSDL3.so and takes SDL's Java activity from (Windows otherwise uses
rem the SDL3.dll that ships with Odin). The Android SDK, NDK, CMake and Java come with
rem Android Studio (README.md, Android).
setlocal
set ROOT=%~dp0..
for /f "usebackq tokens=1,2 delims==" %%a in ("%ROOT%\scripts\versions.env") do (
	if not "%%a"=="" if not "%%b"=="" set %%a=%%b
)
set DEPS=%ROOT%\deps
if not exist "%DEPS%\odin\odin.exe" ( echo deps missing: run scripts\setup_deps.bat first & exit /b 1 )

if not exist "%DEPS%\sdl3-src\CMakeLists.txt" (
	echo == SDL %SDL_TAG% source
	git clone -q --depth 1 -b %SDL_TAG% https://github.com/libsdl-org/SDL.git "%DEPS%\sdl3-src" || exit /b 1
)

rem Odin checks that vendor:stb's Linux archives exist whenever it compiles for Linux, and
rem Android is Linux to it, though the Android build compiles stb_truetype from source
rem (android\app\jni\CMakeLists.txt) and never reads them. Odin for Windows ships only the
rem .lib files, so empty stand-ins satisfy the check.
for %%l in (stb_truetype stb_rect_pack) do if not exist "%DEPS%\odin\vendor\stb\lib\%%l.a" type nul > "%DEPS%\odin\vendor\stb\lib\%%l.a"
echo Android dependencies ready in %DEPS%
