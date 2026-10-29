---
name: sm-store
description: The rules the whole app must keep to ship on the Apple App Store (iPad, later Mac) and Google Play (Android tablets), plus signed Windows and Linux releases — screen insets and touch target sizes, back gesture, files and storage, permissions, privacy and data, network and downloaded code, payments, crashes and hangs, native library build settings (arm64, 16 KB pages, SDK levels), third-party licences, accessibility. Load for ANY task that adds a dependency, permission, file or folder access, network call, saved data, telemetry, account, purchase, platform build or packaging step, new screen or control, or touches startup, shutdown or app lifecycle, e.g. "add an export to Photos", "add crash reporting", "add a cloud save", "build an APK", "add a font", "add a pro version", "open files from the tablet". Requires sm-build; what the controls look like is sm-ui.
---

# Store rules

The app is meant to ship on Google Play (Android tablets) now and the App Store (iPad, later Mac) later, plus downloads
for Windows and Linux. Store review rejects a build for any rule below, so every change keeps to all of them from day
one, on every platform, even before a store build exists. Dates are the stores' published deadlines as of 2026-10;
re-check the stores' pages before a first submission, because they move every year.

## Screens and controls (both stores)
- Content and controls stay inside the safe area: Android is edge-to-edge (forced when targeting API 35+), iPad has
  rounded corners, the home indicator and Stage Manager windows. Read the insets each frame from SDL
  (`SDL_GetWindowSafeArea`) and lay panels out inside them; the viewport may draw under them.
- Touch targets are at least 44 x 44 points (Apple) and 48 x 48 dp (Android): use 48 everywhere. There is one
  layout for every OS and device (Bolt, 2026-10-25): desktop uses the same touch-sized layout as the tablet, scaled
  by the display's DPI, never a denser mouse-only variant.
- Every window size works: iPad split view and Stage Manager, Android multi-window, free-form windows and rotation.
  Never assume full screen or one orientation; nothing is cut off or overlaps at the smallest size.
- Android back (gesture or button) closes the topmost sheet, menu or dialog first and only then leaves the app, and it
  never discards unsaved work without asking (predictive back: handle it, do not block it).
- Text stays readable: 4.5:1 contrast for body text, sizes from the theme, no text baked into images.
- Follow the system dark or light setting once a light theme exists; until then dark only is allowed.
- Accessibility is not a review gate today but the custom UI must be able to expose every control's name, role and
  value to VoiceOver and TalkBack later: every widget keeps a stable id and a text label, even icon-only ones.

## App lifecycle and quality
- No crash, hang or blank screen in review: a build that crashes on launch or on the reviewer's first action is
  rejected. Damaged files are refused with a message, never asserted on (already a hard rule).
- Play flags apps above 1.09% user-perceived crash rate or 0.47% ANR rate (8% on any one device model) and hides
  them. The main thread never blocks for seconds: long work (remesh, slice, file reads of big meshes) runs on jobs
  with progress, and the frame loop keeps presenting.
- Going to the background (SDL `EVENT_WILL_ENTER_BACKGROUND` / `DID_ENTER_BACKGROUND`) saves recoverable state and
  stops GPU submission; the OS may kill the app there without warning. Coming back restores the scene. Today
  `DID_ENTER_BACKGROUND` starts an autosave at once (`app.autosave.background`, `src/app/autosave.odin`), and on mobile
  every session not closed is offered back at the next start, since a kill there looks like a crash.
- UNVERIFIED until the iPad build: iOS gives a backgrounded app only seconds unless it asks for more
  (`beginBackgroundTask`), so a big scene's autosave may be cut short there (the copy before it stays whole); and
  `SDL_GetPrefPath` on iOS is backed up to iCloud, so the `autosave` folder needs `NSURLIsExcludedFromBackupKey` (or
  to live under Caches) before a store build, or hundreds of MB of copies go to the user's iCloud.
- Saving over a scene keeps earlier saves in a "<stem> versions" folder beside the file (`src/app/versions.odin`).
  Once Android and iPad save through the system picker, that folder is outside what the app may write: there the
  versions must go to the app's own folder (or the picked folder's tree, if the user granted one), never ask for
  broader storage access to keep them.
- Apple 4.2 / 2.1: the build is complete, nothing says "coming soon", no placeholder screens, no debug panels
  reachable by users (the Stats panel, F11 and Menu > Stats, is to be a developer flag only in store builds).

