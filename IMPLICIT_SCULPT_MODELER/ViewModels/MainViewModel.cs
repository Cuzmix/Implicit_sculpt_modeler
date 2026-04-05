using CommunityToolkit.Mvvm.ComponentModel;

namespace IMPLICIT_SCULPT_MODELER.ViewModels;

public partial class MainViewModel : ViewModelBase
{
    [ObservableProperty] private string _greeting = "Welcome to Avalonia!";
}