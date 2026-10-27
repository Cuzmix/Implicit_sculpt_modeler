@echo off
rem Usage: build.bat [debug|release|test|run|smoke|bench|gpubench|computebench|check|android|androidrun]   (see build.sh for what each does)
rem Run scripts\setup_deps.bat first.
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
if "%MODE%"=="android" goto android
if "%MODE%"=="androidrun" goto android

rem Recompile shaders when glslangValidator (Vulkan SDK) is available; otherwise use the committed .spv files.
where glslangValidator >nul 2>nul && (
	for %%s in ("%ROOT%src\render\shaders\*.vert" "%ROOT%src\render\shaders\*.frag" "%ROOT%src\render\shaders\*.comp") do glslangValidator -V --quiet "%%s" -o "%%s.spv" || goto fail
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
if "%MODE%"=="computebench" goto computebench
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
"%ODIN%" check "%ROOT%src\ui" -no-entry-point %COMMON% || exit /b 1
"%ODIN%" check "%ROOT%src\voxel" -no-entry-point %COMMON% || exit /b 1
python "%ROOT%scripts\agents_sync.py" --check || exit /b 1
echo check: 12 packages type-check, agent mirror current
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
"%ODIN%" test "%ROOT%src\voxel" -out:"%ROOT%build\test_voxel.exe" %COMMON% || exit /b 1
"%ODIN%" test "%ROOT%src\jobs" -out:"%ROOT%build\test_jobs.exe" %COMMON% || exit /b 1
"%ODIN%" test "%ROOT%src\gizmo" -out:"%ROOT%build\test_gizmo.exe" %COMMON% || exit /b 1
"%ODIN%" test "%ROOT%src\png_write" -out:"%ROOT%build\test_png_write.exe" %COMMON% || exit /b 1
"%ODIN%" test "%ROOT%src\ui" -out:"%ROOT%build\test_ui.exe" %COMMON% || exit /b 1
"%ODIN%" test "%ROOT%src\app" -out:"%ROOT%build\test_app.exe" %COMMON% || exit /b 1
exit /b 0

:bench
"%ODIN%" build "%ROOT%src\bench" -out:"%ROOT%build\bench.exe" -o:speed -no-bounds-check %COMMON% || exit /b 1
"%ROOT%build\bench.exe" %2 %3 %4 %5 %6
exit /b

:gpubench
"%ODIN%" build "%ROOT%src\app" -out:"%ROOT%build\sculpt.exe" -o:speed -no-bounds-check %COMMON% || exit /b 1
"%ROOT%build\sculpt.exe" --gpubench "%ROOT%build\gpubench.md" %2 %3 %4 %5 %6
exit /b

:computebench
"%ODIN%" build "%ROOT%src\app" -out:"%ROOT%build\sculpt.exe" -o:speed -no-bounds-check %COMMON% || exit /b 1
"%ROOT%build\sculpt.exe" --compute-bench "%ROOT%build\computebench.md" %2 %3 %4 %5 %6
exit /b

:android
rem The Android app (README.md, Android): Gradle builds SDL, stb_truetype and src\app (Odin) for
rem arm64 with the NDK into an APK; androidrun also installs it on the tablet adb sees and
rem starts it. Android Studio's SDK and Java are used unless ANDROID_HOME and JAVA_HOME
rem name others.
if not exist "%DEPS%\sdl3-src\CMakeLists.txt" ( echo SDL source missing: run scripts\setup_android.bat first & exit /b 1 )
if not defined ANDROID_HOME set "ANDROID_HOME=%LOCALAPPDATA%\Android\Sdk"
if not defined JAVA_HOME set "JAVA_HOME=%ProgramFiles%\Android\Android Studio\jbr"
if not exist "%ANDROID_HOME%\platform-tools" ( echo no Android SDK in %ANDROID_HOME%: install Android Studio, or set ANDROID_HOME & exit /b 1 )
if not exist "%JAVA_HOME%\bin\java.exe" ( echo no Java in %JAVA_HOME%: install Android Studio, or set JAVA_HOME & exit /b 1 )
set TASK=assembleDebug
if "%MODE%"=="androidrun" set TASK=installDebug
pushd "%ROOT%android"
rem .\ because cmd skips the current folder when NoDefaultCurrentDirectoryInExePath is set.
call .\gradlew.bat %TASK% || goto android_fail
popd
if "%MODE%"=="android" echo android: android\app\build\outputs\apk\debug\app-debug.apk
if "%MODE%"=="androidrun" "%ANDROID_HOME%\platform-tools\adb.exe" shell am start -n io.github.cuzmix.sculpt/org.libsdl.app.SDLActivity || exit /b 1
exit /b 0

:android_fail
popd
exit /b 1

:fail
exit /b 1
