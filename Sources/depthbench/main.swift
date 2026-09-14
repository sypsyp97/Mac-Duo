import AppKit
import DepthKit
import Metal
import MetalPerformanceShaders
import simd

/// Times the per-frame GPU work of the depth effect off screen.
///
/// The live path is the hot one: every frame copies a capture frame into the
/// picture, rebuilds the Gaussian pyramid over it, and draws one full screen
/// pass. This runs that same work at the built-in display's real size and
/// reports each stage separately, so an optimisation can be compared against a
/// number rather than an impression.
///
///     depthbench [--frames N] [--padding PT] [--json PATH]

struct Options {
    var frames = 300
    var warmup = 30
    var padding: CGFloat = 120
    var json: String?
}

func parse() -> Options {
    var o = Options()
    var it = CommandLine.arguments.dropFirst().makeIterator()
    while let a = it.next() {
        switch a {
        case "--frames": o.frames = Int(it.next() ?? "") ?? o.frames
        case "--warmup": o.warmup = Int(it.next() ?? "") ?? o.warmup
        case "--padding": o.padding = CGFloat(Double(it.next() ?? "") ?? Double(o.padding))
        case "--json": o.json = it.next()
        default: FileHandle.standardError.write("unknown argument: \(a)\n".data(using: .utf8)!); exit(2)
        }
    }
    return o
}

/// Milliseconds a command buffer spent on the GPU.
func gpuMilliseconds(_ buffer: MTLCommandBuffer) -> Double {
    (buffer.gpuEndTime - buffer.gpuStartTime) * 1000
}

func percentile(_ sorted: [Double], _ p: Double) -> Double {
    guard !sorted.isEmpty else { return 0 }
    let index = Int((Double(sorted.count - 1) * p).rounded())
    return sorted[index]
}

let options = parse()

guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
    FileHandle.standardError.write("no Metal device\n".data(using: .utf8)!)
    exit(1)
}

// The built-in display, or a 14-inch default when the bench runs headless.
let screen = NSScreen.screens.first {
    guard let number = $0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
    else { return false }
    return CGDisplayIsBuiltin(number.uint32Value) != 0
}
let screenSize = screen?.frame.size ?? CGSize(width: 1512, height: 982)
let pixelScale = screen?.backingScaleFactor ?? 2

let paddedSize = CGSize(
    width: screenSize.width + 2 * options.padding,
    height: screenSize.height + 2 * options.padding
)
let paddedWidth = Int((paddedSize.width * pixelScale).rounded())
let paddedHeight = Int((paddedSize.height * pixelScale).rounded())
let frameWidth = Int((screenSize.width * pixelScale).rounded())
let frameHeight = Int((screenSize.height * pixelScale).rounded())
let levels = Int(floor(log2(Double(max(paddedWidth, paddedHeight))))) + 1

let pictureDescriptor = MTLTextureDescriptor.texture2DDescriptor(
    pixelFormat: .bgra8Unorm_srgb,
    width: paddedWidth,
    height: paddedHeight,
    mipmapped: true
)
pictureDescriptor.usage = [.shaderRead, .shaderWrite, .renderTarget]
pictureDescriptor.storageMode = .private

// Stands in for the ScreenCaptureKit frame, which arrives without mipmaps.
let frameDescriptor = MTLTextureDescriptor.texture2DDescriptor(
    pixelFormat: .bgra8Unorm_srgb,
    width: frameWidth,
    height: frameHeight,
    mipmapped: false
)
frameDescriptor.usage = [.shaderRead, .shaderWrite]
// Shared, like the IOSurface a capture frame arrives on, and writable from the
// CPU so the noise can be uploaded directly.
frameDescriptor.storageMode = .shared

let targetDescriptor = MTLTextureDescriptor.texture2DDescriptor(
    pixelFormat: .bgra8Unorm_srgb,
    width: frameWidth,
    height: frameHeight,
    mipmapped: false
)
targetDescriptor.usage = [.renderTarget, .shaderRead]
targetDescriptor.storageMode = .private

