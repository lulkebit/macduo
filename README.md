# MacDuo

A small macOS menu bar app that makes your desktop appear to stay in place as you fold your MacBook display.

MacDuo takes one screenshot at the start of a fold and adjusts its perspective using the real lid angle. From a calibrated viewing position, the image appears anchored behind the moving display. Adjustable softness adds a subtle glass effect.

**Experimental:** the effect requires an accessible MacBook lid-angle sensor. Hardware support varies, and the sensor's report format is undocumented. The interactive preview works without screen recording permission or a supported sensor.

## Requirements

- macOS 14 or later.
- A MacBook with an active built-in display, a Metal-capable GPU, and a supported lid-angle sensor.
- Screen recording permission for the desktop effect.
- Xcode Command Line Tools with Swift 5.9 or later to build from source.

## Build and run

```sh
git clone https://github.com/lulkebit/macduo.git
cd macduo
./scripts/build-app.sh
ditto dist/MacDuo.app /Applications/MacDuo.app
open /Applications/MacDuo.app
```

The script creates a release build and signs it with a persistent local development identity in your default keychain. Its private key stays in Keychain. Future builds reuse the same identity so their code-signing requirement remains stable. There are no external package dependencies.

Quit MacDuo before replacing an installed copy. Use the same installed app for screen recording permission and launch at login. If you cannot write to `/Applications`, use `~/Applications` instead.

## Use

1. Set **Open angle** to your normal working position; the default is 100°.
2. Turn on **Effect**. Enabling it only arms the effect; it does not capture your screen.
3. Lower the lid at least 2° below the open angle. Once sufficient movement is detected, MacDuo captures one image and projects it throughout the fold.
4. Open the lid back to the configured angle to return to your live desktop and discard the image.

Enable **Launch at login** to start MacDuo quietly in the menu bar when you sign in. The app restores your last **Effect** setting; startup itself never takes a screenshot. Login-item status follows System Settings, including changes made there.

Closing the settings window leaves MacDuo in the menu bar. Press **⌃⌥⌘D** (Control–Option–Command–D) to toggle the effect from any app. The overlay passes clicks through; apps continue running underneath the frozen image.

In **Preview**, switch between **Observer** (the view from the virtual eye) and **Display** (the image drawn on the physical screen). Drag the angle slider or enable **Follow lid** to inspect the effect.

Use **Calibration** to adjust eye height and distance. Keep your head still and set **Softness** to zero while tuning the geometry. MacDuo does not use a camera or track your eyes, so the illusion depends on your viewing position.

## Screen access and privacy

Screen images stay in memory. MacDuo does not save them, transmit them, capture audio, or use a recording stream. A fold reuses the same image even when movement stops or reverses. Pausing, locking, sleeping, losing the sensor, or changing displays discards it.

macOS requires screen recording permission even for a single screenshot and controls any capture indicators. Use **Screen access → Test capture** to take and immediately discard a test image. This also arms the effect. If access is denied, select **Open Settings**, allow MacDuo, and return to the app. After a denied request, automatic captures stay blocked, including across restarts, until **Retry access** succeeds. Returning from System Settings or moving the lid does not trigger another permission request.

When upgrading from an older ad hoc build, macOS may retain an allowed entry for the old code signature. Quit MacDuo, remove that old entry from Screen Recording in System Settings, and add the newly installed MacDuo.app. Then reopen it and choose **Retry access**. This refresh is needed when the signing identity changes; the new default build process reuses its identity. MacDuo never changes macOS privacy permissions itself.

## Limitations

- The effect uses a frozen image; it does not show live changes during a fold.
- Only the built-in display is affected. Protected content may be omitted by macOS.
- The display remains opaque. At shallow viewing angles, the projection fades to a matte to avoid extreme distortion.
- MacDuo preserves normal sleep behavior and runs outside the App Sandbox.
- The build script does not notarize the app; source builds are intended for local use.

## Development

Built with Swift, SwiftUI, AppKit, ScreenCaptureKit, and Core Image on Metal.

```sh
swift test
dist/MacDuo.app/Contents/MacOS/MacDuo --diagnose
open dist/MacDuo.app --args --background
```

`--diagnose` briefly reads the sensor without taking a screenshot. `--background` launches with the settings window hidden. Tests cover capture gating, permission recovery, suspension handling, image boundaries, and perspective geometry against independent ray/plane calculations.

Set `MACDUO_SIGNING_IDENTITY` when running the build script to use an existing Apple signing identity. The default self-signed certificate is for local development; public binary distribution still requires Developer ID signing and notarization. Explicitly setting `MACDUO_SIGNING_IDENTITY=-` opts into ad hoc signing, which does not retain a stable identity across changed builds. See Apple’s [code-signing requirements](https://developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements).

See [projection design and API references](docs/reference.md) and [sensor notes](docs/sensor-notes.md). For hardware reports, include the Mac model, macOS version, and diagnostic output. Contributions and focused bug reports are welcome.

## Credits and license

Lid-angle sensor research by [Sam Henri Gold](https://github.com/samhenrigold/LidAngleSensor).

MacDuo is available under the [MIT License](LICENSE). Copyright © 2026 Luke Schröter.
