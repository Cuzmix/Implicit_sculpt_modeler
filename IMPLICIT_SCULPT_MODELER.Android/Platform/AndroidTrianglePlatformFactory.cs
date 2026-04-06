using System.Diagnostics.CodeAnalysis;
using IMPLICIT_SCULPT_MODELER.Controls;
using IMPLICIT_SCULPT_MODELER.Platform;

namespace IMPLICIT_SCULPT_MODELER.Android.Platform;

internal sealed class AndroidTrianglePlatformFactory : ITrianglePlatformFactory
{
    public bool TryCreateHost([NotNullWhen(true)] out WebGpuHostControl? host, out string? unsupportedReason)
    {
        if (MainActivity.Current is null)
        {
            host = null;
            unsupportedReason = "The Android activity is not ready yet.";
            return false;
        }

        host = new AndroidWebGpuHostControl();
        unsupportedReason = null;
        return true;
    }
}
