using System;
using System.Threading.Tasks;
using Avalonia;
using IMPLICIT_SCULPT_MODELER.Controls;
using Silk.NET.Core.Native;
using Silk.NET.WebGPU;

namespace IMPLICIT_SCULPT_MODELER.Rendering;

internal readonly record struct TriangleRenderResult(bool NeedsSurfaceRecreation, string? FatalMessage)
{
    public static TriangleRenderResult Success => new(false, null);
}

internal sealed class WebGpuTriangleRenderer : IDisposable
{
    private const string ShaderSource = """
        struct VertexOutput {
            @builtin(position) position: vec4f,
            @location(0) color: vec3f,
        };

        @vertex
        fn vs_main(@builtin(vertex_index) vertex_index: u32) -> VertexOutput {
            var positions = array<vec2f, 3>(
                vec2f(0.0, 0.72),
                vec2f(-0.72, -0.54),
                vec2f(0.72, -0.54)
            );

            var colors = array<vec3f, 3>(
                vec3f(1.0, 0.36, 0.22),
                vec3f(0.16, 0.76, 0.94),
                vec3f(0.98, 0.86, 0.32)
            );

            var output: VertexOutput;
            output.position = vec4f(positions[vertex_index], 0.0, 1.0);
            output.color = colors[vertex_index];
            return output;
        }

        @fragment
        fn fs_main(input: VertexOutput) -> @location(0) vec4f {
            return vec4f(input.color, 1.0);
        }
        """;

    private readonly WebGpuHostControl _host;
    private readonly WebGPU _api;

    private nint _instance;
    private nint _surface;
    private nint _adapter;
    private nint _device;
    private nint _queue;
    private nint _shaderModule;
    private nint _renderPipeline;
    private TextureFormat _surfaceFormat;
    private PixelSize _configuredSize;
    private bool _disposed;

    private WebGpuTriangleRenderer(WebGpuHostControl host, WebGPU api)
    {
        _host = host;
        _api = api;
    }

    public static async Task<WebGpuTriangleRenderer> CreateAsync(WebGpuHostControl host)
    {
        var renderer = new WebGpuTriangleRenderer(host, WebGPU.GetApi());
        await renderer.InitializeAsync();
        return renderer;
    }

    public void Resize(PixelSize size)
    {
        if (_disposed)
        {
            return;
        }

        if (size.Width < 1 || size.Height < 1)
        {
            return;
        }

        if (_configuredSize == size)
        {
            return;
        }

        ConfigureSurface(size);
    }

    public unsafe TriangleRenderResult Render(PixelSize size)
    {
        if (_disposed)
        {
            return new TriangleRenderResult(false, "The WebGPU renderer has already been disposed.");
        }

        if (size.Width < 1 || size.Height < 1)
        {
            return TriangleRenderResult.Success;
        }

        Resize(size);

        SurfaceTexture surfaceTexture = default;
        _api.SurfaceGetCurrentTexture((Surface*)_surface, &surfaceTexture);

        switch (surfaceTexture.Status)
        {
            case SurfaceGetCurrentTextureStatus.Success:
                break;
            case SurfaceGetCurrentTextureStatus.Timeout:
                ReleaseTexture(surfaceTexture.Texture);
                return TriangleRenderResult.Success;
            case SurfaceGetCurrentTextureStatus.Outdated:
            case SurfaceGetCurrentTextureStatus.Lost:
                ReleaseTexture(surfaceTexture.Texture);
                return new TriangleRenderResult(true, null);
            case SurfaceGetCurrentTextureStatus.OutOfMemory:
            case SurfaceGetCurrentTextureStatus.DeviceLost:
                ReleaseTexture(surfaceTexture.Texture);
                return new TriangleRenderResult(false, $"The surface reported {surfaceTexture.Status}.");
            default:
                ReleaseTexture(surfaceTexture.Texture);
                return new TriangleRenderResult(false, $"The surface reported an unexpected status: {surfaceTexture.Status}.");
        }

        if (surfaceTexture.Texture is null)
        {
            return new TriangleRenderResult(true, null);
        }

        var textureView = _api.TextureCreateView(surfaceTexture.Texture, (TextureViewDescriptor*)null);
        var commandEncoderDescriptor = new CommandEncoderDescriptor();
        var commandEncoder = _api.DeviceCreateCommandEncoder((Device*)_device, &commandEncoderDescriptor);

        var clearColor = new Silk.NET.WebGPU.Color(0.04d, 0.06d, 0.09d, 1d);
        var colorAttachment = new RenderPassColorAttachment
        {
            View = textureView,
            LoadOp = LoadOp.Clear,
            StoreOp = StoreOp.Store,
            ClearValue = clearColor
        };

        var renderPassDescriptor = new RenderPassDescriptor
        {
            ColorAttachmentCount = 1,
            ColorAttachments = &colorAttachment
        };

        var renderPass = _api.CommandEncoderBeginRenderPass(commandEncoder, &renderPassDescriptor);
        _api.RenderPassEncoderSetPipeline(renderPass, (RenderPipeline*)_renderPipeline);
        _api.RenderPassEncoderDraw(renderPass, 3, 1, 0, 0);
        _api.RenderPassEncoderEnd(renderPass);
        _api.RenderPassEncoderRelease(renderPass);

        var commandBufferDescriptor = new CommandBufferDescriptor();
        var commandBuffer = _api.CommandEncoderFinish(commandEncoder, &commandBufferDescriptor);
        _api.QueueSubmit((Queue*)_queue, 1, &commandBuffer);
        _api.SurfacePresent((Surface*)_surface);

        _api.CommandBufferRelease(commandBuffer);
        _api.CommandEncoderRelease(commandEncoder);
        _api.TextureViewRelease(textureView);
        _api.TextureRelease(surfaceTexture.Texture);

        if (surfaceTexture.Suboptimal)
        {
            ConfigureSurface(size);
        }

        return TriangleRenderResult.Success;
    }

