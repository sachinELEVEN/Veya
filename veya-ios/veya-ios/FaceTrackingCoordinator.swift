import AVFoundation
import Foundation
import Vision
import UIKit

final class FaceTrackingCoordinator: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    var onUpdate: ((FaceTrackingSample) -> Void)?

    let session = AVCaptureSession()

    private let sessionQueue = DispatchQueue(label: "veya.faceTracking.session")
    private let visionQueue = DispatchQueue(label: "veya.faceTracking.vision")
    private let sequenceHandler = VNSequenceRequestHandler()
    private var isConfigured = false
    private var isRunningRequested = false
    private var latestSample = FaceTrackingSample.zero

    func start() {
        isRunningRequested = true

        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            configureAndStartIfNeeded()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                guard let self else { return }
                if granted {
                    self.configureAndStartIfNeeded()
                } else {
                    self.publishUnavailable("Camera permission denied.")
                }
            }
        default:
            publishUnavailable("Camera permission denied.")
        }
    }

    func stop() {
        isRunningRequested = false
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if self.session.isRunning {
                self.session.stopRunning()
            }
        }
    }

    private func configureAndStartIfNeeded() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if !self.isConfigured {
                self.configureSession()
            }

            guard self.isRunningRequested, !self.session.isRunning else { return }
            self.session.startRunning()
        }
    }

    private func configureSession() {
        session.beginConfiguration()
        session.sessionPreset = .high

        defer {
            session.commitConfiguration()
            isConfigured = true
        }

        guard let camera = preferredFrontCamera(),
              let input = try? AVCaptureDeviceInput(device: camera),
              session.canAddInput(input) else {
            publishUnavailable("Front camera unavailable.")
            return
        }

        session.inputs.forEach { session.removeInput($0) }
        session.outputs.forEach { session.removeOutput($0) }

        session.addInput(input)

        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.setSampleBufferDelegate(self, queue: visionQueue)

        guard session.canAddOutput(output) else {
            publishUnavailable("Could not add camera output.")
            return
        }

        session.addOutput(output)

        if let connection = output.connection(with: .video) {
            connection.videoOrientation = .portrait
            connection.isVideoMirrored = true
        }
    }

    private func preferredFrontCamera() -> AVCaptureDevice? {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [
                .builtInUltraWideCamera,
                .builtInTrueDepthCamera,
                .builtInWideAngleCamera
            ],
            mediaType: .video,
            position: .front
        )

        return discovery.devices.first
    }

    private func publishUnavailable(_ message: String) {
        latestSample = FaceTrackingSample(faceDetected: false, xOffset: 0, yOffset: 0, faceWidth: 0, isAvailable: false, timestamp: .now)
        DispatchQueue.main.async { [weak self] in
            self?.onUpdate?(self?.latestSample ?? .zero)
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let request = VNDetectFaceRectanglesRequest()

        do {
            try sequenceHandler.perform([request], on: sampleBuffer, orientation: currentOrientation())
            let faces = request.results ?? []
            process(faces: faces)
        } catch {
            publishUnavailable("Face detection failed.")
        }
    }

    private func process(faces: [VNFaceObservation]) {
        guard let face = faces.max(by: { lhs, rhs in
            lhs.boundingBox.width * lhs.boundingBox.height < rhs.boundingBox.width * rhs.boundingBox.height
        }) else {
            latestSample = FaceTrackingSample(faceDetected: false, xOffset: 0, yOffset: 0, faceWidth: 0, isAvailable: true, timestamp: .now)
            DispatchQueue.main.async { [weak self] in
                self?.onUpdate?(self?.latestSample ?? .zero)
            }
            return
        }

        let centerX = face.boundingBox.midX
        let centerY = face.boundingBox.midY

        let sample = FaceTrackingSample(
            faceDetected: true,
            xOffset: (centerX - 0.5) * 2.0,
            yOffset: (centerY - 0.5) * 2.0,
            faceWidth: face.boundingBox.width,
            isAvailable: true,
            timestamp: .now
        )

        latestSample = sample
        DispatchQueue.main.async { [weak self] in
            self?.onUpdate?(sample)
        }
    }

    private func currentOrientation() -> CGImagePropertyOrientation {
        switch UIDevice.current.orientation {
        case .portraitUpsideDown:
            return .leftMirrored
        case .landscapeLeft:
            return .upMirrored
        case .landscapeRight:
            return .downMirrored
        default:
            return .rightMirrored
        }
    }
}
