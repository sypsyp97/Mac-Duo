import CoreGraphics
import Foundation

/// Where the picture lands on the glass.
///
/// The picture is a sheet hinged to the bottom edge of the screen, turned back
/// in world space by the angle the lid has travelled. The eye stays where it
/// is while the glass turns under it, so the projection takes both the current
/// lid angle and the eye position.
public struct DepthGeometry {

    /// Past 90 degrees the picture turns its face away from the glass.
    public var maxSeparationDegrees: Double = 88

    public init() {}

    /// Bottom-left, bottom-right, top-right, top-left.
    public func corners(
        startAngle: Double,
        currentAngle: Double,
        viewingDistanceRatio: Double,
        recession: Double,
        screenSize: CGSize
    ) -> [CGPoint] {
        let width = Double(screenSize.width)
        let height = Double(screenSize.height)
        let start = startAngle * .pi / 180
        let current = currentAngle * .pi / 180
        let travel = max(startAngle - currentAngle, 0)
        let separation = min(recession * travel, maxSeparationDegrees) * .pi / 180

        // The eye in world axes, hinge at the origin.
        let reach = height * viewingDistanceRatio + height / 2 * cos(start)
        let rise = height / 2 * sin(start)

        // The same eye, measured along the glass and away from it.
        let along = reach * cos(current) + rise * sin(current)
        let depth = max(reach * sin(current) - rise * cos(current), height / 10)

        let half = width / 2
        func project(_ x: Double, _ y: Double) -> CGPoint {
            let scale = depth / (depth + y * sin(separation))
            return CGPoint(
                x: half + (x - half) * scale,
                y: along + (y * cos(separation) - along) * scale
            )
        }
        return [project(0, 0), project(width, 0), project(width, height), project(0, height)]
    }
}

/// The settings that shape one frame.
public struct DepthTuning {
    public var viewingDistance: Double = 2.7
    public var recession: Double = 2
    public var blurEvenness: Double = 0.4
    public var dimReach: Double = 0.7
    public var maxBlurRadius: Double = 55
    public var maxDim: Double = 0.4

    public init(
        viewingDistance: Double = 2.7,
        recession: Double = 2,
        blurEvenness: Double = 0.4,
        dimReach: Double = 0.7,
        maxBlurRadius: Double = 55,
        maxDim: Double = 0.4
    ) {
        self.viewingDistance = viewingDistance
        self.recession = recession
        self.blurEvenness = blurEvenness
        self.dimReach = dimReach
        self.maxBlurRadius = maxBlurRadius
        self.maxDim = maxDim
    }
}
