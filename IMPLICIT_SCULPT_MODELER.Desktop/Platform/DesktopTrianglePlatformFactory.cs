using System;
using System.Diagnostics.CodeAnalysis;
using IMPLICIT_SCULPT_MODELER.Controls;
using IMPLICIT_SCULPT_MODELER.Platform;

namespace IMPLICIT_SCULPT_MODELER.Desktop.Platform;

internal sealed class DesktopTrianglePlatformFactory : ITrianglePlatformFactory
{
    public bool TryCreateHost([NotNullWhen(true)] out WebGpuHostControl? host, out string? unsupportedReason)
    {
        if (!OperatingSystem.IsWindows())
        {
            host = null;
            unsupportedReason = "The first desktop WebGPU host is wired for the Windows HWND path only.";
            return false;
        }

        host = new Win32WebGpuHostControl();
        unsupportedReason = null;
        return true;
    }
}
