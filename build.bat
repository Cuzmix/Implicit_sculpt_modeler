@echo off
rem Usage: build.bat [debug|release|test|run|smoke]   (see build.sh for what each does)
rem Run scripts\setup_deps.bat first, from an x64 Native Tools Command Prompt.
setlocal
set ROOT=%~dp0
set DEPS=%ROOT%deps
set ODIN=%DEPS%\odin\odin.exe
if not exist "%ODIN%" ( echo deps missing: run scripts\setup_deps.bat first & exit /b 1 )
set MODE=%1
if "%MODE%"=="" set MODE=debug
set COMMON=-collection:deps="%DEPS%" -vet -strict-style -warnings-as-errors

rem Recompile shaders when glslangValidator (Vulkan SDK) is available; otherwise use the committed .spv files.
where glslangValidator >nul 2>nul && (
	for %%s in ("%ROOT%src\render\shaders\*.vert" "%ROOT%src\render\shaders\*.frag") do glslangValidator -V --quiet "%%s" -o "%%s.spv" || exit /b 1
)

if not exist "%ROOT%build" mkdir "%ROOT%build"
copy /y "%DEPS%\odin\vendor\sdl3\SDL3.dll" "%ROOT%build\" >nul

if "%MODE%"=="release" (
	"%ODIN%" build "%ROOT%src\app" -out:"%ROOT%build\sculpt.exe" -o:speed %COMMON% || exit /b 1
	exit /b 0
)
if "%MODE%"=="test" (
	"%ODIN%" test "%ROOT%src\geom" -out:"%ROOT%build\test_geom.exe" %COMMON% || exit /b 1
	"%ODIN%" test "%ROOT%src\camera" -out:"%ROOT%build\test_camera.exe" %COMMON% || exit /b 1
	exit /b 0
)
"%ODIN%" build "%ROOT%src\app" -out:"%ROOT%build\sculpt.exe" -debug %COMMON% || exit /b 1
if "%MODE%"=="run" "%ROOT%build\sculpt.exe" %2 %3 %4 %5 %6
if "%MODE%"=="smoke" (
	set SDL_ASSERT=abort
	"%ROOT%build\sculpt.exe" --frames=300 --gpu-debug || exit /b 1
)
