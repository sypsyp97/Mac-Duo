import CoreGraphics
import DepthKit
import Metal
import simd
import Testing

struct DepthPhysicsTests {
    private let size = CGSize(width: 1512, height: 982)
    private let ratio = 2.81

    // Independent world coordinates: forward along the desk, then up.
    private func axes(_ angle: Double) -> (along: SIMD3<Double>, normal: SIMD3<Double>) {
        let radians = angle * .pi / 180
        return (SIMD3(0, cos(radians), sin(radians)), SIMD3(0, sin(radians), -cos(radians)))
    }

    private func eye(start: Double, size: CGSize, ratio: Double) -> SIMD3<Double> {
        axes(start).along * (size.height / 2) + SIMD3(size.width / 2, size.height * ratio, 0)
    }

    private func optics(start: Double, current: Double, size: CGSize, ratio: Double) -> DepthOptics {
        DepthOptics(frame: DepthGeometry().frame(startAngle: start, currentAngle: current,
                    viewingDistanceRatio: ratio, screenSize: size),
                    millimetresPerPoint: nil, screenSize: size)
    }

    @Test func fixedWorldPictureProjectsOntoMovingGlass() {
        for start in [40.0, 70, 90, 110, 130] {
            let e = eye(start: start, size: size, ratio: ratio)
            for current in stride(from: start + 2, through: 15, by: -2) {
                let glass = axes(current)
                let frame = optics(start: start, current: current, size: size, ratio: ratio)
                #expect(abs(frame.pictureDistance - simd_dot(e, axes(start).normal)) < 1e-9)
                let actual = DepthGeometry().corners(startAngle: start, currentAngle: current,
                                viewingDistanceRatio: ratio, screenSize: size)
                let points: [SIMD2<Double>] = [SIMD2(0, 0), SIMD2(Double(size.width), 0),
                    SIMD2(Double(size.width), Double(size.height)), SIMD2(0, Double(size.height))]
                for (i, uv) in points.enumerated() {
                    let p = SIMD3(uv.x, 0, 0) + axes(start).along * uv.y
                    let direction = p - e
                    let t = -simd_dot(e, glass.normal) / simd_dot(direction, glass.normal)
                    let g = e + t * direction
                    #expect(abs(actual[i].x - g.x) < 1e-8)
                    #expect(abs(actual[i].y - simd_dot(g, glass.along)) < 1e-8)
                    let back = frame.screenToPicture * SIMD3(g.x, simd_dot(g, glass.along), 1)
                    #expect(simd_length(SIMD2(back.x, back.y) / back.z - uv) < 1e-7)
                }
            }
        }
    }

    @Test func closingLeavesPictureBehindGlass() {
        let start = 110.0, current = 80.0
        let p = axes(start).along * size.height
        #expect(simd_dot(p, axes(current).normal) < 0)
        let corners = DepthGeometry().corners(startAngle: start, currentAngle: current,
                            viewingDistanceRatio: ratio, screenSize: size)
        #expect(corners[2].x - corners[3].x < size.width)
    }