guard var picture = device.makeTexture(descriptor: pictureDescriptor),
      let capture = device.makeTexture(descriptor: frameDescriptor),
      let target = device.makeTexture(descriptor: targetDescriptor) else {
    FileHandle.standardError.write("texture allocation failed\n".data(using: .utf8)!)
    exit(1)
}

// Noise rather than a flat fill, so the pyramid has real work to average and
// the sampler cannot coalesce identical texels.
do {
    let bytesPerRow = frameWidth * 4
    var pixels = [UInt8](repeating: 0, count: bytesPerRow * frameHeight)
    var state: UInt64 = 0x2545F4914F6CDD1D
    for i in stride(from: 0, to: pixels.count, by: 4) {
        state ^= state << 13; state ^= state >> 7; state ^= state << 17
        pixels[i] = UInt8(truncatingIfNeeded: state)
        pixels[i + 1] = UInt8(truncatingIfNeeded: state >> 8)
        pixels[i + 2] = UInt8(truncatingIfNeeded: state >> 16)
        pixels[i + 3] = 255
    }
    capture.replace(
        region: MTLRegionMake2D(0, 0, frameWidth, frameHeight),
        mipmapLevel: 0,
        withBytes: pixels,
        bytesPerRow: bytesPerRow
    )
}

let pipeline: MTLRenderPipelineState
do {
    let library = try device.makeLibrary(source: DepthShaders.source, options: nil)
    let descriptor = MTLRenderPipelineDescriptor()
    descriptor.vertexFunction = library.makeFunction(name: "depthVertex")
    descriptor.fragmentFunction = library.makeFunction(name: "depthFragment")
    descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm_srgb
    pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
} catch {
    FileHandle.standardError.write("pipeline: \(error)\n".data(using: .utf8)!)
    exit(1)
}

struct Uniforms {
    var column0: SIMD4<Float>
    var column1: SIMD4<Float>
    var column2: SIMD4<Float>
    var screenAndOrigin: SIMD4<Float>
    var paddedAndBlur: SIMD4<Float>
    var shape: SIMD4<Float>
    var light: SIMD4<Float>
    var optics0: SIMD4<Float>
    var optics1: SIMD4<Float>
}

// A lid part way through its travel: the geometry is tilted and the blur is
// half strength, which is where the shader samples the widest spread of mip
// levels.
let geometry = DepthGeometry()
let corners = geometry.corners(
    startAngle: 90,
    currentAngle: 60,
    viewingDistanceRatio: 6,
    recession: 1,
    screenSize: screenSize
)
let solvedFrame = geometry.frame(
    startAngle: 90,
    currentAngle: 60,
    viewingDistanceRatio: 6,
    recession: 1,
    screenSize: screenSize
)
let optics = DepthOptics(frame: solvedFrame, geometry: geometry, screenSize: screenSize)
let inverse = Homography.matrix(
    width: Double(screenSize.width),
    height: Double(screenSize.height),
    to: corners.map { SIMD2(Double($0.x), Double($0.y)) }
).inverse

func column(_ index: Int) -> SIMD4<Float> {
    let c = inverse[index]
    return SIMD4(Float(c.x), Float(c.y), Float(c.z), 0)
}

let maxBlurRadius = 135.0
var uniforms = Uniforms(
    column0: column(0),
    column1: column(1),
    column2: column(2),
    screenAndOrigin: SIMD4(
        Float(screenSize.width), Float(screenSize.height),
        Float(-options.padding), Float(-options.padding)
    ),
    paddedAndBlur: SIMD4(
        Float(paddedSize.width), Float(paddedSize.height),
        Float(maxBlurRadius * Double(pixelScale)), 0.5
    ),
    shape: SIMD4(0, 1, Float(pixelScale), Float(levels - 1)),
    light: SIMD4(0.2, 0.5, 0.7, 0),
    optics0: SIMD4(Float(optics.sinSeparation), Float(optics.cosSeparation),
                   Float(optics.along), Float(optics.depth)),
    optics1: SIMD4(Float(optics.halfWidth), Float(optics.cocScale), 1, 0)
)

