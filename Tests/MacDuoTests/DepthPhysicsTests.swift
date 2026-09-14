import CoreGraphics
import Foundation
import Testing
import simd
@testable import DepthKit

/// The picture is frozen in the room and the eye does not move, so the eye
/// must see exactly the same rectangle at every lid angle. These build the
/// scene from scratch in world coordinates and ray-trace it, sharing nothing
/// with the code under test but the inputs, then compare through a pinhole
/// camera at the eye. A sign convention shared by both sides would cancel in
/// that comparison, which is the point: an earlier version of this geometry
/// was self-consistent and wrong.
struct DepthPhysicsTests {

    static let width = 1512.0
    static let height = 982.0
    static let ratio = 2.81
    static let start = 110.0
    static var size: CGSize { CGSize(width: width, height: height) }

    /// The screen's "up" direction in world axes, for a lid at `degrees`.
    static func up(_ degrees: Double) -> SIMD3<Double> {
        let t = degrees * .pi / 180
        return SIMD3(0, cos(t), sin(t))
    }

    /// A point of the glass, in world coordinates.
    static func glass(_ degrees: Double, _ x: Double, _ y: Double) -> SIMD3<Double> {
        SIMD3(x - width / 2, 0, 0) + up(degrees) * y
    }

    /// The eye: on the normal through the screen centre at the start angle.
    static var eye: SIMD3<Double> {
        let centre = glass(start, width / 2, height / 2)
        let u = up(start)
        let normal = SIMD3(0.0, u.z, -u.y)      // toward the viewer
        return centre + normal * (ratio * height)
    }

    /// Pinhole image of a world point, looking at the screen centre.
    static func seen(_ p: SIMD3<Double>) -> SIMD2<Double>? {
        let centre = glass(start, width / 2, height / 2)
        let focal = ratio * height
        let forward = (centre - eye) / focal
        let upAxis = up(start)
        let right = SIMD3(1.0, 0.0, 0.0)
        let v = p - eye
        let z = simd_dot(v, forward)
        guard z > 1e-9 else { return nil }
        return SIMD2(focal * simd_dot(v, right) / z, focal * simd_dot(v, upAxis) / z)
    }

    static func optics(at current: Double) -> DepthOptics {
        let solved = DepthGeometry().frame(
            startAngle: Self.start,
            currentAngle: current,
            viewingDistanceRatio: Self.ratio,
            screenSize: Self.size
        )
        return DepthOptics(frame: solved, startAngle: Self.start, screenSize: Self.size)
    }

    /// What the shader will read for a glass point.
    static func picture(_ optics: DepthOptics, _ x: Double, _ y: Double) -> SIMD2<Double> {
        let h = optics.screenToPicture * SIMD3(x, y, 1)
        return SIMD2(h.x / h.z, h.y / h.z)
    }

