using System.Diagnostics.CodeAnalysis;
using IMPLICIT_SCULPT_MODELER.Controls;
using IMPLICIT_SCULPT_MODELER.Platform;

namespace IMPLICIT_SCULPT_MODELER.iOS.Platform;

internal sealed class IosTrianglePlatformFactory : ITrianglePlatformFactory
{
    public bool TryCreateHost([NotNullWhen(true)] out WebGpuHostControl? host, out string? unsupportedReason)
    {
        host = new IosWebGpuHostControl();
        unsupportedReason = null;
        return true;
    }
}
