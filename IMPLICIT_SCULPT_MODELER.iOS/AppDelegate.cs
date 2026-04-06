using Foundation;
using UIKit;
using Avalonia;
using Avalonia.Controls;
using Avalonia.iOS;
using Avalonia.Media;
using IMPLICIT_SCULPT_MODELER.Platform;
using IMPLICIT_SCULPT_MODELER.iOS.Platform;

namespace IMPLICIT_SCULPT_MODELER.iOS;

[Register("AppDelegate")]
#pragma warning disable CA1711
public partial class AppDelegate : AvaloniaAppDelegate<App>
#pragma warning restore CA1711
{
    protected override AppBuilder CustomizeAppBuilder(AppBuilder builder)
    {
        TrianglePlatform.Configure(new IosTrianglePlatformFactory());
        return base.CustomizeAppBuilder(builder)
            .WithInterFont();
    }
}
