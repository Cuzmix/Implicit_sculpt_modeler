@echo off
rem Fetches and builds pinned dependencies into deps\ (Windows x64).
rem Run from an "x64 Native Tools Command Prompt for VS" (needs cl.exe for ImGui, and link.exe for Odin).
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
if not exist "%DEPS%\odin\vendor\stb\lib\stb_truetype.lib" (
	echo == stb
	call "%DEPS%\odin\vendor\stb\src\build.bat" || exit /b 1
)

if not exist "%DEPS%\odin-imgui\imgui_windows_x64.lib.built" (
	echo == odin-imgui %ODIN_IMGUI_COMMIT%
	if exist "%DEPS%\odin-imgui" rmdir /s /q "%DEPS%\odin-imgui"
	git clone -q https://gitlab.com/L-4/odin-imgui.git "%DEPS%\odin-imgui" || exit /b 1
	git -C "%DEPS%\odin-imgui" -c advice.detachedHead=false checkout -q %ODIN_IMGUI_COMMIT% || exit /b 1
	python -c "import re,io;p=r'%DEPS%\odin-imgui\build.py';s=io.open(p).read();s=re.sub(r'(?m)^wanted_backends = .*\n(\t+.*\n)?','wanted_backends = [\"sdl3\", \"sdlgpu3\"]\n',s,1);io.open(p,'w').write(s)" || exit /b 1
	pushd "%DEPS%\odin-imgui" && python build.py && popd || exit /b 1
	echo built> "%DEPS%\odin-imgui\imgui_windows_x64.lib.built"
)
echo Dependencies ready in %DEPS%
