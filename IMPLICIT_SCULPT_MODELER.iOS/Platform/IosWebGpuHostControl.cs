using System;
using System.Runtime.Versioning;
using Avalonia.Platform;
using Avalonia.iOS;
using CoreAnimation;
using IMPLICIT_SCULPT_MODELER.Controls;
using ObjCRuntime;
using Silk.NET.WebGPU;
using UIKit;

namespace IMPLICIT_SCULPT_MODELER.iOS.Platform;

[SupportedOSPlatform("ios")]
internal sealed class IosWebGpuHostControl : WebGpuHostControl
{
    private TriangleMetalView? _view;
    private CAMetalLayer? _metalLayer;

    protected override IPlatformHandle CreateNativeControlCore(IPlatformHandle parent)
    {
        _view = new TriangleMetalView
        {
            Opaque = true,
            BackgroundColor = UIColor.Black,
            ContentScaleFactor = UIScreen.MainScreen.Scale
        };
        _metalLayer = _view.MetalLayer;

        MarkSurfaceReady();
        return new UIViewControlHandle(_view);
    }

    protected override void DestroyNativeControlCore(IPlatformHandle control)
    {
        MarkSurfaceUnavailable();

        if (_view is null)
        {
            return;
        }

        _view.RemoveFromSuperview();
        _view.Dispose();
        _view = null;
        _metalLayer = null;
    }

    public override unsafe Surface* CreateSurface(WebGPU api, Instance* instance)
    {
        var metalLayerHandle = _metalLayer?.Handle ?? IntPtr.Zero;

        if (metalLayerHandle == IntPtr.Zero)
        {
            return null;
        }

        var layerDescriptor = new SurfaceDescriptorFromMetalLayer
        {
            Chain = new ChainedStruct
            {
                SType = SType.SurfaceDescriptorFromMetalLayer
            },
            Layer = (void*)metalLayerHandle
        };

        var surfaceDescriptor = new SurfaceDescriptor
        {
            NextInChain = (ChainedStruct*)&layerDescriptor
        };

        return api.InstanceCreateSurface(instance, &surfaceDescriptor);
    }

    private sealed class TriangleMetalView : UIView
    {
        public TriangleMetalView()
        {
            MetalLayer = new CAMetalLayer
            {
                Opaque = true,
                ContentsScale = UIScreen.MainScreen.Scale,
                NeedsDisplayOnBoundsChange = true
            };

            Layer.AddSublayer(MetalLayer);
        }

        public CAMetalLayer MetalLayer { get; }

        public override void LayoutSubviews()
        {
            base.LayoutSubviews();
            MetalLayer.Frame = Bounds;
        }
    }
}
