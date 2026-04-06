using System;
using Avalonia;
using IMPLICIT_SCULPT_MODELER.Desktop.Platform;
using IMPLICIT_SCULPT_MODELER.Platform;

namespace IMPLICIT_SCULPT_MODELER.Desktop;

sealed class Program
{
    [STAThread]
    public static void Main(string[] args)
    {
        TrianglePlatform.Configure(new DesktopTrianglePlatformFactory());
        BuildAvaloniaApp().StartWithClassicDesktopLifetime(args);
    }

    public static AppBuilder BuildAvaloniaApp()
        => AppBuilder.Configure<App>()
            .UsePlatformDetect()
            .WithInterFont()
            .LogToTrace();
}
