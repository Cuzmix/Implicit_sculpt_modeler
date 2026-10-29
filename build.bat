@echo off
rem Usage: build.bat [debug|release|test|run|smoke|bench|gpubench|computebench|check|iphonecheck|android|androidrun|all|clean]   (see build.sh for what each does)
rem Run scripts\setup_deps.bat first.
rem Modes are labels rather than if-blocks: an `exit /b 1` inside a parenthesised block
rem returns 0 to whoever ran `cmd /c build.bat`, so a failure would pass unnoticed.
setlocal
set ROOT=%~dp0
rem Cleaning needs no toolchain, so it comes before the check for one.
if "%1"=="clean" goto clean
set DEPS=%ROOT%deps
set ODIN=%DEPS%\odin\odin.exe
if not exist "%ODIN%" ( echo deps missing: run scripts\setup_deps.bat first & exit /b 1 )
set MODE=%1
if "%MODE%"=="" set MODE=debug
set COMMON=-collection:deps="%DEPS%" -vet -strict-style -warnings-as-errors
rem The oldest iPadOS the iPad build runs on; build.sh says why.
set IOS_MIN=17.4
if "%MODE%"=="check" goto check
if "%MODE%"=="all" goto all
if "%MODE%"=="iphonecheck" goto iphonecheck
if "%MODE%"=="android" goto android
if "%MODE%"=="androidrun" goto android
rem The app links Luau for script plugins and ufbx for FBX import, which setup_deps builds
rem from source.
if not exist "%DEPS%\luau\luau.lib" ( echo Luau missing: run scripts\setup_deps.bat, which builds deps\luau & exit /b 1 )
rem And ufbx for FBX import, with the app's shim round it (scripts\build_ufbx.py).
if not exist "%DEPS%\ufbx\ufbx.lib" ( echo ufbx missing: run scripts\setup_deps.bat, which builds deps\ufbx & exit /b 1 )

rem Recompile the Slang shaders when slangc is in deps\slang\bin or on the PATH (the Vulkan SDK
rem installs it); otherwise use the committed .spv files. build.sh describes the rules.
set SLANGC=
if exist "%DEPS%\slang\bin\slangc.exe" set SLANGC=%DEPS%\slang\bin\slangc.exe
if not defined SLANGC for /f "delims=" %%p in ('where slangc 2^>nul') do if not defined SLANGC set SLANGC=%%p
if defined SLANGC call :shaders || goto fail

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
"%ODIN%" check "%ROOT%src\fbx" -no-entry-point %COMMON% || exit /b 1
"%ODIN%" check "%ROOT%src\geom" -no-entry-point %COMMON% || exit /b 1
"%ODIN%" check "%ROOT%src\camera" -no-entry-point %COMMON% || exit /b 1
"%ODIN%" check "%ROOT%src\gizmo" -no-entry-point %COMMON% || exit /b 1
"%ODIN%" check "%ROOT%src\jobs" -no-entry-point %COMMON% || exit /b 1
"%ODIN%" check "%ROOT%src\luau" -no-entry-point %COMMON% || exit /b 1
"%ODIN%" check "%ROOT%src\png_write" -no-entry-point %COMMON% || exit /b 1
"%ODIN%" check "%ROOT%src\poly" -no-entry-point %COMMON% || exit /b 1
"%ODIN%" check "%ROOT%src\render" -no-entry-point %COMMON% || exit /b 1
"%ODIN%" check "%ROOT%src\sculpt" -no-entry-point %COMMON% || exit /b 1
"%ODIN%" check "%ROOT%src\sdf_trial" -no-entry-point %COMMON% || exit /b 1
"%ODIN%" check "%ROOT%src\ui" -no-entry-point %COMMON% || exit /b 1
"%ODIN%" check "%ROOT%src\usd" -no-entry-point %COMMON% || exit /b 1
"%ODIN%" check "%ROOT%src\voxel" -no-entry-point %COMMON% || exit /b 1
"%ODIN%" check "%ROOT%src\zip" -no-entry-point %COMMON% || exit /b 1
python "%ROOT%scripts\agents_sync.py" --check || exit /b 1
python "%ROOT%scripts\boundary_check.py" || exit /b 1
python "%ROOT%scripts\shaders_msl.py" --check || exit /b 1
echo check: 17 packages type-check, agent mirror current, only render names the GPU API, Metal shaders current
exit /b 0

:iphonecheck
rem The app for the iPad as the arm64 object build.sh ios links on a Mac, without Xcode or
rem linking, so iOS-only compile errors show up here too.
if not exist "%ROOT%build\ios" mkdir "%ROOT%build\ios"
"%ODIN%" build "%ROOT%src\app" -target:darwin_arm64 -subtarget:iphone -build-mode:obj -use-single-module -minimum-os-version:%IOS_MIN% -out:"%ROOT%build\ios\sculpt.o" %COMMON% -o:speed -no-bounds-check || exit /b 1
echo iphonecheck: app compiles for the iPad (arm64, iPadOS %IOS_MIN%)
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
rem Once on each GPU backend; a Vulkan validation message fails it.
"%ROOT%build\sculpt.exe" --frames=300 --gpu-debug --view-windows=1 --gpu=sdl || exit /b 1
"%ROOT%build\sculpt.exe" --frames=300 --gpu-debug --view-windows=1 --gpu=vulkan || exit /b 1
exit /b 0

