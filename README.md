<div align="center">

# Mac Duo

**Wish you could bring the iPhone Duo effect to your MacBook?**

https://github.com/user-attachments/assets/3ea3b098-c6d2-4398-8f3a-e9087bbb33f2

Close the lid and watch your screen content tilt, blur, and fade as it moves.  
Mac Duo adds this effect to your MacBook, with controls in the menu bar.

**Available in:** English and Simplified Chinese (简体中文).

<img src="./assets/menu.png" width="400" alt="Mac Duo menu">

</div>

<hr>

## About this fork

A fork of [sumimakito/Mac-Duo](https://github.com/sumimakito/Mac-Duo) carrying fixes for
reported issues, plus a benchmark for the effect's GPU cost. Upstream is the original; this
tracks it and adds:

| Change | Upstream issue |
|---|---|
| Simplified Chinese resolves in released builds, not only in local ones | [#21](https://github.com/sumimakito/Mac-Duo/issues/21), [#23](https://github.com/sumimakito/Mac-Duo/issues/23) |
| Blit mipmaps stand in when the MPS Gaussian pyramid refuses to encode | [#5](https://github.com/sumimakito/Mac-Duo/issues/5), [#10](https://github.com/sumimakito/Mac-Duo/issues/10) |
| `build.sh --run` no longer terminates an installed copy of the app | [#24](https://github.com/sumimakito/Mac-Duo/issues/24) |
| An application icon, drawn by a script that can regenerate it | [#20](https://github.com/sumimakito/Mac-Duo/issues/20) |
| `depthbench`, a probe for the effect's per-frame GPU cost | — |

### The Chinese localization

SwiftPM writes the localization as `zh-hans.lproj` for a plain `swift build` and `zh-Hans.lproj`
for a universal one. `Bundle` matches resource names case-sensitively even on a case-insensitive
filesystem, so a lookup under a fixed casing found the directory in a development build and
nothing in the shipped app, which then fell back to English. The fix takes the spelling from
`Bundle.localizations`. That split is also why the fault appears only in downloaded builds.

### Measurements

`swift build -c release --product depthbench && .build/release/depthbench` runs the live path's
own work off screen at the built-in display's real size. On an M5 Pro at 3024×1964, padded
picture 3504×2444, 12 pyramid levels, 300 frames:

| Stage | p50 | p95 |
|---|---|---|
| Copy the frame in and rebuild the pyramid | 0.330 ms | 0.335 ms |
| Full screen shader pass | 0.078 ms | 0.078 ms |
| **Per frame** | **0.408 ms** | **0.413 ms** |
| Build one still picture (once per effect) | 4.4 ms | — |

The frame budget at 120 Hz is 8.3 ms, so the whole GPU path costs about 5% of it. Two
optimisations were measured and dropped as a result: trimming the 120 pt black margin, worth at
most 0.2 ms of that 0.41 ms, and filling only the margin instead of the whole buffer before
drawing the screenshot, whose measured effect changed sign across repeated runs. On Apple
Silicon this effect is not compute-bound.

<hr>

With the default settings, it's recommended to view the effect in front of your MacBook.

- **Metal rendering:** Uses GPU rendering to apply perspective, blur, and dimming as the lid closes.
- **Live screen content:** Uses ScreenCaptureKit to capture and render screen content in real time.
- **Adjustable perspective:** Tweak the perspective to suit your viewing position and make the effect look more natural.


> [!NOTE]
> Mac Duo is completely **free** to use. Whether you use the app or reuse its code in your projects, please consider [sponsoring me](https://github.com/sponsors/sumimakito) if you find it helpful.
>
> Special thanks to our team at [Moeru AI](https://github.com/moeru-ai) for sponsoring the Apple Developer Program membership used to sign and notarize the prebuilt app here.

## Download

[Download DMG](https://github.com/sumimakito/Mac-Duo/releases/download/dev/Mac-Duo-dev.dmg) | [Download ZIP](https://github.com/sumimakito/Mac-Duo/releases/download/dev/Mac-Duo-dev.zip)

These downloads contain the latest [development build](https://github.com/sumimakito/Mac-Duo/releases/tag/dev) for Apple Silicon and Intel Macs.

Requires macOS 14 or later and a MacBook with a compatible lid angle sensor.
Grant Screen Recording permission when prompted to enable the effect.

## Build

Requires Xcode with Swift 6.0 or later. Run from the project directory:

```sh
./build.sh
```

The script creates `build/Mac Duo.app` with an ad-hoc signature. Open it from Finder, or build and launch with:

```sh
./build.sh --run
```

macOS may require Screen Recording permission again after rebuilding with ad-hoc signing.

## Known limitations

- Only MacBooks with a compatible lid angle sensor can use the effect. The app reports when no sensor is available.
- The sensor must be one macOS marks as built-in. An external display with a similar sensor is ignored.
- The effect applies only to the built-in display.
- The effect stops when macOS sleeps as the lid closes.
- Clicks pass through the effect to the apps underneath.

## Acknowledgements

This project is built with AI assistance.

## License

Licensed under the [Apache License 2.0](LICENSE). Copyright 2026 Makito.

See [NOTICE](NOTICE) for attribution.