let pyramid = MPSImageGaussianPyramid(device: device, centerWeight: 0.375)
let inset = Int((options.padding * pixelScale).rounded())

/// One frame's copy and pyramid rebuild, on its own command buffer so the two
/// stages can be timed apart.
func encodeAbsorb() -> MTLCommandBuffer? {
    guard let commands = queue.makeCommandBuffer(),
          let blit = commands.makeBlitCommandEncoder() else { return nil }
    blit.copy(
        from: capture,
        sourceSlice: 0,
        sourceLevel: 0,
        sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
        sourceSize: MTLSize(width: frameWidth, height: frameHeight, depth: 1),
        to: picture,
        destinationSlice: 0,
        destinationLevel: 0,
        destinationOrigin: MTLOrigin(x: inset, y: inset, z: 0)
    )
    blit.endEncoding()
    if !pyramid.encode(commandBuffer: commands, inPlaceTexture: &picture, fallbackCopyAllocator: nil) {
        guard let fallback = commands.makeBlitCommandEncoder() else { return nil }
        fallback.generateMipmaps(for: picture)
        fallback.endEncoding()
    }
    return commands
}

func encodeRender() -> MTLCommandBuffer? {
    guard let commands = queue.makeCommandBuffer() else { return nil }
    let pass = MTLRenderPassDescriptor()
    pass.colorAttachments[0].texture = target
    pass.colorAttachments[0].loadAction = .clear
    pass.colorAttachments[0].storeAction = .store
    pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
    guard let encoder = commands.makeRenderCommandEncoder(descriptor: pass) else { return nil }
    encoder.setRenderPipelineState(pipeline)
    encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
    encoder.setFragmentTexture(picture, index: 0)
    encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
    encoder.endEncoding()
    return commands
}

/// The still-picture path: one screenshot is laid on a black margin through a
/// CGContext, uploaded, and turned into a pyramid before anything can be shown.
/// This runs once per effect, on the way to the first frame, so it is latency
/// the user waits through rather than per-frame cost.
func measurePictureBuild(marginOnlyFill: Bool) -> [String: Double] {
    let byteCount = paddedWidth * paddedHeight * 4
    guard let staging = device.makeBuffer(length: byteCount, options: .storageModeShared) else {
        return [:]
    }
    let space = CGColorSpaceCreateDeviceRGB()
    let started = CFAbsoluteTimeGetCurrent()
    guard let context = CGContext(
        data: staging.contents(),
        width: paddedWidth,
        height: paddedHeight,
        bitsPerComponent: 8,
        bytesPerRow: paddedWidth * 4,
        space: space,
        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
    ) else { return [:] }
    let contextReady = CFAbsoluteTimeGetCurrent()

    let fillInset = options.padding * pixelScale
    context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
    if marginOnlyFill {
        // The draw below covers every interior pixel, so only the margin needs
        // blacking.
        context.fill([
            CGRect(x: 0, y: 0, width: CGFloat(paddedWidth), height: fillInset),
            CGRect(x: 0, y: CGFloat(paddedHeight) - fillInset,
                   width: CGFloat(paddedWidth), height: fillInset),
            CGRect(x: 0, y: fillInset, width: fillInset,
                   height: CGFloat(paddedHeight) - 2 * fillInset),
            CGRect(x: CGFloat(paddedWidth) - fillInset, y: fillInset, width: fillInset,
                   height: CGFloat(paddedHeight) - 2 * fillInset),
        ])
    } else {
        context.fill(CGRect(x: 0, y: 0, width: paddedWidth, height: paddedHeight))
    }
    let filled = CFAbsoluteTimeGetCurrent()

    // A screenshot the size of the screen, drawn into the padded interior.
    let source: CGImage = {
        let bytesPerRow = frameWidth * 4
        let data = CFDataCreateMutable(nil, bytesPerRow * frameHeight)!
        CFDataSetLength(data, bytesPerRow * frameHeight)
        let provider = CGDataProvider(data: data)!
        return CGImage(
            width: frameWidth, height: frameHeight,
            bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bytesPerRow,
            space: space,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        )!
    }()
    let inset = options.padding * pixelScale
    context.draw(source, in: CGRect(
        x: inset, y: inset,
        width: CGFloat(paddedWidth) - 2 * inset,
        height: CGFloat(paddedHeight) - 2 * inset
    ))
    let drawn = CFAbsoluteTimeGetCurrent()

    guard let commands = queue.makeCommandBuffer(),
          let blit = commands.makeBlitCommandEncoder() else { return [:] }
    blit.copy(
        from: staging, sourceOffset: 0,
        sourceBytesPerRow: paddedWidth * 4,
        sourceBytesPerImage: byteCount,
        sourceSize: MTLSize(width: paddedWidth, height: paddedHeight, depth: 1),
        to: picture, destinationSlice: 0, destinationLevel: 0,
        destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
    )
    blit.endEncoding()
    _ = pyramid.encode(commandBuffer: commands, inPlaceTexture: &picture, fallbackCopyAllocator: nil)
    commands.commit()
    commands.waitUntilCompleted()
    let finished = CFAbsoluteTimeGetCurrent()

    return [
        "context_ms": (contextReady - started) * 1000,
        "fill_black_ms": (filled - contextReady) * 1000,
        "draw_image_ms": (drawn - filled) * 1000,
        "upload_and_pyramid_ms": (finished - drawn) * 1000,
        "total_ms": (finished - started) * 1000,
    ]
}