:release
"%ODIN%" build "%ROOT%src\app" -out:"%ROOT%build\sculpt.exe" -o:speed -no-bounds-check %COMMON% || exit /b 1
exit /b 0

:test
"%ODIN%" test "%ROOT%src\geom" -out:"%ROOT%build\test_geom.exe" %COMMON% || exit /b 1
"%ODIN%" test "%ROOT%src\poly" -out:"%ROOT%build\test_poly.exe" %COMMON% || exit /b 1
"%ODIN%" test "%ROOT%src\camera" -out:"%ROOT%build\test_camera.exe" %COMMON% || exit /b 1
"%ODIN%" test "%ROOT%src\sculpt" -out:"%ROOT%build\test_sculpt.exe" %COMMON% || exit /b 1
"%ODIN%" test "%ROOT%src\voxel" -out:"%ROOT%build\test_voxel.exe" %COMMON% || exit /b 1
"%ODIN%" test "%ROOT%src\jobs" -out:"%ROOT%build\test_jobs.exe" %COMMON% || exit /b 1
"%ODIN%" test "%ROOT%src\gizmo" -out:"%ROOT%build\test_gizmo.exe" %COMMON% || exit /b 1
"%ODIN%" test "%ROOT%src\png_write" -out:"%ROOT%build\test_png_write.exe" %COMMON% || exit /b 1
"%ODIN%" test "%ROOT%src\zip" -out:"%ROOT%build\test_zip.exe" %COMMON% || exit /b 1
"%ODIN%" test "%ROOT%src\ui" -out:"%ROOT%build\test_ui.exe" %COMMON% || exit /b 1
"%ODIN%" test "%ROOT%src\luau" -out:"%ROOT%build\test_luau.exe" %COMMON% || exit /b 1
"%ODIN%" test "%ROOT%src\usd" -out:"%ROOT%build\test_usd.exe" %COMMON% || exit /b 1
"%ODIN%" test "%ROOT%src\fbx" -out:"%ROOT%build\test_fbx.exe" %COMMON% || exit /b 1
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

:all
rem Everything that builds, stopping at the first failure: check, the release app (so
rem release-only errors show) and then the debug one, which build\sculpt.exe is left as, the
rem tests, the iPad compile check, and the Android APK when Android Studio's SDK is there.
rem Smoke and the touch scenarios need a display: scripts\gate.py runs them.
call "%~f0" check || goto fail
call "%~f0" release || goto fail
call "%~f0" debug || goto fail
call "%~f0" test || goto fail
call "%~f0" iphonecheck || goto fail
set "SDK=%ANDROID_HOME%"
if not defined SDK set "SDK=%LOCALAPPDATA%\Android\Sdk"
if not exist "%SDK%\platform-tools" goto all_no_android
call "%~f0" android || goto fail
echo all: check, release, debug, test, iphonecheck and android done; build\sculpt.exe is the debug app
exit /b 0

:all_no_android
echo all: check, release, debug, test and iphonecheck done; no Android SDK in %SDK%, so no APK; build\sculpt.exe is the debug app
exit /b 0

:clean
rem The builds' outputs: build\ (the apps, tests, gate logs, dumps, the iPad object) and the
rem Android build's. deps\ stays: setup_deps made it, and it is the pinned toolchain.
for %%d in ("%ROOT%build" "%ROOT%android\.gradle" "%ROOT%android\build" "%ROOT%android\app\build" "%ROOT%android\app\.cxx") do if exist "%%~d" rmdir /s /q "%%~d"
for %%d in ("%ROOT%build" "%ROOT%android\.gradle" "%ROOT%android\build" "%ROOT%android\app\build" "%ROOT%android\app\.cxx") do if exist "%%~d" goto clean_busy
echo clean: build\ and the Android build's outputs removed
exit /b 0

:clean_busy
echo clean: a file under build\ or android\ is in use (a running app or a Gradle daemon); close it and clean again
exit /b 1

:fail
exit /b 1

:shaders
rem Each name.stage.slang to the name.stage.spv the renderer embeds (build.sh has the rules).
for %%s in ("%ROOT%src\render\shaders\*.vert.slang") do call :shader "%%s" vertex || exit /b 1
for %%s in ("%ROOT%src\render\shaders\*.frag.slang") do call :shader "%%s" fragment || exit /b 1
for %%s in ("%ROOT%src\render\shaders\*.comp.slang") do call :shader "%%s" compute || exit /b 1
rem Each new .spv's Metal source for the iPad build, when SDL_shadercross is built (build.sh says more).
if exist "%DEPS%\shadercross\shadercross.exe" python "%ROOT%scripts\shaders_msl.py" || exit /b 1
exit /b 0

:shader
set FLAGS=
findstr /b /c:"// slangc: -fp-mode precise" %1 >nul && set FLAGS=-fp-mode precise
"%SLANGC%" %1 -target spirv -profile spirv_1_3 -matrix-layout-row-major -O0 -stage %2 -entry main %FLAGS% -o "%~dpn1.spv"
exit /b
