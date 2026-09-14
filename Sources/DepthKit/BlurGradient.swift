import Foundation

/// How far out of focus the picture is at a given height, and how much light
/// it has lost. Height is 0 at the hinge edge and 1 at the far edge.
public struct BlurGradient {

    /// Exponent on the closing travel. Values above 1 start slowly.
    public var blurCurve: Double = 1.6

    /// Exponent on the closing travel for the dimming.
    public var dimCurve: Double = 0.7

    /// Dimming at the hinge edge, as a fraction of the dimming at the far
    /// edge.
    public var dimHingeFloor: Double = 0.2

    public init() {}

    public func blurStrength(progress: Double) -> Double {
        pow(min(max(progress, 0), 1), blurCurve)
    }

    public func dimStrength(progress: Double) -> Double {
        pow(min(max(progress, 0), 1), dimCurve)
    }
}
