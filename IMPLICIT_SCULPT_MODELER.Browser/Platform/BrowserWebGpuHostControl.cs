using System;
using System.Runtime.InteropServices.JavaScript;
using Avalonia.Browser;
using Avalonia.Platform;
using IMPLICIT_SCULPT_MODELER.Controls;
using Silk.NET.Core.Native;
using Silk.NET.WebGPU;

namespace IMPLICIT_SCULPT_MODELER.Browser.Platform;

internal sealed partial class BrowserWebGpuHostControl : WebGpuHostControl
{
    private JSObject? _canvas;
    private string? _canvasId;

    protected override IPlatformHandle CreateNativeControlCore(IPlatformHandle parent)
    {
        if (parent is not JSObjectPlatformHandle browserParent)
        {
            throw new InvalidOperationException("Avalonia did not provide a browser JS object handle for the TriangleViewport.");
        }

        _canvasId = $"triangle-canvas-{Guid.NewGuid():N}";
        _canvas = BrowserTriangleInterop.CreateTriangleCanvas(browserParent.Object, _canvasId);

        MarkSurfaceReady();
        return new JSObjectControlHandle(_canvas);
    }

    protected override void DestroyNativeControlCore(IPlatformHandle control)
    {
        MarkSurfaceUnavailable();

        if (!string.IsNullOrWhiteSpace(_canvasId))
        {
            BrowserTriangleInterop.DestroyTriangleCanvas(_canvasId);
        }

        _canvas?.Dispose();
        _canvas = null;
        _canvasId = null;
    }

    public override unsafe Surface* CreateSurface(WebGPU api, Instance* instance)
    {
        if (string.IsNullOrWhiteSpace(_canvasId))
        {
            return null;
        }

        var selectorPointer = (byte*)SilkMarshal.StringToPtr($"#{_canvasId}");

        try
        {
            var canvasDescriptor = new SurfaceDescriptorFromCanvasHTMLSelector
            {
                Chain = new ChainedStruct
                {
                    SType = SType.SurfaceDescriptorFromCanvasHtmlSelector
                },
                Selector = selectorPointer
            };

            var surfaceDescriptor = new SurfaceDescriptor
            {
                NextInChain = (ChainedStruct*)&canvasDescriptor
            };

            return api.InstanceCreateSurface(instance, &surfaceDescriptor);
        }
        finally
        {
            SilkMarshal.Free((nint)selectorPointer);
        }
    }
}

internal static partial class BrowserTriangleInterop
{
    [JSImport("createTriangleCanvas", "./triangle-host.js")]
    internal static partial JSObject CreateTriangleCanvas(JSObject hostElement, string canvasId);

    [JSImport("destroyTriangleCanvas", "./triangle-host.js")]
    internal static partial void DestroyTriangleCanvas(string canvasId);
}
