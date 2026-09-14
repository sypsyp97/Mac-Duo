# Changelog

All notable changes to this fork. Kept in the style of
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [1.0.0]

First release under this name. It is a fork of
[sumimakito/Mac-Duo](https://github.com/sumimakito/Mac-Duo) with the projection re-solved, the
look driven from the lid rather than from sliders, and a way to tell it where you are sitting.

### Motion

- **The lid's smoothing is the original critically damped spring, deliberately.** Velocity
  extrapolation was written, tuned against a simulation of the measured sensor and unit tested; on
  paper it cut the lag of a steady close from several degrees to 0.75, and on a real lid it was
  clearly worse. A hand-pushed lid carries tremor and hinge stiction that a smooth simulated ramp
  does not, and extrapolating a velocity from that amplifies both. The code says so, so nobody
  repeats it.
- The sensor was measured: polling it at 270 Hz yields a new value **8.2 times a second**, gaps of
  103 ms median and 312 ms at worst, each about 0.02°. The display draws at 120 Hz, so fourteen
  frames in fifteen have nothing new.
- Polling runs at 24 Hz rather than 30, on feel. The likely mechanism is in the code comment: the
  velocity estimate divides by an interval the poll period quantises, and that velocity decides
  when the effect starts and stops.
- **A run that has just ended will not start another** until the lid has clearly been opened again,
  3° past the start angle or held at it for 0.4 s. Releasing is direction-aware, so opening across
  the start angle ended a run at once and closing back across it started another just as fast,
  leaving a band zero degrees wide. Measured on a real lid at a 105° start angle: runs ended at 106
  and restarted at 102 within 633 ms, replaying the whole fade out and in each time.


### Changed

- **The projection was solved properly.** The picture is meant to stay where it was in the room
  while the glass turns out from under it; instead it squashed downward, which reads as the image
  being flattened rather than as the screen moving away from it. The cause was re-expressing the
  eye in the rotating glass frame every angle, when its relation to the picture plane never
  changes. The acceptance test is the invariant itself: a picture fixed in space, seen from a
  fixed eye, must project to the same rectangle at every lid angle. The old mapping moved the top
  edge 125 pt at 90 degrees and 476 pt at 50; the new one holds it to 0.
- **Blur and dimming follow the lid angle, not a lens.** As optics they were vacuous — the picture
  and the eye are both fixed, so nothing ever leaves the focal plane and a real lens would hold
  focus the whole way. A 3.5 mm pupil gave 2.8 pt of blur at full travel against the 135 pt the
  effect wants. They now follow how far the panel has turned, which is what the effect this
  imitates does.
- **The settings are down to one control for the look.** Strength, 0 to 200%, pushes the blur and
  the dimming. Viewing distance and eye height feed the geometry and the camera can fill them in.
  Everything else is solved.

### Added

- **The camera finds the viewpoint.** Assuming the viewer sits 550 mm away on the screen's centre
  normal is wrong for most people, and visibly so: sitting at 700 while the app assumes 550 draws
  the top edge 10% narrow at a 60 degree separation, which reads as leaning away too much. A face
  gives the distance and the height, anchored by the one judgement a viewer can actually make —
  whether the picture has stopped leaning. Nobody is asked for a measurement they cannot take.
- The app is signed with `com.apple.security.device.camera`. Without it the hardened runtime
  refuses camera access outright, with no prompt and an immediate denial recorded.

### Fixed

- The panel's body height was fixed at 400 pt, sized for nine sliders that no longer exist, so
  most of it was empty. It sizes to its content.
- Opening the app from Finder or the Dock did nothing: an accessory app has no window to raise
  and nothing handled the reopen. It shows the panel.

### Notes for anyone working on this

- The camera's own metadata will mislead you. `OriginalCameraIntrinsicMatrix`,
  `PinholeCameraFocalLength` and `FocalLenIn35mmFilm` all describe the whole 3040 px super-wide
  sensor, while the delivered frame is a crop of it with a normal field of view. `SensorCropRect`,
  `RawCropRect` and `TotalScalingFromPhysicalSensor` all report the full frame and none of them
  says how much of it you got. Taking the full width puts the focal length out by 2.2x. That is
  why one lumped constant is calibrated instead of two read out.
- `DepthPhysicsTests` builds its scene from scratch in world coordinates and compares through a
  pinhole camera at the eye, sharing nothing with the code under test but the inputs. That matters:
  the geometry it replaced was self-consistent and wrong, and a test written in its own terms
  agreed with it.

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
