using System.Diagnostics.CodeAnalysis;
using IMPLICIT_SCULPT_MODELER.Controls;
using IMPLICIT_SCULPT_MODELER.Platform;

namespace IMPLICIT_SCULPT_MODELER.Browser.Platform;

internal sealed class BrowserTrianglePlatformFactory : ITrianglePlatformFactory
{
    public bool TryCreateHost([NotNullWhen(true)] out WebGpuHostControl? host, out string? unsupportedReason)
    {
        host = new BrowserWebGpuHostControl();
        unsupportedReason = null;
        return true;
    }
}
