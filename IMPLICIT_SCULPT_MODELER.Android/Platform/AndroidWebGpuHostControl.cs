using System;
using System.Runtime.InteropServices;
using Android.Graphics;
using Android.Runtime;
using Android.Views;
using Avalonia.Android;
using Avalonia.Platform;
using IMPLICIT_SCULPT_MODELER.Controls;
using Silk.NET.WebGPU;

namespace IMPLICIT_SCULPT_MODELER.Android.Platform;

internal sealed class AndroidWebGpuHostControl : WebGpuHostControl
{
    private readonly SurfaceCallback _surfaceCallback;
    private SurfaceView? _surfaceView;
    private IntPtr _nativeWindow;

    public AndroidWebGpuHostControl()
    {
        _surfaceCallback = new SurfaceCallback(this);
    }

    protected override IPlatformHandle CreateNativeControlCore(IPlatformHandle parent)
    {
        var activity = MainActivity.Current ?? throw new InvalidOperationException("The Android activity is not ready.");
        _surfaceView = new SurfaceView(activity);
        _surfaceView.Holder?.AddCallback(_surfaceCallback);
        return new AndroidViewControlHandle(_surfaceView);
    }

    protected override void DestroyNativeControlCore(IPlatformHandle control)
    {
        ReleaseNativeWindow();

        if (_surfaceView is not null)
        {
            _surfaceView.Holder?.RemoveCallback(_surfaceCallback);
            _surfaceView.Dispose();
            _surfaceView = null;
        }

        MarkSurfaceUnavailable();
    }

    public override unsafe Silk.NET.WebGPU.Surface* CreateSurface(WebGPU api, Instance* instance)
    {
        if (_nativeWindow == IntPtr.Zero)
        {
            return null;
        }

        var nativeWindowDescriptor = new SurfaceDescriptorFromAndroidNativeWindow
        {
            Chain = new ChainedStruct
            {
                SType = SType.SurfaceDescriptorFromAndroidNativeWindow
            },
            Window = (void*)_nativeWindow
        };

        var surfaceDescriptor = new SurfaceDescriptor
        {
            NextInChain = (ChainedStruct*)&nativeWindowDescriptor
        };

        return api.InstanceCreateSurface(instance, &surfaceDescriptor);
    }

    private void OnSurfaceChanged(ISurfaceHolder? holder)
    {
        UpdateNativeWindow(holder?.Surface);
    }

    private void OnSurfaceDestroyed()
    {
        ReleaseNativeWindow();
        MarkSurfaceUnavailable();
        NotifySurfaceChanged();
    }

    private void UpdateNativeWindow(global::Android.Views.Surface? surface)
    {
        ReleaseNativeWindow();

        if (surface is null || surface.Handle == IntPtr.Zero)
        {
            MarkSurfaceUnavailable();
            return;
        }

        _nativeWindow = ANativeWindowFromSurface(JNIEnv.Handle, surface.Handle);

        if (_nativeWindow == IntPtr.Zero)
        {
            MarkSurfaceUnavailable();
            return;
        }

        MarkSurfaceReady();
        NotifySurfaceChanged();
    }

    private void ReleaseNativeWindow()
    {
        if (_nativeWindow == IntPtr.Zero)
        {
            return;
        }

        ANativeWindowRelease(_nativeWindow);
        _nativeWindow = IntPtr.Zero;
    }

    [DllImport("android", EntryPoint = "ANativeWindow_fromSurface")]
    private static extern IntPtr ANativeWindowFromSurface(IntPtr jniEnvironment, IntPtr surface);

    [DllImport("android", EntryPoint = "ANativeWindow_release")]
    private static extern void ANativeWindowRelease(IntPtr nativeWindow);

    private sealed class SurfaceCallback : Java.Lang.Object, ISurfaceHolderCallback
    {
        private readonly AndroidWebGpuHostControl _owner;

        public SurfaceCallback(AndroidWebGpuHostControl owner)
        {
            _owner = owner;
        }

        public void SurfaceChanged(ISurfaceHolder? holder, Format format, int width, int height)
        {
            _owner.OnSurfaceChanged(holder);
        }

        public void SurfaceCreated(ISurfaceHolder? holder)
        {
            _owner.OnSurfaceChanged(holder);
        }

        public void SurfaceDestroyed(ISurfaceHolder? holder)
        {
            _owner.OnSurfaceDestroyed();
        }
    }
}
