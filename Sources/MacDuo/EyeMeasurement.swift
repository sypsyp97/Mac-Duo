import AVFoundation
import CoreGraphics
import Foundation
import Vision

/// Measures where the viewer's eyes are, from one look through the camera.
///
/// The projection needs two numbers about the room: how far the eye is from
/// the screen plane, and how high it sits. Both fall out of a face, once the
/// camera's scale is known.
///
/// That scale has to be calibrated rather than read out. This is a super-wide
/// sensor, 3040 px across, and the video stream is a crop of it with a normal
/// field of view. The intrinsic matrix, `PinholeCameraFocalLength` and
/// `FocalLenIn35mmFilm` all describe the whole sensor, and nothing in the
/// metadata says how much of it the delivered frame covers; taking the full
/// width, which is what those fields invite, puts the focal length out by 2.2x
/// and reported 34 cm for a viewer sitting at 75. So the app asks once instead,
/// and the answer absorbs the viewer's own pupil spacing along with the crop.
///
/// This runs on demand, never during the effect: the camera is in the lid and
/// is turned away while the lid closes, and the indicator light would be on
/// the whole time.
@MainActor
enum EyeMeasurement {

    /// Distance to a face times the pupil separation it shows, in
    /// millimetre-pixels. One number, standing in for the focal length of the
    /// delivered frame and the viewer's interpupillary distance together.
    typealias Calibration = Double

    struct Result {
        /// Perpendicular distance from the eye to the screen plane.
        var distanceMillimetres: Double
        /// How far above the screen centre the eye sits, in the screen plane.
        var heightAboveCentreMillimetres: Double
        /// Frames that held a face.
        var samples: Int
    }

    enum Failure: LocalizedError {
        case noCamera, denied, noFace, notCalibrated

        var errorDescription: String? {
            switch self {
            case .noCamera: return "No camera"
            case .denied: return "Camera access was refused. Turn it on under Privacy & Security."
            case .noFace: return "No face found. Sit facing the screen and try again."
            case .notCalibrated: return "Set the distance you are actually at, then calibrate."
            }
        }
    }

    /// Mean adult interpupillary distance. Used only to turn a calibrated
    /// distance into a height offset: an error here moves the height a little
    /// and the distance not at all.
    static let interpupillaryMillimetres: Double = 63

    /// Frames to look at. The median of these rejects a blink or a turn.
    private static let frameCount = 9

    /// One look, reporting the pupil separation in pixels of the delivered
    /// frame. Multiplying it by a known distance gives the calibration.
    static func pupilSeparation() async throws -> Double {
        let (separations, _, _) = try await samples()
        return median(separations)
    }

    static func measure(
        calibration: Calibration,
        screenHeightPoints: Double,
        millimetresPerPoint: Double
    ) async throws -> Result {
        guard calibration > 0 else { throw Failure.notCalibrated }
        let (separations, offsets, frames) = try await samples()

        var distances: [Double] = []
        var heights: [Double] = []
        // The focal length the calibration implies, needed for the height.
        let focal = calibration / interpupillaryMillimetres
        for (separation, offsetPixels) in zip(separations, offsets) {
            let distance = calibration / separation
            distances.append(distance)
            // The camera sits at the top of the lid, so the screen centre is
            // half a screen below its optical axis.
            heights.append(
                offsetPixels / focal * distance + screenHeightPoints / 2 * millimetresPerPoint
            )
        }
        Diagnostics.geometry.notice(
            "eye measurement: \(frames) frames, \(distances.count) with a face"
        )
        guard !distances.isEmpty else { throw Failure.noFace }
        return Result(
            distanceMillimetres: median(distances),
            heightAboveCentreMillimetres: median(heights),
            samples: distances.count
        )
    }

    /// Pupil separations, and how far the eyes sat above the frame centre,
    /// one entry per frame that held a face.
    private static func samples() async throws -> ([Double], [Double], Int) {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: break
        case .notDetermined:
            guard await AVCaptureDevice.requestAccess(for: .video) else { throw Failure.denied }
        default: throw Failure.denied
        }
        guard let device = AVCaptureDevice.default(for: .video) else { throw Failure.noCamera }