    @Test func inverseSurvivesGlassCrossingEyePlane() {
        let e = eye(start: 110, size: size, ratio: ratio)
        let grazing = atan2(e.z, e.y) * 180 / .pi
        for current in [grazing - 0.001, grazing, grazing + 0.001] {
            let o = optics(start: 110, current: current, size: size, ratio: ratio)
            for i in 0..<3 {
                for j in 0..<3 { #expect(o.screenToPicture[i][j].isFinite) }
            }
        }
        #expect(optics(start: 110, current: grazing - 0.001, size: size, ratio: ratio).depth < 0)
        #expect(optics(start: 110, current: grazing + 0.001, size: size, ratio: ratio).depth > 0)
    }

    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil, "Requires a Metal device"))
    func gpuPreservesFirstFrameAndRadiance() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let queue = try #require(device.makeCommandQueue())
        let library = try device.makeLibrary(source: DepthShaders.source, options: nil)
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "depthVertex")
        descriptor.fragmentFunction = library.makeFunction(name: "depthFragment")
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm_srgb
        let pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        let width = 192, height = 128, padding = 32
        let testSize = CGSize(width: width / 2, height: height / 2)
        let tw = width + padding * 2, th = height + padding * 2
        let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm_srgb, width: tw, height: th, mipmapped: false)
        textureDescriptor.storageMode = .shared
        textureDescriptor.usage = .shaderRead
        let texture = try #require(device.makeTexture(descriptor: textureDescriptor))
        let targetDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm_srgb, width: width, height: height, mipmapped: false)
        targetDescriptor.storageMode = .shared
        targetDescriptor.usage = .renderTarget
        let target = try #require(device.makeTexture(descriptor: targetDescriptor))

        func upload(pattern: Bool, gradient: Bool = false) -> [UInt8] {
            var bytes = [UInt8](repeating: 0, count: tw * th * 4)
            for y in 0..<th {
                for x in 0..<tw {
                    let i = (y * tw + x) * 4
                    bytes[i + 3] = 255
                    if x >= padding && x < padding + width && y >= padding && y < padding + height {
                        for c in 0..<3 {
                            bytes[i + c] = pattern ? UInt8((x * 13 + y * 7 + c * 37) % 256) : 180
                            if gradient {
                                let coordinate = c == 0 ? Double(x - padding) / Double(width)
                                    : Double(y - padding) / Double(height)
                                bytes[i + c] = UInt8(80 + 100 * coordinate)
                            }
                        }
                    }
                }
            }
            texture.replace(region: MTLRegionMake2D(0, 0, tw, th), mipmapLevel: 0,
                            withBytes: bytes, bytesPerRow: tw * 4)
            return bytes
        }

        func render(start: Double, current: Double, ratio: Double) throws -> [UInt8] {
            let o = optics(start: start, current: current, size: testSize, ratio: ratio)
            let matrix = o.screenToPicture
            var uniforms = (0..<3).map { i -> SIMD4<Float> in
                let c = matrix[i]
                return SIMD4(Float(c.x), Float(c.y), Float(c.z), 0)
            }
            uniforms += [SIMD4(Float(testSize.width), Float(testSize.height), -16, -16),
                         SIMD4(Float(tw) / 2, Float(th) / 2, 2, 0),
                         SIMD4(Float(o.sinSeparation), Float(o.cosSeparation), Float(o.along), Float(o.depth)),
                         SIMD4(Float(o.halfWidth), Float(o.pupilRadius), 0, 0)]
            let command = try #require(queue.makeCommandBuffer())
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = target
            pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].storeAction = .store
            let encoder = try #require(command.makeRenderCommandEncoder(descriptor: pass))
            encoder.setRenderPipelineState(pipeline)
            uniforms.withUnsafeBytes {
                encoder.setFragmentBytes($0.baseAddress!, length: $0.count, index: 0)
            }
            encoder.setFragmentTexture(texture, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            encoder.endEncoding()
            command.commit()
            command.waitUntilCompleted()
            #expect(command.status == .completed)
            var bytes = [UInt8](repeating: 0, count: width * height * 4)
            target.getBytes(&bytes, bytesPerRow: width * 4,
                            from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
            return bytes
        }

        let source = upload(pattern: true)
        for start in [40.0, 90, 110, 130] {
            let result = try render(start: start, current: start, ratio: ratio)
            var maximumError = 0
            for y in 0..<height {
                for x in 0..<width {
                    for c in 0..<4 {
                        maximumError = max(maximumError, abs(Int(result[(y * width + x) * 4 + c])
                            - Int(source[((y + padding) * tw + x + padding) * 4 + c])))
                    }
                }
            }
            #expect(maximumError <= 1)
        }
        _ = upload(pattern: false)
        for current in [110.0, 90, 80, 60, 30, 5] {
            let result = try render(start: 110, current: current, ratio: ratio)
            let e = eye(start: 110, size: testSize, ratio: ratio)
            let glass = axes(current), picture = axes(110)
            if simd_dot(e, glass.normal) <= 0 {
                #expect(stride(from: 0, to: result.count, by: 4).allSatisfy { result[$0] == 0 })
                continue
            }
            var checked = 0
            for y in stride(from: 8, to: height - 8, by: 8) {
                for x in stride(from: 8, to: width - 8, by: 8) {
                    let g = SIMD3((Double(x) + 0.5) / 2, 0, 0)
                        + glass.along * (testSize.height - (Double(y) + 0.5) / 2)
                    let direction = g - e
                    let t = -simd_dot(e, picture.normal) / simd_dot(direction, picture.normal)
                    let p = e + t * direction
                    let py = simd_dot(p, picture.along)
                    if t > 0 && p.x > 16 && p.x < testSize.width - 16
                        && py > 16 && py < testSize.height - 16 {
                        #expect(abs(Int(result[(y * width + x) * 4]) - 180) <= 1)
                        checked += 1
                    }
                }
            }
            #expect(checked > 0)
        }
        _ = upload(pattern: false, gradient: true)
        let gradient = try render(start: 110, current: 80, ratio: ratio)
        let e = eye(start: 110, size: testSize, ratio: ratio)
        let glass = axes(80), picture = axes(110)
        var gradientChecks = 0
        for y in stride(from: 16, to: height - 16, by: 8) {
            for x in stride(from: 16, to: width - 16, by: 8) {
                let g = SIMD3((Double(x) + 0.5) / 2, 0, 0)
                    + glass.along * (testSize.height - (Double(y) + 0.5) / 2)
                let ray = g - e
                let t = -simd_dot(e, picture.normal) / simd_dot(ray, picture.normal)
                let p = e + t * ray
                let py = simd_dot(p, picture.along)
                if p.x > 16 && p.x < testSize.width - 16 && py > 16 && py < testSize.height - 16 {
                    let expectedX = 80 + 100 * (p.x * 2 - 0.5) / Double(width)
                    let expectedY = 80 + 100 * ((testSize.height - py) * 2 - 0.5) / Double(height)
                    #expect(abs(Double(gradient[(y * width + x) * 4]) - expectedX) < 2)
                    #expect(abs(Double(gradient[(y * width + x) * 4 + 1]) - expectedY) < 2)
                    gradientChecks += 1
                }
            }
        }
        #expect(gradientChecks > 0)
        // A nearby eye also exercises rays parallel to, or behind, the picture.
        _ = try render(start: 40, current: 30, ratio: 0.5)
    }
}
