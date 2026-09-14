import CoreGraphics
import Foundation
import simd

/// Where the picture lands on the glass.
///
/// The picture is a sheet hinged to the bottom edge of the screen. It keeps
/// its place in the room while the glass turns under it, so the projection
/// takes both the current lid angle and the eye position.
public struct DepthGeometry {

    public init() {}

    /// Where the eye and the picture sit for one lid angle.
    ///
    /// Picture points throughout, in the glass's own axes: `x` across, `y`
    /// along the glass from the hinge, `z` toward its viewing side. Closing
    /// moves the glass toward the eye, leaving the picture behind it:
    /// `(x, y)` on the picture sits at `(x, y cos, -y sin)` in glass axes.
    public struct Frame {
        public var separation: Double
        /// The eye, measured along the glass from the hinge.
        public var along: Double
        /// The eye, measured away from the glass.
        public var depth: Double
    }

    public func frame(
        startAngle: Double,
        currentAngle: Double,
        viewingDistanceRatio: Double,
        screenSize: CGSize
    ) -> Frame {
        let height = Double(screenSize.height)
        let start = startAngle * .pi / 180
        let current = currentAngle * .pi / 180
        // The picture and eye stay fixed in world space.
        let separation = (startAngle - currentAngle) * .pi / 180

        // The eye in world axes, hinge at the origin.
        let reach = height * viewingDistanceRatio + height / 2 * cos(start)
        let rise = height / 2 * sin(start)

        return Frame(
            separation: separation,
            along: reach * cos(current) + rise * sin(current),
            depth: reach * sin(current) - rise * cos(current)
        )
    }

    /// Bottom-left, bottom-right, top-right, top-left.
    public func corners(
        startAngle: Double,
        currentAngle: Double,
        viewingDistanceRatio: Double,
        screenSize: CGSize
    ) -> [CGPoint] {
        let width = Double(screenSize.width)
        let height = Double(screenSize.height)
        let solved = frame(
            startAngle: startAngle,
            currentAngle: currentAngle,
            viewingDistanceRatio: viewingDistanceRatio,
            screenSize: screenSize
        )
        let along = solved.along
        let depth = solved.depth
        let separation = solved.separation

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

/// The optics the shader needs, solved once per frame on the CPU.
///
/// Display size comes from macOS. Eye position and pupil size are assumed;
/// defocus approximates a thin lens focused on the glass along each view ray.
public struct DepthOptics {

    /// Assumed horizontal distance from the eye to the initial screen centre.
    public static let eyeDistanceMillimetres: Double = 550

    /// Pupil diameter in ordinary indoor light. This is the aperture, and it
    /// is what sets how fast the picture falls out of focus once it leaves the
    /// glass.
    public static let pupilMillimetres: Double = 3.5

    /// A 14-inch laptop, for displays whose size macOS will not report.
    private static let fallbackDistanceRatio: Double = 2.8

    public var sinSeparation: Double
    public var cosSeparation: Double
    public var along: Double
    public var depth: Double
    public var halfWidth: Double
    /// Half the pupil in glass points: the blur radius per unit of relative
    /// defocus.
    public var pupilRadius: Double

    /// Eye-to-picture signed distance. It stays constant as the glass rotates.
    public var pictureDistance: Double { depth * cosSeparation + along * sinSeparation }

    /// Analytic ray/plane intersection in homogeneous picture coordinates.
    /// Unlike fitting projected corners, this remains finite when the glass
    /// passes through the eye plane and its projected rectangle collapses.
    public var screenToPicture: simd_double3x3 {
        let k = pictureDistance
        return simd_double3x3(columns: (
            SIMD3(k, 0, 0),
            SIMD3(-halfWidth * sinSeparation, depth, -sinSeparation),
            SIMD3(0, 0, k)
        ))
    }

    public init(frame: DepthGeometry.Frame, millimetresPerPoint: Double?, screenSize: CGSize) {
        sinSeparation = sin(frame.separation)
        cosSeparation = cos(frame.separation)
        along = frame.along
        depth = frame.depth
        halfWidth = Double(screenSize.width) / 2
        if let millimetresPerPoint, millimetresPerPoint > 0 {
            pupilRadius = Self.pupilMillimetres / 2 / millimetresPerPoint
        } else {
            // Same pupil, sized against the fallback geometry.
            pupilRadius = Self.pupilMillimetres / 2
                * Double(screenSize.height) * Self.fallbackDistanceRatio
                / Self.eyeDistanceMillimetres
        }
    }

    /// Where the eye sits, as a multiple of the screen height.
    public static func viewingDistanceRatio(
        millimetresPerPoint: Double?,
        screenHeightPoints: Double
    ) -> Double {
        guard let millimetresPerPoint, millimetresPerPoint > 0, screenHeightPoints > 0 else {
            return fallbackDistanceRatio
        }
        return eyeDistanceMillimetres / millimetresPerPoint / screenHeightPoints
    }
}

/// What one frame needs beyond the lid angle, all of it read off the display
/// rather than set by hand.
public struct DepthTuning {
    /// The display's physical millimetres per point, when macOS reports them.
    public var millimetresPerPoint: Double?

    public init(millimetresPerPoint: Double? = nil) {
        self.millimetresPerPoint = millimetresPerPoint
    }

    /// Where the eye sits for a screen this tall, as a multiple of its height.
    public func viewingDistanceRatio(screenHeightPoints: Double) -> Double {
        DepthOptics.viewingDistanceRatio(
            millimetresPerPoint: millimetresPerPoint,
            screenHeightPoints: screenHeightPoints
        )
    }
}