    public unsafe void Dispose()
    {
        if (_disposed)
        {
            return;
        }

        _disposed = true;

        if (_surface != 0)
        {
            _api.SurfaceUnconfigure((Surface*)_surface);
        }

        if (_renderPipeline != 0)
        {
            _api.RenderPipelineRelease((RenderPipeline*)_renderPipeline);
        }

        if (_shaderModule != 0)
        {
            _api.ShaderModuleRelease((ShaderModule*)_shaderModule);
        }

        if (_queue != 0)
        {
            _api.QueueRelease((Queue*)_queue);
        }

        if (_device != 0)
        {
            _api.DeviceRelease((Device*)_device);
        }

        if (_adapter != 0)
        {
            _api.AdapterRelease((Adapter*)_adapter);
        }

        if (_surface != 0)
        {
            _api.SurfaceRelease((Surface*)_surface);
        }

        if (_instance != 0)
        {
            _api.InstanceRelease((Instance*)_instance);
        }

        _api.Dispose();
    }

    private async Task InitializeAsync()
    {
        _instance = CreateInstanceHandle();

        if (_instance == 0)
        {
            throw new InvalidOperationException("Silk.NET could not create a WebGPU instance.");
        }

        _surface = CreateSurfaceHandle();

        if (_surface == 0)
        {
            throw new InvalidOperationException("The platform host could not create a WebGPU surface.");
        }

        _adapter = await RequestAdapterAsync().ConfigureAwait(true);
        _device = await RequestDeviceAsync().ConfigureAwait(true);
        _queue = GetQueueHandle();
        _surfaceFormat = ChooseSurfaceFormat();
        _shaderModule = CreateShaderModule();
        _renderPipeline = CreateRenderPipeline();

        ConfigureSurface(_host.GetPixelSize());
    }

    private unsafe nint CreateInstanceHandle()
    {
        var instanceDescriptor = new InstanceDescriptor();
        return (nint)_api.CreateInstance(&instanceDescriptor);
    }

    private unsafe nint CreateSurfaceHandle()
    {
        return (nint)_host.CreateSurface(_api, (Instance*)_instance);
    }

    private unsafe nint GetQueueHandle()
    {
        return (nint)_api.DeviceGetQueue((Device*)_device);
    }

    private unsafe Task<nint> RequestAdapterAsync()
    {
        var tcs = new TaskCompletionSource<nint>(TaskCreationOptions.RunContinuationsAsynchronously);

        PfnRequestAdapterCallback callback = new((status, adapter, _, _) =>
        {
            if (status == RequestAdapterStatus.Success && adapter is not null)
            {
                tcs.TrySetResult((nint)adapter);
                return;
            }

            tcs.TrySetException(new InvalidOperationException($"WebGPU adapter request failed with status {status}."));
        });

        var options = new RequestAdapterOptions
        {
            CompatibleSurface = (Surface*)_surface,
            PowerPreference = PowerPreference.HighPerformance
        };

        _api.InstanceRequestAdapter((Instance*)_instance, &options, callback, null);
        return AwaitHandleAsync(tcs.Task, callback);
    }

    private unsafe Task<nint> RequestDeviceAsync()
    {
        var tcs = new TaskCompletionSource<nint>(TaskCreationOptions.RunContinuationsAsynchronously);

        PfnRequestDeviceCallback callback = new((status, device, _, _) =>
        {
            if (status == RequestDeviceStatus.Success && device is not null)
            {
                tcs.TrySetResult((nint)device);
                return;
            }

            tcs.TrySetException(new InvalidOperationException($"WebGPU device request failed with status {status}."));
        });

        var descriptor = new DeviceDescriptor
        {
            DefaultQueue = new QueueDescriptor()
        };

        _api.AdapterRequestDevice((Adapter*)_adapter, &descriptor, callback, null);
        return AwaitHandleAsync(tcs.Task, callback);
    }

