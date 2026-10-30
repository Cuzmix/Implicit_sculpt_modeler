@echo off
rem Fetches and builds pinned dependencies into deps\ (Windows x64).
rem Needs Visual Studio with the "Desktop development with C++" workload: Odin links with its
rem link.exe and the Windows SDK, which it finds itself, so any command prompt works.
rem Also needs: git, python, curl and tar (both ship with Windows 10+).
rem Odin's Windows release ships SDL3.dll and SDL3.lib in vendor\sdl3, so SDL is not built here.
setlocal
set ROOT=%~dp0..
for /f "usebackq tokens=1,2 delims==" %%a in ("%ROOT%\scripts\versions.env") do (
	if not "%%a"=="" if not "%%b"=="" set %%a=%%b
)
set DEPS=%ROOT%\deps
if not exist "%DEPS%" mkdir "%DEPS%"

if not exist "%DEPS%\odin\odin.exe" (
	echo == Odin %ODIN_TAG%
	curl -fsSL -o "%DEPS%\odin.zip" https://github.com/odin-lang/Odin/releases/download/%ODIN_TAG%/odin-windows-amd64-%ODIN_TAG%.zip || exit /b 1
	tar -xf "%DEPS%\odin.zip" -C "%DEPS%" || exit /b 1
	move "%DEPS%\dist" "%DEPS%\odin" >nul || exit /b 1
	del "%DEPS%\odin.zip"
)
"%DEPS%\odin\odin.exe" version || exit /b 1

rem stb's C libraries: vendor:fontstash (the UI's text) links stb_truetype and stb_rect_pack.
rem Odin's Windows release ships them built; should they be missing, they are built here.
if not exist "%DEPS%\odin\vendor\stb\lib\stb_truetype.lib" (
	echo == stb
	call :msvc || exit /b 1
	call "%DEPS%\odin\vendor\stb\src\build.bat" || exit /b 1
)

rem Luau, the language of script plugins, built from source with cl (scripts\build_luau.py).
call :msvc || exit /b 1
python "%ROOT%\scripts\build_luau.py" || exit /b 1

rem ufbx, the FBX reader Import uses, with the app's shim round it (scripts\build_ufbx.py).
python "%ROOT%\scripts\build_ufbx.py" || exit /b 1

rem AutoRemesher's core, the Quad Remesh engine, with the app's boundary (scripts\build_autoremesher.py).
python "%ROOT%\scripts\build_autoremesher.py" || exit /b 1

echo Dependencies ready in %DEPS%
exit /b 0

rem Puts MSVC's cl and lib on PATH for the C and C++ built here (stb, Luau, ufbx): vswhere finds
rem the newest Visual Studio with the C++ tools and its vcvarsall.bat sets them up;
rem vcvarsall.bat's own helpers call vswhere.exe by name, so its folder goes on PATH too.
:msvc
where cl >nul 2>nul && exit /b 0
set "PATH=%ProgramFiles(x86)%\Microsoft Visual Studio\Installer;%PATH%"
where vswhere.exe >nul 2>nul && for /f "usebackq delims=" %%i in (`vswhere.exe -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath`) do set "PATH=%%i\VC\Auxiliary\Build;%PATH%"
where vcvarsall.bat >nul 2>nul && goto msvc_found
echo no Visual Studio with the C++ tools found: install it with the "Desktop development with C++" workload
exit /b 1
:msvc_found
call vcvarsall.bat x64 >nul
exit /b 0