    @Test func aFrozenPictureLooksIdenticalFromEveryLidAngle() {
        for current in stride(from: Self.start, through: 30.0, by: -5.0) {
            let optics = Self.optics(at: current)
            for (x, y) in [(0.0, 0.0), (Self.width, 0.0), (0.0, Self.height),
                           (Self.width, Self.height), (Self.width / 2, Self.height / 2)] {
                // What the shader puts at this glass point...
                let source = Self.picture(optics, x, y)
                // ...is a point of the picture, which lives at the start angle.
                let world = Self.glass(Self.start, source.x, source.y)
                guard let target = Self.seen(world),
                      let actual = Self.seen(Self.glass(current, x, y)) else { continue }
                let error = simd_distance(target, actual)
                #expect(
                    error < 0.01,
                    "lid \(current)°, glass (\(x), \(y)): the eye sees a \(error) pt shift"
                )
            }
        }
    }

    @Test func theMappingIsTheIdentityBeforeTheLidMoves() {
        let optics = Self.optics(at: Self.start)
        for (x, y) in [(0.0, 0.0), (Self.width, Self.height), (Self.width / 2, 321.0)] {
            let source = Self.picture(optics, x, y)
            #expect(abs(source.x - x) < 1e-6 && abs(source.y - y) < 1e-6)
        }
    }

    /// The denominator that a naive picture-to-glass projection divides by can
    /// reach zero; this direction cannot, which is why the shader uses it.
    @Test func theMappingNeverDegenerates() {
        for current in stride(from: Self.start, through: 0.0, by: -1.0) {
            let optics = Self.optics(at: current)
            for y in stride(from: 0.0, through: Self.height, by: Self.height / 8) {
                let h = optics.screenToPicture * SIMD3(Self.width / 2, y, 1)
                #expect(abs(h.z) > 1e-6, "lid \(current)°, y \(y): the divide collapsed")
            }
        }
    }

    /// Round trip through a brute-force intersection, which shares no algebra
    /// with the matrix: send a picture point to the glass by hand, push that
    /// glass point back through `screenToPicture`, and it must come home. This
    /// catches a mistranscribed matrix entry, which the camera test above
    /// could in principle absorb.
    @Test func theMatrixInvertsAHandComputedIntersection() {
        for current in stride(from: Self.start, through: 50.0, by: -10.0) {
            let optics = Self.optics(at: current)
            for (u, v) in [(0.0, 0.0), (Self.width, Self.height),
                           (Self.width / 3, Self.height / 4), (Self.width, Self.height / 2)] {
                // Ray from the eye to the picture point, meeting the glass.
                let target = Self.glass(Self.start, u, v)
                let normal = SIMD3(0.0, Self.up(current).z, -Self.up(current).y)
                let toEye = simd_dot(Self.eye, normal)
                let toTarget = simd_dot(target, normal)
                guard abs(toEye - toTarget) > 1e-9 else { continue }
                let step = toEye / (toEye - toTarget)
                let hit = Self.eye + (target - Self.eye) * step
                let onGlass = SIMD2(hit.x + Self.width / 2, simd_dot(hit, Self.up(current)))

                let home = Self.picture(optics, onGlass.x, onGlass.y)
                #expect(
                    simd_distance(home, SIMD2(u, v)) < 0.01,
                    "lid \(current)°, picture (\(u), \(v)) came back at \(home)"
                )
            }
        }
    }

    /// The reference effect crops the picture against the screen edge as the
    /// lid closes. `screenToPicture` runs glass to picture, so that shows up
    /// as the screen covering an ever wider slice of the picture: the picture
    /// itself is shrinking on the glass and falling inside the bezel.
    @Test func theScreenCoversMoreOfThePictureAsTheLidCloses() {
        var previous = 0.0
        for current in stride(from: Self.start, through: 50.0, by: -10.0) {
            let optics = Self.optics(at: current)
            let covered = Self.picture(optics, Self.width, Self.height).x
                - Self.picture(optics, 0, Self.height).x
            #expect(
                covered >= previous - 1e-9,
                "at \(current)° the screen suddenly covered less of the picture"
            )
            previous = covered
        }
        // Starts as an exact fit, then really does widen rather than crawl.
        let open = Self.optics(at: Self.start)
        let openSpan = Self.picture(open, Self.width, Self.height).x
            - Self.picture(open, 0, Self.height).x
        #expect(abs(openSpan - Self.width) < 1e-6)
        #expect(previous > Self.width * 1.3, "the picture barely changed size")
    }

    @Test func theLookRunsFromUntouchedToShut() {
        let open = Self.optics(at: Self.start)
        #expect(open.travel == 0)
        #expect(open.blurRadius == 0)
        #expect(open.brightness == 1)

        let shut = Self.optics(at: 0)
        #expect(abs(shut.travel - 1) < 1e-9)
        #expect(abs(shut.blurRadius - DepthOptics.maximumBlurPoints) < 1e-9)
        #expect(shut.brightness == 0)

        // Monotone in between, which is what keeps the ramp from reversing.
        var previousBlur = -1.0
        var previousBrightness = 2.0
        for current in stride(from: Self.start, through: 0.0, by: -5.0) {
            let o = Self.optics(at: current)
            #expect(o.blurRadius >= previousBlur)
            #expect(o.brightness <= previousBrightness)
            previousBlur = o.blurRadius
            previousBrightness = o.brightness
        }
    }
}
