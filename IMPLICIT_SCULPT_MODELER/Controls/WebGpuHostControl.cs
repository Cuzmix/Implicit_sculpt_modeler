using System;
using Avalonia;
using Avalonia.Controls;
using Silk.NET.WebGPU;

namespace IMPLICIT_SCULPT_MODELER.Controls;

public abstract class WebGpuHostControl : NativeControlHost
{
    public event EventHandler? SurfaceChanged;

    public bool IsReady { get; private set; }

    public PixelSize GetPixelSize()
    {
        var scaling = TopLevel.GetTopLevel(this)?.RenderScaling ?? 1d;
        var width = Math.Max(1, (int)Math.Ceiling(Bounds.Width * scaling));
        var height = Math.Max(1, (int)Math.Ceiling(Bounds.Height * scaling));
        return new PixelSize(width, height);
    }

    public abstract unsafe Surface* CreateSurface(WebGPU api, Instance* instance);

    protected void MarkSurfaceReady()
    {
        var changed = !IsReady;
        IsReady = true;
        if (changed)
        {
            OnSurfaceChanged();
        }
    }

    protected void MarkSurfaceUnavailable()
    {
        var changed = IsReady;
        IsReady = false;
        if (changed)
        {
            OnSurfaceChanged();
        }
    }

    protected void NotifySurfaceChanged()
    {
        OnSurfaceChanged();
    }

    protected override void OnDetachedFromVisualTree(VisualTreeAttachmentEventArgs e)
    {
        MarkSurfaceUnavailable();
        base.OnDetachedFromVisualTree(e);
    }

    private void OnSurfaceChanged()
    {
        SurfaceChanged?.Invoke(this, EventArgs.Empty);
    }
}
