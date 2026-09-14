<div align="center">

# Mac Duo

**The iPhone Duo effect, on a MacBook.**

Close the lid and the screen tilts, blurs and fades as it goes. The picture is lifted off the
glass and left standing in the room while the panel turns under it, so what you see is where the
picture would actually be.

**Available in:** English and Simplified Chinese (简体中文).

<img src="./assets/menu.png" width="400" alt="Mac Duo menu">

</div>

<hr>

## What it does

- **Physical optics.** Defocus is a thin lens focused on the glass, and the light is Lambert
  against the turned panel with inverse-square falloff. Both are exactly neutral while the
  picture still lies on the glass, so the effect grows out of the geometry rather than out of a
  tuned curve.
- **Live screen content.** ScreenCaptureKit feeds the picture in real time.
- **Metal rendering.** One full-screen pass per frame, 0.44 ms on an M5 Pro against an 8.3 ms
  budget at 120 Hz.
- **Adjustable viewpoint.** Move the eye position so the perspective matches where you sit.

## Requirements

macOS 14 or later, and a MacBook with a lid angle sensor. The app says so when there is none.
Screen Recording permission is required; the app asks on first launch.

## Build

Xcode with Swift 6.0 or later:

```sh
./build.sh          # build and sign
./build.sh --run    # build, sign, and relaunch
./build.sh --universal
```

The app lands in `build/Mac Duo.app`.

### Signing, and why it matters here

`build.sh` signs ad-hoc by default. An ad-hoc signature has no stable identity — the designated
requirement is the code hash — so **every rebuild invalidates the Screen Recording grant**. The
entry left behind still reads as enabled in System Settings while capture keeps failing with
`-3801`, which looks like a permission bug and is not one.

Sign with any code-signing identity and the requirement becomes the bundle id plus the
certificate, which survives rebuilds:

```sh
SIGN_IDENTITY="My Local Signing" ./build.sh --universal
codesign -d -r- "build/Mac Duo.app"
# designated => identifier "to.maki.MacDuo" and certificate root = H"..."
```

A self-signed certificate is enough: Keychain Access → Certificate Assistant → Create a
Certificate, type *Code Signing*. Grant the permission once after that.

## Settings

| Setting | What it does |
|---|---|
| Depth effect | Master switch. |
| Live rendering | Off holds the frame from when the effect started. |
| Physical optics | Focus and light from where the picture is. Off restores the fixed gradients. |
| Timeout | Ends the effect once the angle stops changing. |
| Start angle | Closing past this angle starts the effect. |
| Blur | How wide the lens opens. |
| Dimming | How much of the measured light loss to apply. |
| Lean back | Degrees the picture leans per degree of closing. 1 holds it still in the room. |
| Perspective | Where the eye sits, as a multiple of the screen height. |

Three sliders that only shape the old gradients — *Full effect after*, *Blur spread*,
*Dimming spread* — are hidden while Physical optics is on, because nothing reads them.

## Measurements

`swift build -c release --product depthbench && .build/release/depthbench` runs the live path's
own work off screen at the built-in display's real size. On an M5 Pro at 3024×1964, padded
picture 3504×2444, 12 pyramid levels:

| Stage | p50 |
|---|---|
| Copy the frame in and rebuild the pyramid | 0.330 ms |
| Full screen shader pass | 0.114 ms |
| **Per frame** | **0.442 ms** |
| Build one still picture, once per effect | 4.4 ms |

Two optimisations were measured and dropped: trimming the 120 pt black margin, worth at most
0.2 ms of that, and filling only the margin before drawing the screenshot, whose measured effect
changed sign across repeated runs. On Apple Silicon this effect is not compute-bound; the
capture stream takes 30–50 ms to start, a hundred times the whole GPU path.

## Known limitations

- Only MacBooks with a lid angle sensor can run the effect.
- The sensor must be one macOS marks as built-in; an external display with a similar sensor is
  ignored.
- The effect applies to the built-in display only.
- It stops when macOS sleeps as the lid closes, so the visible part is the first stretch of
  travel.
- Clicks pass straight through to the apps underneath.

## Changes

See [CHANGELOG.md](CHANGELOG.md).

## Credits

Built on [sumimakito/Mac-Duo](https://github.com/sumimakito/Mac-Duo), Apache-2.0.

## License

Licensed under the [Apache License 2.0](LICENSE). Copyright 2026 Yipeng Sun.

See [NOTICE](NOTICE) for attribution.