    private static async Task<nint> AwaitHandleAsync(Task<nint> handleTask, object callbackHandle)
    {
        var handle = await handleTask.ConfigureAwait(true);
        GC.KeepAlive(callbackHandle);
        return handle;
    }

    private unsafe TextureFormat ChooseSurfaceFormat()
    {
        var preferred = _api.SurfaceGetPreferredFormat((Surface*)_surface, (Adapter*)_adapter);
        return preferred == TextureFormat.Undefined ? TextureFormat.Bgra8Unorm : preferred;
    }

    private unsafe nint CreateShaderModule()
    {
        var shaderSourcePointer = (byte*)SilkMarshal.StringToPtr(ShaderSource);

        try
        {
            var wgslDescriptor = new ShaderModuleWGSLDescriptor
            {
                Chain = new ChainedStruct
                {
                    SType = SType.ShaderModuleWgslDescriptor
                },
                Code = shaderSourcePointer
            };

            var shaderDescriptor = new ShaderModuleDescriptor
            {
                NextInChain = (ChainedStruct*)&wgslDescriptor
            };

            var shaderModule = _api.DeviceCreateShaderModule((Device*)_device, &shaderDescriptor);

            if (shaderModule is null)
            {
                throw new InvalidOperationException("WebGPU could not compile the inline WGSL shader.");
            }

            return (nint)shaderModule;
        }
        finally
        {
            SilkMarshal.Free((nint)shaderSourcePointer);
        }
    }

    private unsafe nint CreateRenderPipeline()
    {
        var vertexEntryPoint = (byte*)SilkMarshal.StringToPtr("vs_main");
        var fragmentEntryPoint = (byte*)SilkMarshal.StringToPtr("fs_main");

        try
        {
            var blendState = new BlendState
            {
                Color = new BlendComponent
                {
                    SrcFactor = BlendFactor.One,
                    DstFactor = BlendFactor.Zero,
                    Operation = BlendOperation.Add
                },
                Alpha = new BlendComponent
                {
                    SrcFactor = BlendFactor.One,
                    DstFactor = BlendFactor.Zero,
                    Operation = BlendOperation.Add
                }
            };

            var colorTargetState = new ColorTargetState
            {
                Format = _surfaceFormat,
                Blend = &blendState,
                WriteMask = ColorWriteMask.All
            };

            var fragmentState = new FragmentState
            {
                Module = (ShaderModule*)_shaderModule,
                EntryPoint = fragmentEntryPoint,
                TargetCount = 1,
                Targets = &colorTargetState
            };

            var renderPipelineDescriptor = new RenderPipelineDescriptor
            {
                Vertex = new VertexState
                {
                    Module = (ShaderModule*)_shaderModule,
                    EntryPoint = vertexEntryPoint
                },
                Primitive = new PrimitiveState
                {
                    Topology = PrimitiveTopology.TriangleList,
                    StripIndexFormat = IndexFormat.Undefined,
                    FrontFace = FrontFace.Ccw,
                    CullMode = CullMode.None
                },
                Multisample = new MultisampleState
                {
                    Count = 1,
                    Mask = uint.MaxValue
                },
                Fragment = &fragmentState
            };

            var renderPipeline = _api.DeviceCreateRenderPipeline((Device*)_device, &renderPipelineDescriptor);

            if (renderPipeline is null)
            {
                throw new InvalidOperationException("WebGPU could not create the triangle render pipeline.");
            }

            return (nint)renderPipeline;
        }
        finally
        {
            SilkMarshal.Free((nint)vertexEntryPoint);
            SilkMarshal.Free((nint)fragmentEntryPoint);
        }
    }

    private unsafe void ConfigureSurface(PixelSize size)
    {
        var clampedSize = new PixelSize(Math.Max(1, size.Width), Math.Max(1, size.Height));

        var configuration = new SurfaceConfiguration
        {
            Device = (Device*)_device,
            Format = _surfaceFormat,
            Usage = TextureUsage.RenderAttachment,
            Width = (uint)clampedSize.Width,
            Height = (uint)clampedSize.Height,
            PresentMode = PresentMode.Fifo,
            AlphaMode = CompositeAlphaMode.Auto
        };

        _api.SurfaceConfigure((Surface*)_surface, &configuration);
        _configuredSize = clampedSize;
    }

    private unsafe void ReleaseTexture(Texture* texture)
    {
        if (texture is not null)
        {
            _api.TextureRelease(texture);
        }
    }
}
