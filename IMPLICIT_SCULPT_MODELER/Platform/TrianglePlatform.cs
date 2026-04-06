using System.Diagnostics.CodeAnalysis;
using IMPLICIT_SCULPT_MODELER.Controls;

namespace IMPLICIT_SCULPT_MODELER.Platform;

public interface ITrianglePlatformFactory
{
    bool TryCreateHost([NotNullWhen(true)] out WebGpuHostControl? host, out string? unsupportedReason);
}

public static class TrianglePlatform
{
    private static ITrianglePlatformFactory? _factory;

    public static void Configure(ITrianglePlatformFactory factory)
    {
        _factory = factory;
    }

    public static bool TryCreateHost([NotNullWhen(true)] out WebGpuHostControl? host, out string? unsupportedReason)
    {
        if (_factory is null)
        {
            host = null;
            unsupportedReason = "This app head did not register a WebGPU host factory before Avalonia started.";
            return false;
        }

        return _factory.TryCreateHost(out host, out unsupportedReason);
    }
}
