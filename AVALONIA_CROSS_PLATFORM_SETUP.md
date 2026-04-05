# Avalonia Cross-Platform Setup Notes

This is a practical reference for getting a fresh Avalonia cross-platform solution building on Windows with:

- Desktop
- Browser
- Android
- iOS

These notes are based on the exact steps used to get this repo building cleanly.

## Goal

End state:

```powershell
dotnet build IMPLICIT_SCULPT_MODELER.sln -v minimal
```

Expected result:

- Build succeeds
- Desktop builds
- Browser builds
- Android builds
- iOS builds

## 1. Start From The Fresh Template

These notes begin after generating the normal Avalonia cross-platform solution and opening it on Windows.

In this repo, the solution contains:

- `IMPLICIT_SCULPT_MODELER`
- `IMPLICIT_SCULPT_MODELER.Desktop`
- `IMPLICIT_SCULPT_MODELER.Browser`
- `IMPLICIT_SCULPT_MODELER.Android`
- `IMPLICIT_SCULPT_MODELER.iOS`

## 2. First Build To See Real Errors

Start by building the solution and then, if needed, individual heads:

```powershell
dotnet build IMPLICIT_SCULPT_MODELER.sln
dotnet build IMPLICIT_SCULPT_MODELER.Desktop\IMPLICIT_SCULPT_MODELER.Desktop.csproj -v normal
dotnet build IMPLICIT_SCULPT_MODELER.Browser\IMPLICIT_SCULPT_MODELER.Browser.csproj -v minimal
dotnet build IMPLICIT_SCULPT_MODELER.Android\IMPLICIT_SCULPT_MODELER.Android.csproj -v minimal
dotnet build IMPLICIT_SCULPT_MODELER.iOS\IMPLICIT_SCULPT_MODELER.iOS.csproj -v minimal
```

For this project, the initial blockers were:

- Avalonia build telemetry failing with access denied
- Missing .NET workloads
- Missing Android SDK / JDK
- Browser solution-build task host failure on .NET 10

## 3. Fix Avalonia Telemetry Build Failure

The first real failure was Avalonia's build telemetry task trying to write here:

```text
C:\Users\Emmanuel\AppData\Local\AvaloniaUI\BuildServices\buildtasks.log
```

The fix was to override the `AvaloniaStats` target in the repo.

Create `Directory.Build.targets` in the solution root:

```xml
<Project>
  <Target Name="AvaloniaStats" />
</Project>
```

In this repo that file is:

- `Directory.Build.targets`

Why:

- It keeps the build self-contained
- It avoids machine-specific failures in locked-down environments

## 4. Install Required .NET Workloads

The fresh template did not have all workloads available on the machine.

First run:

```powershell
dotnet workload restore IMPLICIT_SCULPT_MODELER.sln
```

That brought in the mobile workloads needed by the solution.

Then install the WebAssembly tooling explicitly:

```powershell
dotnet workload install wasm-tools
```

Why:

- Browser build on .NET 10 needed the WebAssembly toolchain
- Without it, browser build tasks like `ComputeWasmBuildAssets` failed

## 5. Install Android SDK And JDK

Installing the `android` workload is not enough by itself. The Android project also needs:

- Android SDK
- Java SDK / JDK

The quickest route used here was the Android dependency target:

```powershell
dotnet build IMPLICIT_SCULPT_MODELER.Android\IMPLICIT_SCULPT_MODELER.Android.csproj `
  -t:InstallAndroidDependencies `
  -f net10.0-android `
  "-p:AndroidSdkDirectory=C:\Users\Emmanuel\android-sdk" `
  "-p:JavaSdkDirectory=C:\Users\Emmanuel\jdk" `
  -p:AcceptAndroidSdkLicenses=True
```

After that, verify Android using explicit paths:

```powershell
dotnet build IMPLICIT_SCULPT_MODELER.Android\IMPLICIT_SCULPT_MODELER.Android.csproj -v minimal `
  "-p:AndroidSdkDirectory=C:\Users\Emmanuel\android-sdk" `
  "-p:JavaSdkDirectory=C:\Users\Emmanuel\jdk"
