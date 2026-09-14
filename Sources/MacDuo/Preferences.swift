import Combine
import Foundation

/// User settings, backed by `UserDefaults`.
///
/// There is one number to set. Everything the picture looks like is solved
/// from the lid angle and the display's own physical size, so there is nothing
/// left to tune.
@MainActor
final class Preferences: ObservableObject {
    static let shared = Preferences()

    private enum Key {
        static let isEnabled = "isEnabled"
        static let isTimeoutEnabled = "isTimeoutEnabled"
        static let thresholdAngle = "thresholdAngle"
        static let showsAngleInMenuBar = "showsAngleInMenuBar"
        static let isLivePicture = "isLivePicture"

        static let all = [
            isEnabled, isTimeoutEnabled, thresholdAngle, showsAngleInMenuBar, isLivePicture,
        ]
    }

    private static let factory: [String: Any] = [
        Key.isEnabled: true,
        Key.isTimeoutEnabled: false,
        Key.thresholdAngle: 90.0,
        Key.showsAngleInMenuBar: false,
        Key.isLivePicture: true,
    ]

    /// Master switch for the depth effect.
    @Published var isEnabled: Bool {
        didSet { defaults.set(isEnabled, forKey: Key.isEnabled) }
    }

    /// Ends the effect early if the angle holds still while below the
    /// threshold, instead of waiting for the lid to open back past it.
    @Published var isTimeoutEnabled: Bool {
        didSet { defaults.set(isTimeoutEnabled, forKey: Key.isTimeoutEnabled) }
    }

    /// Closing past this angle starts the depth effect. Degrees.
    @Published var thresholdAngle: Double {
        didSet { defaults.set(thresholdAngle, forKey: Key.thresholdAngle) }
    }

    /// Draw the live angle next to the menu bar icon.
    @Published var showsAngleInMenuBar: Bool {
        didSet { defaults.set(showsAngleInMenuBar, forKey: Key.showsAngleInMenuBar) }
    }

    /// Keep the picture under the effect updating, instead of holding the one
    /// frame that was on screen at the trigger angle.
    @Published var isLivePicture: Bool {
        didSet { defaults.set(isLivePicture, forKey: Key.isLivePicture) }
    }

    /// Highest angle above the threshold at which the pre-warm may run.
    let prewarmCeiling: Double = 70

    /// Closing speed in degrees per second that starts the pre-warm.
    let closingSpeed: Double = 8

    /// How long the pre-warm runs after the lid stops moving.
    let prewarmLinger: TimeInterval = 2

    /// Seconds between pre-warm screenshots.
    let prewarmInterval: TimeInterval = 0.25

    /// Degrees above the threshold before the overlay is released.
    let hysteresis: Double = 4

    /// Settings from earlier versions, removed at launch. The second line went
    /// when the optics started coming from the display's own geometry and had
    /// nothing left to read.
    private static let retired = [
        "blurFrontWidth", "maxTilt", "tiltDegrees", "tiltRatio", "dimEvenness",
        "blurSpan", "maxBlurRadius", "maxDim", "viewingDistance", "recession",
        "blurEvenness", "dimReach", "isPhysicalOptics",
    ]

    private let defaults = UserDefaults.standard

    // No inline values on purpose. Swift skips property observers for the
    // assignment that initialises a property.
    private init() {
        let defaults = UserDefaults.standard
        defaults.register(defaults: Self.factory)
        for key in Self.retired { defaults.removeObject(forKey: key) }
        isEnabled = defaults.bool(forKey: Key.isEnabled)
        isTimeoutEnabled = defaults.bool(forKey: Key.isTimeoutEnabled)
        thresholdAngle = defaults.double(forKey: Key.thresholdAngle)
        showsAngleInMenuBar = defaults.bool(forKey: Key.showsAngleInMenuBar)
        isLivePicture = defaults.bool(forKey: Key.isLivePicture)
    }

    func resetToDefaults() {
        for key in Key.all {
            defaults.removeObject(forKey: key)
        }
        isEnabled = defaults.bool(forKey: Key.isEnabled)
        isTimeoutEnabled = defaults.bool(forKey: Key.isTimeoutEnabled)
        thresholdAngle = defaults.double(forKey: Key.thresholdAngle)
        showsAngleInMenuBar = defaults.bool(forKey: Key.showsAngleInMenuBar)
        isLivePicture = defaults.bool(forKey: Key.isLivePicture)
    }
}
