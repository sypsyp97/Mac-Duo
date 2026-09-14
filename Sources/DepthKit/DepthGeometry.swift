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
    /// Where the picture stands relative to the glass, for one lid angle.
    ///
    /// The picture is frozen in the room at the angle the lid had when the run
    /// started, and the eye does not move either, so the eye's relation to the
    /// *picture* plane never changes: it sits `eyeDistance` off it, level with
    /// the picture's centre. Only `separation` varies. Expressing the eye in
    /// the rotating glass frame instead, and recomputing it every angle, is
    /// what made the older projection squash the picture.
    public struct Frame {
        /// Radians the glass has turned away from the picture.
        public var separation: Double
        /// Eye to the picture plane, in picture points. Constant for a run.
        public var eyeDistance: Double
    }

    public func frame(
        startAngle: Double,
        currentAngle: Double,
        viewingDistanceRatio: Double,
        screenSize: CGSize
    ) -> Frame {
        Frame(
            separation: (startAngle - currentAngle) * .pi / 180,
            eyeDistance: Double(screenSize.height) * viewingDistanceRatio
        )
    }

}

/// What the shader needs, solved once per frame.
///
/// The map from a point of the glass to the point of the frozen picture the
/// eye sees through it. Derived by intersecting the ray from the eye with the
/// picture plane; with the eye a working distance away and the picture no
/// taller than the screen, `eyeDistance - y sin s` cannot reach zero, so this
/// direction never degenerates and needs no clipping.
///
/// The blur and the dimming are deliberately *not* optical. The picture is
/// fixed in the room and so is the eye, so its distance never changes and a
/// real lens would keep it in focus the whole way. Apple's effect, and every
/// recreation of it, drives both from how far the panel has turned instead.
public struct DepthOptics {

    /// Default distance from the eye to the screen centre. Sitting further
    /// back than this makes the picture read as leaning away more than it
    /// should: the top edge is drawn too narrow. At a 60 degree separation,
    /// assuming 550 mm while actually sitting at 700 draws the top edge 10%
    /// narrow; at 450 it comes out 14% wide. The geometry is exact either
    /// way, so this is the one measurement it needs from the room.
    public static let defaultEyeDistanceMillimetres: Double = 550

    /// A 14-inch laptop, for displays whose size macOS will not report.
    private static let fallbackDistanceRatio: Double = 2.8

    /// Blur radius at full travel, in points at the display's own scale.
    /// Chosen to land where the effect reads, not where a 3.5 mm pupil would:
    /// see the type's note.
    public static let maximumBlurPoints: Double = 135

    /// Exponent on the travel for the blur. Above 1 it starts gently.
    public static let blurCurve: Double = 1.6

    /// Exponent on the travel for the dimming. Below 1 it bites early.
    public static let dimCurve: Double = 0.7

    public var sinSeparation: Double
    public var cosSeparation: Double
    public var eyeDistance: Double
    public var halfWidth: Double
    public var halfHeight: Double
    /// How far up the screen plane the eye sits, measured from the hinge.
    /// Level with the screen centre unless something measured otherwise.
    public var eyeHeight: Double
    /// 0 with the picture still on the glass, 1 with the lid shut.
    public var travel: Double

    /// How far to push the blur and the dimming past what the geometry alone
    /// would do. The geometry is exact; this is the one number that is taste.
    /// 0 leaves the picture sharp and lit, 1 matches the effect this imitates.
    public var strength: Double = 1

    /// Blur radius at the far edge of the picture, in points. Every point
    /// below it blurs less, in proportion to how far off the glass it has
    /// floated; see the shader.
    public var blurRadius: Double {
        Self.maximumBlurPoints * strength * pow(travel, Self.blurCurve)
    }

    /// How far the far edge of the picture has floated off the glass, as a
    /// fraction of the screen height. The blur follows this up the picture,
    /// so it is zero at the hinge, zero everywhere while the picture still
    /// lies on the glass, and widest at the edge that has travelled furthest.
    public var farEdgeLift: Double { abs(sinSeparation) }

    /// What fraction of the light is left. 1 on the glass, 0 shut.
    public var brightness: Double {
        min(max(1 - strength * pow(travel, Self.dimCurve), 0), 1)
    }

    /// Glass point (x, y, 1) to picture point, in homogeneous coordinates.
    public var screenToPicture: simd_double3x3 {
        simd_double3x3(columns: (
            SIMD3(eyeDistance, 0, 0),
            SIMD3(-halfWidth * sinSeparation,
                  eyeDistance * cosSeparation - eyeHeight * sinSeparation,
                  -sinSeparation),
            SIMD3(0, 0, eyeDistance)
        ))
    }

    public init(
        frame: DepthGeometry.Frame,
        startAngle: Double,
        screenSize: CGSize,
        strength: Double = 1,
        eyeHeightAboveCentre: Double = 0
    ) {
        self.strength = max(strength, 0)
        eyeHeight = Double(screenSize.height) / 2 + eyeHeightAboveCentre
        sinSeparation = sin(frame.separation)
        cosSeparation = cos(frame.separation)
        eyeDistance = frame.eyeDistance
        halfWidth = Double(screenSize.width) / 2
        halfHeight = Double(screenSize.height) / 2
        // Flat is shut, so the travel runs from the trigger angle to zero.
        travel = startAngle > 0
            ? min(max(frame.separation * 180 / .pi / startAngle, 0), 1)
            : 0
    }

    /// Where the eye sits, as a multiple of the screen height.
    public static func viewingDistanceRatio(
        millimetresPerPoint: Double?,
        screenHeightPoints: Double,
        eyeDistanceMillimetres: Double = defaultEyeDistanceMillimetres
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
    /// See `DepthOptics.strength`.
    public var strength: Double
    /// How far the viewer actually sits from the screen.
    public var eyeDistanceMillimetres: Double
    /// How far above the screen centre their eyes are.
    public var eyeHeightMillimetres: Double

    public init(
        millimetresPerPoint: Double? = nil,
        strength: Double = 1,
        eyeDistanceMillimetres: Double = DepthOptics.defaultEyeDistanceMillimetres,
        eyeHeightMillimetres: Double = 0
    ) {
        self.millimetresPerPoint = millimetresPerPoint
        self.strength = strength
        self.eyeDistanceMillimetres = eyeDistanceMillimetres
        self.eyeHeightMillimetres = eyeHeightMillimetres
    }

    /// The eye height in points, for a display of this scale.
    public var eyeHeightPoints: Double {
        guard let millimetresPerPoint, millimetresPerPoint > 0 else { return 0 }
        return eyeHeightMillimetres / millimetresPerPoint
    }

    /// Where the eye sits for a screen this tall, as a multiple of its height.
    public func viewingDistanceRatio(screenHeightPoints: Double) -> Double {
        DepthOptics.viewingDistanceRatio(
            millimetresPerPoint: millimetresPerPoint,
            screenHeightPoints: screenHeightPoints,
            eyeDistanceMillimetres: eyeDistanceMillimetres
        )
    }
}
