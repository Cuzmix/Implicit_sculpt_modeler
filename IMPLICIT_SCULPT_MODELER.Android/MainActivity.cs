using Android.App;
using Android.Content.PM;
using Avalonia;
using Avalonia.Android;

namespace IMPLICIT_SCULPT_MODELER.Android;

[Activity(
    Label = "IMPLICIT_SCULPT_MODELER.Android",
    Theme = "@style/MyTheme.NoActionBar",
    Icon = "@drawable/icon",
    MainLauncher = true,
    ConfigurationChanges = ConfigChanges.Orientation | ConfigChanges.ScreenSize | ConfigChanges.UiMode)]
public class MainActivity : AvaloniaMainActivity<App>
{
    protected override AppBuilder CustomizeAppBuilder(AppBuilder builder)
    {
        return base.CustomizeAppBuilder(builder)
            .WithInterFont();
    }
}