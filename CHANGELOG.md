# Changelog

All notable changes to this fork. Kept in the style of
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added

- **Physical optics**, on by default. Defocus is a thin lens focused on the glass and the light
  is Lambert against the turned panel with inverse-square falloff. Both are exactly neutral at
  zero separation, so the effect grows out of the geometry instead of out of a tuned curve.
- Mip selection now takes the screen-space derivative of the picture coordinate. The receding
  half was minified well below one texel per pixel and shimmered.
- An application icon, with `Scripts/make-icon.py` to regenerate it rather than only replace it.
- `depthbench`, a probe that runs the live path's GPU work off screen and reports each stage
  from the command buffer's timestamps.
- `DepthKit`, holding the geometry, the homography, the gradients and the shader source, so a
  benchmark and the tests can reach them.

### Fixed

- **Simplified Chinese came out in English in every released build.** SwiftPM writes the
  localization as `zh-hans.lproj` for a plain build and `zh-Hans.lproj` for a universal one, and
  `Bundle` matches resource names case-sensitively even on a case-insensitive filesystem. The
  lookup asked for a fixed casing, so it worked when built locally and fell back to the main
  bundle in the DMG. The spelling now comes from `Bundle.localizations`.
- **The effect drew garbage on some GPUs.** When `MPSImageGaussianPyramid`'s in-place encode
  returns false the levels above 0 are never written, and the shader samples them by number:
  black borders in one report, a red gradient in another, both from a 2019 Intel MacBook Pro.
  The blit encoder's box filter now stands in.
- **The app never asked for Screen Recording.** The only route was finding it in System Settings
  by hand, which silently fails for an ad-hoc build whose identity changes on every rebuild. It
  now requests at launch and from the panel's button.
- **The launch-at-login switch reported what was asked for, not what macOS did.** `register()`
  succeeds into `.requiresApproval` when background items have not been allowed, and removing
  the item in System Settings left the switch on for the rest of the session. The status is read
  back after every change and on every appearance.
- `build.sh --run` matched on the process name, so a development run terminated a copy installed
  in `/Applications`. It now matches the full executable path.

### Changed

- *Full effect after*, *Blur spread* and *Dimming spread* are hidden while Physical optics is
  on: nothing reads them in that mode. *Blur* becomes the aperture and *Dimming* becomes how
  much of the measured light loss to apply.

### Measured and not done

- Trimming the 120 pt black margin around the picture: worth at most 0.2 ms of a 0.44 ms frame.
- Filling only the margin before drawing the screenshot: the measured effect changed sign across
  repeated runs.