        let frames = try await Camera.frames(from: device, count: frameCount)
        var separations: [Double] = []
        var offsets: [Double] = []

        for buffer in frames {
            guard let face = try? detectFace(in: buffer),
                  let left = face.landmarks?.leftPupil?.normalizedPoints.first,
                  let right = face.landmarks?.rightPupil?.normalizedPoints.first else { continue }

            // Landmarks are normalised inside the face box; lift them to the
            // frame, then to pixels.
            let box = face.boundingBox
            let width = Double(CVPixelBufferGetWidth(buffer))
            let height = Double(CVPixelBufferGetHeight(buffer))
            func pixels(_ p: CGPoint) -> CGPoint {
                CGPoint(
                    x: (Double(box.origin.x) + Double(p.x) * Double(box.width)) * width,
                    y: (Double(box.origin.y) + Double(p.y) * Double(box.height)) * height
                )
            }
            let a = pixels(left)
            let b = pixels(right)
            let separation = hypot(a.x - b.x, a.y - b.y)
            guard separation > 1 else { continue }

            separations.append(Double(separation))
            offsets.append((Double(a.y) + Double(b.y)) / 2 - height / 2)
            Diagnostics.geometry.notice(
                """
                eye frame \(width, format: .fixed(precision: 0))x\(height, format: .fixed(precision: 0)) \
                separation \(Double(separation), format: .fixed(precision: 2)) px
                """
            )
        }
        guard !separations.isEmpty else { throw Failure.noFace }
        return (separations, offsets, frames.count)
    }

    private static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count % 2 == 0 ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
    }

    private static func detectFace(in buffer: CVPixelBuffer) throws -> VNFaceObservation? {
        let request = VNDetectFaceLandmarksRequest()
        try VNImageRequestHandler(cvPixelBuffer: buffer, options: [:]).perform([request])
        // The nearest face is the largest, which is the person using this Mac.
        return (request.results ?? []).max { $0.boundingBox.height < $1.boundingBox.height }
    }
}

/// Pulls a handful of frames and shuts the camera off again.
private final class Camera: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {

    private let session = AVCaptureSession()
    private var wanted = 0
    private var collected: [CVPixelBuffer] = []
    private var finish: ((Result<[CVPixelBuffer], Error>) -> Void)?
    private let lock = NSLock()

    static func frames(from device: AVCaptureDevice, count: Int) async throws -> [CVPixelBuffer] {
        let camera = Camera()
        return try await withCheckedThrowingContinuation { continuation in
            camera.start(device: device, count: count) { result in
                continuation.resume(with: result)
                withExtendedLifetime(camera) {}
            }
        }
    }

    private func start(
        device: AVCaptureDevice,
        count: Int,
        completion: @escaping (Result<[CVPixelBuffer], Error>) -> Void
    ) {
        wanted = count
        finish = completion
        do {
            session.beginConfiguration()
            let input = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(input) else { throw EyeMeasurement.Failure.noCamera }
            session.addInput(input)
            let output = AVCaptureVideoDataOutput()
            output.alwaysDiscardsLateVideoFrames = true
            output.setSampleBufferDelegate(self, queue: DispatchQueue(label: "MacDuo.eye"))
            guard session.canAddOutput(output) else { throw EyeMeasurement.Failure.noCamera }
            session.addOutput(output)
            session.commitConfiguration()
        } catch {
            deliver(.failure(error))
            return
        }
        DispatchQueue.global(qos: .userInitiated).async { [session] in session.startRunning() }
        // The camera has to wake and expose; give it a bounded wait.
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let frames = self.collected
            self.lock.unlock()
            self.deliver(frames.isEmpty ? .failure(EyeMeasurement.Failure.noFace) : .success(frames))
        }
    }

    private func deliver(_ result: Result<[CVPixelBuffer], Error>) {
        lock.lock()
        let callback = finish
        finish = nil
        lock.unlock()
        guard let callback else { return }
        if session.isRunning { session.stopRunning() }
        callback(result)
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        lock.lock()
        let enough = collected.count >= wanted
        if !enough { collected.append(pixels) }
        let frames = collected
        lock.unlock()
        if enough || frames.count >= wanted {
            DispatchQueue.main.async { [weak self] in self?.deliver(.success(frames)) }
        }
    }
}
