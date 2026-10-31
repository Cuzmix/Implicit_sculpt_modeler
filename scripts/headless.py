#!/usr/bin/env python3
"""How a script opens the app's window on this machine, shared by gate.py, touch_check.py
and the other scripts that run build/sculpt.

On a desktop the window opens on the desktop's display. On Linux with no display there
are two ways:
    offscreen  SDL's offscreen video driver: no display at all, so every run has its own
               window and runs side by side need no private servers. A cloud container's
               SDL (setup_deps.sh without the X11 headers) has only this one.
    xvfb       an X virtual framebuffer per run, when SDL has its X11 driver and Xvfb is
               installed.
Vulkan needs a driver too: where the system lists none, the SwiftShader driver that ships
with the pre-installed Chromium is used.

    python scripts/headless.py        # prints the mode and the environment it adds
"""
import ctypes
import glob
import os
import shutil
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
WINDOWS = os.name == "nt"
LINUX = sys.platform.startswith("linux")
# The system's Vulkan driver lists, in the order the loader reads them.
ICD_FOLDERS = ["/etc/vulkan/icd.d", "/usr/local/share/vulkan/icd.d", "/usr/share/vulkan/icd.d"]
# Chromium's SwiftShader Vulkan driver, where Playwright puts its browsers.
SWIFTSHADER = "/opt/pw-browsers/chromium-*/chrome-linux64/vk_swiftshader_icd.json"


def has_display():
    return WINDOWS or not LINUX or bool(os.environ.get("DISPLAY") or os.environ.get("WAYLAND_DISPLAY"))


def video_drivers():
    """The video drivers the app's SDL was built with (Linux), or None when it cannot be read."""
    lib = os.path.join(ROOT, "deps", "sdl3", "lib", "libSDL3.so")
    if not LINUX or not os.path.exists(lib):
        return None
    try:
        sdl = ctypes.CDLL(lib)
        sdl.SDL_GetVideoDriver.restype = ctypes.c_char_p
        return [sdl.SDL_GetVideoDriver(i).decode() for i in range(sdl.SDL_GetNumVideoDrivers())]
    except (OSError, AttributeError):
        return None


def mode():
    """'display' (a desktop's own), 'offscreen', 'xvfb', or 'none' (no way to open a window)."""
    if has_display():
        return "display"
    drivers = video_drivers()
    if drivers is not None and "x11" not in drivers and "offscreen" in drivers:
        return "offscreen"
    if shutil.which("Xvfb") or shutil.which("xvfb-run"):
        return "xvfb"
    return "offscreen" if drivers and "offscreen" in drivers else "none"


def vulkan_driver():
    """The Vulkan driver list to name for the loader, or None when the system has its own."""
    if not LINUX or os.environ.get("VK_ICD_FILENAMES") or os.environ.get("VK_DRIVER_FILES"):
        return None
    for folder in ICD_FOLDERS:
        if glob.glob(os.path.join(folder, "*.json")):
            return None
    found = sorted(glob.glob(SWIFTSHADER))
    return found[-1] if found else None


def env(base=None):
    """`base` (the process's environment by default) with what the app needs to open its
    window here: the offscreen driver when that is the mode, and a Vulkan driver when the
    system lists none."""
    out = dict(os.environ if base is None else base)
    if mode() == "offscreen":
        out["SDL_VIDEO_DRIVER"] = "offscreen"
        out.pop("DISPLAY", None)
    icd = vulkan_driver()
    if icd:
        out["VK_ICD_FILENAMES"] = icd
    return out


def wrap(cmd, screen="1600x1400x24"):
    """`cmd` run where it can open a window: under xvfb-run when that is the mode."""
    if mode() == "xvfb" and shutil.which("xvfb-run"):
        return ["xvfb-run", "-a", "-s", f"-screen 0 {screen}"] + cmd
    return cmd


if __name__ == "__main__":
    print(f"mode={mode()} drivers={video_drivers()} vulkan={vulkan_driver() or 'system'}")
