using System;
using System.ComponentModel;
using System.Runtime.Versioning;
using Avalonia.Platform;
using IMPLICIT_SCULPT_MODELER.Controls;
using Silk.NET.WebGPU;

namespace IMPLICIT_SCULPT_MODELER.Desktop.Platform;

[SupportedOSPlatform("windows")]
internal sealed class Win32WebGpuHostControl : WebGpuHostControl
{
    private IntPtr _hwnd;

    protected override IPlatformHandle CreateNativeControlCore(IPlatformHandle parent)
    {
        _hwnd = Win32NativeMethods.CreateWindowEx(
            0,
            "Static",
            null,
            Win32NativeMethods.WsChild | Win32NativeMethods.WsVisible | Win32NativeMethods.WsClipchildren | Win32NativeMethods.WsClipsiblings,
            0,
            0,
            1,
            1,
            parent.Handle,
            IntPtr.Zero,
            Win32NativeMethods.GetModuleHandle(null),
            IntPtr.Zero);

        if (_hwnd == IntPtr.Zero)
        {
            throw new Win32Exception("The Windows WebGPU child host could not be created.");
        }

        MarkSurfaceReady();
        return new PlatformHandle(_hwnd, "HWND");
    }

    protected override void DestroyNativeControlCore(IPlatformHandle control)
    {
        MarkSurfaceUnavailable();

        if (_hwnd == IntPtr.Zero)
        {
            return;
        }

        Win32NativeMethods.DestroyWindow(_hwnd);
        _hwnd = IntPtr.Zero;
    }

    public override unsafe Surface* CreateSurface(WebGPU api, Instance* instance)
    {
        if (_hwnd == IntPtr.Zero)
        {
            return null;
        }

        var hwndDescriptor = new SurfaceDescriptorFromWindowsHWND
        {
            Chain = new ChainedStruct
            {
                SType = SType.SurfaceDescriptorFromWindowsHwnd
            },
            Hinstance = (void*)Win32NativeMethods.GetModuleHandle(null),
            Hwnd = (void*)_hwnd
        };

        var surfaceDescriptor = new SurfaceDescriptor
        {
            NextInChain = (ChainedStruct*)&hwndDescriptor
        };

        return api.InstanceCreateSurface(instance, &surfaceDescriptor);
    }
}
