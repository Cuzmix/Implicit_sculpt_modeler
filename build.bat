@echo off
rem Usage: build.bat [debug|release|test|run|smoke|bench|gpubench|check]   (see build.sh for what each does)
rem Run scripts\setup_deps.bat first, from an x64 Native Tools Command Prompt.
rem Modes are labels rather than if-blocks: an `exit /b 1` inside a parenthesised block
rem returns 0 to whoever ran `cmd /c build.bat`, so a failure would pass unnoticed.
setlocal
set ROOT=%~dp0
set DEPS=%ROOT%deps
set ODIN=%DEPS%\odin\odin.exe
if not exist "%ODIN%" ( echo deps missing: run scripts\setup_deps.bat first & exit /b 1 )
set MODE=%1
if "%MODE%"=="" set MODE=debug
set COMMON=-collection:deps="%DEPS%" -vet -strict-style -warnings-as-errors
if "%MODE%"=="check" goto check

rem Recompile shaders when glslangValidator (Vulkan SDK) is available; otherwise use the committed .spv files.
where glslangValidator >nul 2>nul && (
	for %%s in ("%ROOT%src\render\shaders\*.vert" "%ROOT%src\render\shaders\*.frag") do glslangValidator -V --quiet "%%s" -o "%%s.spv" || goto fail
)

if not exist "%ROOT%build" mkdir "%ROOT%build"
copy /y "%DEPS%\odin\vendor\sdl3\SDL3.dll" "%ROOT%build\" >nul

if "%MODE%"=="debug" goto debug
if "%MODE%"=="run" goto debug
if "%MODE%"=="smoke" goto debug
if "%MODE%"=="release" goto release
if "%MODE%"=="test" goto test
if "%MODE%"=="bench" goto bench
if "%MODE%"=="gpubench" goto gpubench
echo unknown mode: %MODE%
exit /b 2

:check
rem Type-check every package with the strict flags: no link, no shaders, no build\.
rem Library packages have no main, hence -no-entry-point; it is harmless on the executables.
"%ODIN%" check "%ROOT%src\app" -no-entry-point %COMMON% || exit /b 1
"%ODIN%" check "%ROOT%src\bench" -no-entry-point %COMMON% || exit /b 1
"%ODIN%" check "%ROOT%src\geom" -no-entry-point %COMMON% || exit /b 1
"%ODIN%" check "%ROOT%src\camera" -no-entry-point %COMMON% || exit /b 1
"%ODIN%" check "%ROOT%src\gizmo" -no-entry-point %COMMON% || exit /b 1
"%ODIN%" check "%ROOT%src\jobs" -no-entry-point %COMMON% || exit /b 1
"%ODIN%" check "%ROOT%src\png_write" -no-entry-point %COMMON% || exit /b 1
"%ODIN%" check "%ROOT%src\render" -no-entry-point %COMMON% || exit /b 1
"%ODIN%" check "%ROOT%src\sculpt" -no-entry-point %COMMON% || exit /b 1
"%ODIN%" check "%ROOT%src\sdf_trial" -no-entry-point %COMMON% || exit /b 1
python "%ROOT%scripts\agents_sync.py" --check || exit /b 1
echo check: 10 packages type-check, agent mirror current
exit /b 0

:debug
"%ODIN%" build "%ROOT%src\app" -out:"%ROOT%build\sculpt.exe" -debug %COMMON% || exit /b 1
if "%MODE%"=="run" goto run
if "%MODE%"=="smoke" goto smoke
exit /b 0

:run
"%ROOT%build\sculpt.exe" %2 %3 %4 %5 %6
exit /b

:smoke
set SDL_ASSERT=abort
"%ROOT%build\sculpt.exe" --frames=300 --gpu-debug || exit /b 1
exit /b 0

:release
"%ODIN%" build "%ROOT%src\app" -out:"%ROOT%build\sculpt.exe" -o:speed -no-bounds-check %COMMON% || exit /b 1
exit /b 0

:test
"%ODIN%" test "%ROOT%src\geom" -out:"%ROOT%build\test_geom.exe" %COMMON% || exit /b 1
"%ODIN%" test "%ROOT%src\camera" -out:"%ROOT%build\test_camera.exe" %COMMON% || exit /b 1
"%ODIN%" test "%ROOT%src\sculpt" -out:"%ROOT%build\test_sculpt.exe" %COMMON% || exit /b 1
"%ODIN%" test "%ROOT%src\jobs" -out:"%ROOT%build\test_jobs.exe" %COMMON% || exit /b 1
"%ODIN%" test "%ROOT%src\gizmo" -out:"%ROOT%build\test_gizmo.exe" %COMMON% || exit /b 1
"%ODIN%" test "%ROOT%src\png_write" -out:"%ROOT%build\test_png_write.exe" %COMMON% || exit /b 1
exit /b 0

:bench
"%ODIN%" build "%ROOT%src\bench" -out:"%ROOT%build\bench.exe" -o:speed -no-bounds-check %COMMON% || exit /b 1
"%ROOT%build\bench.exe" %2 %3 %4 %5 %6
exit /b

:gpubench
"%ODIN%" build "%ROOT%src\app" -out:"%ROOT%build\sculpt.exe" -o:speed -no-bounds-check %COMMON% || exit /b 1
"%ROOT%build\sculpt.exe" --gpubench "%ROOT%build\gpubench.md" %2 %3 %4 %5 %6
exit /b

:fail
exit /b 1