/// The first builds pay for warm-up allocations the later ones reuse.
func pictureBuildReport(marginOnlyFill: Bool) -> [String: Double] {
    var runs: [[String: Double]] = []
    for _ in 0..<14 { runs.append(measurePictureBuild(marginOnlyFill: marginOnlyFill)) }
    var report: [String: Double] = [:]
    for key in runs.last?.keys.sorted() ?? [] {
        report[key] = percentile(runs.dropFirst(4).compactMap { $0[key] }.sorted(), 0.5)
    }
    return report
}

let pictureBuildFullFill = pictureBuildReport(marginOnlyFill: false)
let pictureBuildMarginFill = pictureBuildReport(marginOnlyFill: true)

var absorbTimes: [Double] = []
var renderTimes: [Double] = []

for iteration in 0..<(options.warmup + options.frames) {
    guard let absorb = encodeAbsorb() else { exit(1) }
    absorb.commit()
    absorb.waitUntilCompleted()
    guard let render = encodeRender() else { exit(1) }
    render.commit()
    render.waitUntilCompleted()
    guard iteration >= options.warmup else { continue }
    absorbTimes.append(gpuMilliseconds(absorb))
    renderTimes.append(gpuMilliseconds(render))
}

let absorbSorted = absorbTimes.sorted()
let renderSorted = renderTimes.sorted()
let totals = zip(absorbTimes, renderTimes).map(+).sorted()

func report(_ name: String, _ sorted: [Double]) -> [String: Double] {
    [
        "mean": sorted.reduce(0, +) / Double(sorted.count),
        "p50": percentile(sorted, 0.5),
        "p95": percentile(sorted, 0.95),
        "min": sorted.first ?? 0,
        "max": sorted.last ?? 0,
    ]
}

let result: [String: Any] = [
    "device": device.name,
    "screen_points": ["width": Double(screenSize.width), "height": Double(screenSize.height)],
    "pixel_scale": Double(pixelScale),
    "padding_points": Double(options.padding),
    "picture_pixels": ["width": paddedWidth, "height": paddedHeight],
    "frame_pixels": ["width": frameWidth, "height": frameHeight],
    "pyramid_levels": levels,
    "frames": options.frames,
    "copy_and_pyramid_ms": report("absorb", absorbSorted),
    "shader_pass_ms": report("render", renderSorted),
    "total_ms": report("total", totals),
    "picture_build_p50_ms": [
        "fill_whole_buffer": pictureBuildFullFill,
        "fill_margin_only": pictureBuildMarginFill,
    ],
]

let encoded = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
if let path = options.json {
    try encoded.write(to: URL(fileURLWithPath: path))
}
FileHandle.standardOutput.write(encoded)
FileHandle.standardOutput.write("\n".data(using: .utf8)!)
