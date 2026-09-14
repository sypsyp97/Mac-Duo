import CoreGraphics
import simd
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

    /// Where the eye and the picture sit for one lid angle.
    ///
    /// Picture points throughout, in the glass's own axes: `x` across, `y`
    /// along the glass from the hinge, `z` away from it. The picture plane is
    /// the glass turned about the hinge by `separation`, so a picture point
    /// `(x, y)` sits at `(x, y cos, y sin)` and the same point of the glass
    /// under it at `(x, y, 0)`.
    public struct Frame {
        public var separation: Double
        /// The eye, measured along the glass from the hinge.
        public var along: Double
        /// The eye, measured away from the glass.
        public var depth: Double

        public var eye: SIMD3<Double> { SIMD3(0, along, depth) }

        /// Where a picture point floats, once the picture has turned away.
        public func picturePosition(x: Double, y: Double) -> SIMD3<Double> {
            SIMD3(x, y * cos(separation), y * sin(separation))
        }

        /// The point of the glass under it, which is where the eye is focused.
        public func glassPosition(x: Double, y: Double) -> SIMD3<Double> {
            SIMD3(x, y, 0)
        }

        /// Outward normal of the turned picture.
        public var pictureNormal: SIMD3<Double> {
            SIMD3(0, -sin(separation), cos(separation))
        }
    }

    public func frame(
        startAngle: Double,
        currentAngle: Double,
        viewingDistanceRatio: Double,
        recession: Double,
        screenSize: CGSize
    ) -> Frame {
        let height = Double(screenSize.height)
        let start = startAngle * .pi / 180
        let current = currentAngle * .pi / 180
        let travel = max(startAngle - currentAngle, 0)
        let separation = min(recession * travel, maxSeparationDegrees) * .pi / 180

        // The eye in world axes, hinge at the origin.
        let reach = height * viewingDistanceRatio + height / 2 * cos(start)
        let rise = height / 2 * sin(start)

        return Frame(
            separation: separation,
            along: reach * cos(current) + rise * sin(current),
            depth: max(reach * sin(current) - rise * cos(current), height / 10)
        )
    }

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
        let solved = frame(
            startAngle: startAngle,
            currentAngle: currentAngle,
            viewingDistanceRatio: viewingDistanceRatio,
            recession: recession,
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
/// Defocus is a thin lens focused on the glass, so a picture still lying on
/// the glass is sharp everywhere by construction and the blur grows out of the
/// geometry as the picture turns away. `cocScale` normalises the circle of
/// confusion so that the far edge, at the largest separation the geometry
/// allows, lands exactly on the configured maximum blur radius.
public struct DepthOptics {
    public var sinSeparation: Double
    public var cosSeparation: Double
    public var along: Double
    public var depth: Double
    public var halfWidth: Double
    public var cocScale: Double

    public init(frame: DepthGeometry.Frame, geometry: DepthGeometry, screenSize: CGSize) {
        let width = Double(screenSize.width)
        let height = Double(screenSize.height)
        sinSeparation = sin(frame.separation)
        cosSeparation = cos(frame.separation)
        along = frame.along
        depth = frame.depth
        halfWidth = width / 2

        // The same eye, the picture turned as far as it ever goes: the circle
        // of confusion there is what the maximum blur radius means.
        var widest = frame
        widest.separation = geometry.maxSeparationDegrees * .pi / 180
        let eye = SIMD3(halfWidth, frame.along, frame.depth)
        let far = widest.picturePosition(x: halfWidth, y: height)
        let glass = widest.glassPosition(x: halfWidth, y: height)
        let reference = abs(1 / distance(eye, glass) - 1 / distance(eye, far))
        cocScale = reference > 1e-12 ? 1 / reference : 0
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
    /// Drive the defocus and the light from the geometry rather than from the
    /// height ramps.
    public var isPhysicalOptics: Bool = true

    public init(
        viewingDistance: Double = 2.7,
        recession: Double = 2,
        blurEvenness: Double = 0.4,
        dimReach: Double = 0.7,
        maxBlurRadius: Double = 55,
        maxDim: Double = 0.4,
        isPhysicalOptics: Bool = true
    ) {
        self.viewingDistance = viewingDistance
        self.recession = recession
        self.blurEvenness = blurEvenness
        self.dimReach = dimReach
        self.maxBlurRadius = maxBlurRadius
        self.maxDim = maxDim
        self.isPhysicalOptics = isPhysicalOptics
    }
}
