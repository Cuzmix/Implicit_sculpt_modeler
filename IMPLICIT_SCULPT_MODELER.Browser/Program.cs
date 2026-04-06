using System.Threading.Tasks;
using Avalonia;
using Avalonia.Browser;
using IMPLICIT_SCULPT_MODELER;
using IMPLICIT_SCULPT_MODELER.Browser.Platform;
using IMPLICIT_SCULPT_MODELER.Platform;

internal sealed partial class Program
{
    private static Task Main(string[] args)
    {
        TrianglePlatform.Configure(new BrowserTrianglePlatformFactory());
        return BuildAvaloniaApp()
            .WithInterFont()
            .StartBrowserAppAsync("out");
    }

    public static AppBuilder BuildAvaloniaApp()
        => AppBuilder.Configure<App>();
}
