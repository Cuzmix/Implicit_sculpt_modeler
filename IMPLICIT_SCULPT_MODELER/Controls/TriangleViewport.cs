using System;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Layout;
using Avalonia.Media;
using IMPLICIT_SCULPT_MODELER.Platform;
using IMPLICIT_SCULPT_MODELER.Rendering;

namespace IMPLICIT_SCULPT_MODELER.Controls;

public sealed class TriangleViewport : UserControl
{
    private readonly Grid _root;
    private readonly Border _fallbackPanel;
    private readonly TextBlock _fallbackTitle;
    private readonly TextBlock _fallbackDetails;

    private WebGpuHostControl? _host;
    private WebGpuTriangleRenderer? _renderer;
    private TopLevel? _topLevel;
    private int _frameGeneration;
    private bool _isRestarting;

    public TriangleViewport()
    {
        HorizontalAlignment = HorizontalAlignment.Stretch;
        VerticalAlignment = VerticalAlignment.Stretch;

        _fallbackTitle = new TextBlock
        {
            FontSize = 24,
            FontWeight = FontWeight.SemiBold,
            HorizontalAlignment = HorizontalAlignment.Center,
            TextAlignment = TextAlignment.Center,
            Foreground = Brushes.White
        };

        _fallbackDetails = new TextBlock
        {
            FontSize = 14,
            MaxWidth = 520,
            HorizontalAlignment = HorizontalAlignment.Center,
            TextAlignment = TextAlignment.Center,
            Foreground = new SolidColorBrush(Color.FromRgb(185, 193, 206)),
            TextWrapping = TextWrapping.Wrap
        };

        _fallbackPanel = new Border
        {
            Background = new SolidColorBrush(Color.FromRgb(10, 13, 18)),
            Padding = new Thickness(32),
            Child = new StackPanel
            {
                HorizontalAlignment = HorizontalAlignment.Center,
                VerticalAlignment = VerticalAlignment.Center,
                Spacing = 12,
                Children =
                {
                    _fallbackTitle,
                    _fallbackDetails
                }
            }
        };

        _root = new Grid
        {
            Background = new SolidColorBrush(Color.FromRgb(10, 13, 18))
        };

        _root.Children.Add(_fallbackPanel);
        Content = _root;

        AttachedToVisualTree += OnAttachedToVisualTree;
        DetachedFromVisualTree += OnDetachedFromVisualTree;

        ShowFallback("Preparing WebGPU", "The native render surface is being created.");
    }

    private void OnAttachedToVisualTree(object? sender, VisualTreeAttachmentEventArgs e)
    {
        _topLevel = TopLevel.GetTopLevel(this);
        if (_topLevel is not null)
        {
            _topLevel.ScalingChanged += OnTopLevelScalingChanged;
        }

        EnsureHost();
        RestartRenderer();
    }

    private void OnDetachedFromVisualTree(object? sender, VisualTreeAttachmentEventArgs e)
    {
        if (_topLevel is not null)
        {
            _topLevel.ScalingChanged -= OnTopLevelScalingChanged;
            _topLevel = null;
        }

        StopRenderer();
    }

    private void OnHostSurfaceChanged(object? sender, EventArgs e)
    {
        if (_host?.IsReady == true)
        {
            RestartRenderer();
            return;
        }

        StopRenderer();
        ShowFallback("Waiting For A Native Surface", "The platform host is still creating the render target.");
    }

    private void OnTopLevelScalingChanged(object? sender, EventArgs e)
    {
        _renderer?.Resize(_host?.GetPixelSize() ?? default);
    }

    private void EnsureHost()
    {
        if (_host is not null)
        {
            return;
        }

        if (!TrianglePlatform.TryCreateHost(out var host, out var unsupportedReason))
        {
            ShowFallback("WebGPU Host Unavailable", unsupportedReason ?? "This platform head does not expose a native WebGPU host yet.");
            return;
        }

        _host = host;
        _host.HorizontalAlignment = HorizontalAlignment.Stretch;
        _host.VerticalAlignment = VerticalAlignment.Stretch;
        _host.SurfaceChanged += OnHostSurfaceChanged;

        _root.Children.Insert(0, _host);
    }

    private async void RestartRenderer()
    {
        if (_isRestarting)
        {
            return;
        }

        _isRestarting = true;

        try
        {
            StopRenderer();
            EnsureHost();

            if (_host is null)
            {
                return;
            }

            if (!_host.IsReady)
            {
                ShowFallback("Waiting For A Native Surface", "The platform host is still creating the render target.");
                return;
            }

            ShowFallback("Starting WebGPU", "Requesting the adapter, device, and swap chain.");

            try
            {
                _renderer = await WebGpuTriangleRenderer.CreateAsync(_host);
            }
            catch (Exception ex)
            {
                ShowFallback("WebGPU Unavailable", ex.Message);
                return;
            }

            ShowHost();
            ScheduleNextFrame(_frameGeneration);
        }
        finally
        {
            _isRestarting = false;
        }
    }

    private void ScheduleNextFrame(int generation)
    {
        _topLevel?.RequestAnimationFrame(_ =>
        {
            if (generation != _frameGeneration || _renderer is null || _host is null || _topLevel is null)
            {
                return;
            }

            if (!_host.IsReady)
            {
                RestartRenderer();
                return;
            }

            TriangleRenderResult result;

            try
            {
                result = _renderer.Render(_host.GetPixelSize());
            }
            catch (Exception ex)
            {
                ShowFallback("WebGPU Rendering Failed", ex.Message);
                StopRenderer();
                return;
            }

            if (result.FatalMessage is not null)
            {
                ShowFallback("WebGPU Rendering Failed", result.FatalMessage);
                StopRenderer();
                return;
            }

            if (result.NeedsSurfaceRecreation)
            {
                RestartRenderer();
                return;
            }

            ScheduleNextFrame(generation);
        });
    }

    private void StopRenderer()
    {
        _frameGeneration++;
        _renderer?.Dispose();
        _renderer = null;
    }

    private void ShowFallback(string title, string details)
    {
        _fallbackTitle.Text = title;
        _fallbackDetails.Text = details;
        _fallbackPanel.IsVisible = true;

        if (_host is not null)
        {
            _host.IsVisible = false;
        }
    }

    private void ShowHost()
    {
        _fallbackPanel.IsVisible = false;

        if (_host is not null)
        {
            _host.IsVisible = true;
        }
    }
}