## Files, storage and data
- No access outside the app's own folders except through the system file picker (Storage Access Framework on
  Android, `UIDocumentPicker` on iPad; `content://` URIs open through `SDL_IOFromFile`). Never request
  `MANAGE_EXTERNAL_STORAGE` or broad storage permissions.
- Ask only for permissions a visible feature needs, at the moment it is used; each iOS permission needs its usage
  string in Info.plist. Today the app needs none.
- No data leaves the device. Adding analytics, crash reporting, accounts or cloud saves first needs: a privacy
  policy URL, Play's Data safety form and Apple's privacy labels updated, consent where the law needs it, and (Apple)
  account deletion inside the app if accounts exist.
- Apple privacy manifest (`PrivacyInfo.xcprivacy`) lists every "required reason" API the binary and its libraries
  call (file timestamps, system boot time, disk space, user defaults); SDL and our code must be checked when the iPad
  build is made. Home says when a scene was saved from the time its preview block stores, not the file's timestamp,
  to stay off that list.
- Home's Recent keeps paths across runs (`recent_scenes`). UNVERIFIED on the tablets: a `content://` URI the picker
  gave is readable in a later run only if the grant was persisted (`takePersistableUriPermission`; iPad needs a
  security-scoped bookmark); until then such a scene shows as gone on Home after a restart rather than failing.

## Code and network
- No downloading or running code after review (Apple 2.5.2; Play device and network abuse policy): brushes, alphas,
  materials and scenes are data files, never scripts or plug-ins loaded at runtime. The one exception is script
  plugins (Luau, `src/app/plugins.odin`), which exist only in the Windows and Linux desktop builds
  (`luau.AVAILABLE` is false for Android and any iPad build, so no Luau is linked there), run sandboxed (no files,
  network or processes; memory and step budgets) and are never fetched by the app: no plugin store or download.
  Bringing them to a tablet needs its own design against 2.5.2 (at most scripts the person writes in the app).
- Encryption: the app uses none beyond the OS's HTTPS, so iOS builds set `ITSAppUsesNonExemptEncryption` to false.

## Payments
- Anything unlocked in the app (a pro version, brush packs) goes through Apple In-App Purchase and Google Play
  Billing; no links or buttons to pay elsewhere unless that store's current rules allow it in that country.

## Builds and packaging
- Google Play: Android App Bundle (`.aab`), arm64-v8a included (64-bit required), target API 36 (Android 16) for
  new apps and updates from 2026-08-31, native libraries linked for 16 KB pages
  (`-Wl,-z,max-page-size=16384`, required for apps targeting Android 15+), signed with Play App Signing. The
  Gradle project is `android/` (`android/app/build.gradle` holds the SDK levels and `app/jni/CMakeLists.txt` the
  link flags); the manifest declares no permissions, and one added there needs a visible feature that uses it.
- App Store: built with Xcode 26 and the iOS 26 SDK (required since 2026-04-28), deployment target iOS 13 or newer
  (minimum from 2026-09-09), arm64 only, launch screen storyboard, full app icon set, iPad multitasking supported.
- Windows: sign the executable and installer (Authenticode) or SmartScreen warns every user. Linux: ship as a
  Flatpak or AppImage with the libraries it needs.
- Store builds are release builds: no tracking allocator exit codes, no GPU validation, no debug flags exposed.

## Licences
- Every third-party piece we ship keeps its licence text and appears in an About > Licences screen: SDL3 (zlib),
  Inter (OFL 1.1, its licence beside the font files), Lucide (ISC), stb (public domain or MIT),
  kb_text_shape, Luau (MIT, with Lua's MIT notice; its texts in the repository's assets/licenses folder, desktop builds only; Luau asks for "Luau"
  in user-facing docs), Stephen Hill's ACES fit (MIT, assets/licenses/ACES-fit-LICENSE.txt; finish.frag.slang), ufbx (MIT or public domain,
  assets/licenses/ufbx-LICENSE.txt; FBX import on every platform) and anything
  added later. A new dependency is added there in the same change.

## Before calling a change done
- Name in your report which of the sections above the change touches and how it keeps to them, or say "no store
  impact". A change that breaks a rule is either fixed or designed and raised with the user, never left silent.