```

Notes:

- In this repo the install target laid down the SDK/JDK under `C:\Users\Emmanuel\android-sdk` and `C:\Users\Emmanuel\jdk`
- The target emitted warnings during installation, but the folders were created and the subsequent Android build succeeded

## 6. Save Android And Java Environment Variables

To make future builds simpler, persist the paths:

```powershell
setx ANDROID_HOME C:\Users\Emmanuel\android-sdk
setx ANDROID_SDK_ROOT C:\Users\Emmanuel\android-sdk
setx JAVA_HOME C:\Users\Emmanuel\jdk
```

After setting them:

- reopen terminals
- restart the IDE if needed

## 7. Add Repo Fallbacks For Android SDK / JDK

To avoid relying only on machine state, add `Directory.Build.props` in the solution root.

This repo uses:

```xml
<Project>
  <PropertyGroup Condition="'$(OS)' == 'Windows_NT'">
    <_DefaultAndroidSdkDirectory>$(USERPROFILE)\android-sdk</_DefaultAndroidSdkDirectory>
    <_DefaultJavaSdkDirectory>$(USERPROFILE)\jdk</_DefaultJavaSdkDirectory>

    <AndroidSdkDirectory Condition="'$(AndroidSdkDirectory)' == '' and '$(ANDROID_SDK_ROOT)' != ''">$(ANDROID_SDK_ROOT)</AndroidSdkDirectory>
    <AndroidSdkDirectory Condition="'$(AndroidSdkDirectory)' == '' and '$(ANDROID_HOME)' != ''">$(ANDROID_HOME)</AndroidSdkDirectory>
    <AndroidSdkDirectory Condition="'$(AndroidSdkDirectory)' == '' and Exists('$(_DefaultAndroidSdkDirectory)')">$(_DefaultAndroidSdkDirectory)</AndroidSdkDirectory>

    <JavaSdkDirectory Condition="'$(JavaSdkDirectory)' == '' and '$(JAVA_HOME)' != ''">$(JAVA_HOME)</JavaSdkDirectory>
    <JavaSdkDirectory Condition="'$(JavaSdkDirectory)' == '' and Exists('$(_DefaultJavaSdkDirectory)')">$(_DefaultJavaSdkDirectory)</JavaSdkDirectory>
  </PropertyGroup>
</Project>
```

Why:

- lets the project build from normal terminals
- gives a fallback even if the environment variables are missing in one shell session

## 8. Fix Browser Failure During Solution Builds

Important finding:

- `IMPLICIT_SCULPT_MODELER.Browser.csproj` built fine by itself
- the full `.sln` build failed with WebAssembly task-host errors during solution builds

The solution build error was in tasks like:

- `ComputeWasmBuildAssets`
- `MarshalingPInvokeScanner`
- `MSB4216`

The practical workaround here was to force the browser head to build after the other app heads in the solution.

Edit the browser project entry in the `.sln` and add project dependencies:

```text
Project("{9A19103F-16F7-4668-BE54-9A1E7A4F7556}") = "IMPLICIT_SCULPT_MODELER.Browser", "IMPLICIT_SCULPT_MODELER.Browser\IMPLICIT_SCULPT_MODELER.Browser.csproj", "{1C1A049E-235C-4CD0-B6FA-D53AC418F4DA}"
    ProjectSection(ProjectDependencies) = postProject
        {7AD1DAC8-7FBE-49D5-8614-7321233DB82E} = {7AD1DAC8-7FBE-49D5-8614-7321233DB82E}
        {ABC31E74-02FF-46EB-B3B2-4E6AE43B456C} = {ABC31E74-02FF-46EB-B3B2-4E6AE43B456C}
        {EBD9022F-BC83-4846-9A11-6F7F3772DC64} = {EBD9022F-BC83-4846-9A11-6F7F3772DC64}
    EndProjectSection
EndProject
```

In plain English:

- Browser waits for Android
- Browser waits for Desktop
- Browser waits for iOS

Why this was needed:

- solution-level parallelism was tripping the WebAssembly task host in this environment
- changing build order fixed the normal `dotnet build <solution>` path without changing app code

If future .NET SDK updates fix this, you may be able to remove this workaround.

## 9. Final Verification

After all fixes:

```powershell
dotnet build IMPLICIT_SCULPT_MODELER.sln -v minimal
```

This repo ended in:

- 0 warnings
- 0 errors

## 10. Files Added Or Changed For Build Stability

Repo-level files added:

- `Directory.Build.targets`
- `Directory.Build.props`

Repo-level file changed:

- `IMPLICIT_SCULPT_MODELER.sln`

Machine-level setup done:

- installed `android` workload
- installed `ios` workload
- installed `wasm-tools` workload
- installed Android SDK to `C:\Users\Emmanuel\android-sdk`
- installed JDK to `C:\Users\Emmanuel\jdk`
- set `ANDROID_HOME`
- set `ANDROID_SDK_ROOT`
- set `JAVA_HOME`

## 11. Quick Checklist For The Next Avalonia Cross-Platform App

1. Generate the fresh Avalonia cross-platform solution.
2. Run a full solution build immediately.
3. Add `Directory.Build.targets` with the empty `AvaloniaStats` target if Avalonia telemetry fails.
4. Run `dotnet workload restore <solution>.sln`.
5. Run `dotnet workload install wasm-tools`.
6. Install Android SDK and JDK if Android build complains they are missing.
7. Set `ANDROID_HOME`, `ANDROID_SDK_ROOT`, and `JAVA_HOME`.
8. Add `Directory.Build.props` fallback wiring for SDK/JDK paths.
9. If Browser builds alone but the solution build fails with WebAssembly task-host errors, add `.sln` project dependencies so Browser builds after the other heads.
10. Re-run `dotnet build <solution>.sln -v minimal` until the whole solution is green.

## 12. Recommended Reuse For New Projects

For your next new Avalonia cross-platform repo on this same machine, I would copy these two files in right away:

- `Directory.Build.targets`
- `Directory.Build.props`

Then if the same browser solution-build issue appears again, apply the same `.sln` dependency ordering workaround.
