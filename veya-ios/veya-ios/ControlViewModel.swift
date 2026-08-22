import Combine
import AVFoundation
import Foundation
import SwiftUI

@MainActor
final class ControlViewModel: ObservableObject {
    @Published var espHost: String = UserDefaults.standard.string(forKey: "veya.espHost") ?? ""
    @Published var trackingMode: TrackingMode = .faceTracking
    @Published var motion: MotionSample = .zero
    @Published var heading: HeadingSample = .zero
    @Published var faceTracking: FaceTrackingSample = .zero
    @Published var autoHoldEnabled = false
    @Published var desiredHeadingDegrees: Double = 90
    @Published var desiredPitchDegrees: Double = 70
    @Published var panDirectionSign: Double = 1
    @Published var tiltDirectionSign: Double = 1
    @Published var connectionMessage = "Waiting for an ESP8266 address."
    @Published var calibrationMessage = "Not calibrated yet."
    @Published var faceErrorX: Double = 0
    @Published var faceErrorY: Double = 0
    @Published var headingErrorDegrees: Double = 0
    @Published var pitchErrorDegrees: Double = 0
    @Published var lastPanCommandDegrees: Double = 0
    @Published var lastTiltCommandDegrees: Double = 0
    @Published var lastFacePanCommandDegrees: Double = 0
    @Published var lastFaceTiltCommandDegrees: Double = 0
    @Published var faceSearchStatus: String = "Idle"
    @Published var filteredHeadingDegrees: Double = 0
    @Published var lastStatus: ESP8266Status?
    @Published var lastErrorMessage: String?
    @Published var isSending = false
    @Published var hasAutoCalibrated = false

    private let client = ESP8266Client()
    private let motionCoordinator = MotionCoordinator()
    private let headingCoordinator = HeadingCoordinator()
    private let faceTracker = FaceTrackingCoordinator()
    private let panCorrectionGain: Double = 0.14
    private let tiltCorrectionGain: Double = 0.12
    private let facePanCorrectionGain: Double = 0.55
    private let faceTiltCorrectionGain: Double = 0.50
    private let deadbandHeading: Double = 5.0
    private let deadbandPitch: Double = 5.0
    private let faceDeadband: Double = 0.18
    private let sendInterval: TimeInterval = 0.10
    private let faceSendInterval: TimeInterval = 0.08
    private let headingSmoothing: Double = 0.22
    private let faceSmoothing: Double = 0.30
    private let faceSearchPanRange: Double = 35
    private let faceSearchPanStep: Double = 6
    private let faceSearchStepInterval: TimeInterval = 0.9
    private let faceLostGracePeriod: TimeInterval = 0.35
    private let faceCenterHoldFrames = 3
    private let motor2PitchMinDegrees: Double = 0
    private let motor2PitchMaxDegrees: Double = 83
    private let motor2TestStepDegrees: Double = 5
    private var lastSendTime = Date.distantPast
    private var lastFaceSendTime = Date.distantPast
    private var lastFaceSeenTime = Date.distantPast
    private var faceSearchBasePanDegrees: Double = 0
    private var faceSearchBaseTiltDegrees: Double = 0
    private var faceSearchPanOffset: Double = 0
    private var faceSearchPanDirection: Double = 1
    private var faceSearchTiltTargetDegrees: Double = 0
    private var lastFaceSearchStepTime = Date.distantPast
    private var faceCenterStableCount = 0
    private var faceSearchInitialized = false
    private var pendingStartupCalibration = false
    private var filteredFaceX: Double = 0
    private var filteredFaceY: Double = 0

    var cameraSession: AVCaptureSession {
        faceTracker.session
    }

    init() {
        motionCoordinator.onUpdate = { [weak self] sample in
            self?.motion = sample
            self?.attemptTracking()
        }

        headingCoordinator.onUpdate = { [weak self] sample in
            self?.heading = sample
            self?.updateFilteredHeading(with: sample)
            self?.attemptTracking()
        }

        faceTracker.onUpdate = { [weak self] sample in
            self?.faceTracking = sample
            self?.updateFilteredFaceOffsets(with: sample)
            self?.attemptTracking()
        }

        motionCoordinator.start()
        headingCoordinator.start()
        faceTracker.start()

        if validatedHost != nil {
            pendingStartupCalibration = true
        }
    }

    func connect() {
        Task {
            await refreshStatus()
            await runStartupCalibrationIfNeeded()
        }
    }

    func refreshStatus() async {
        guard let host = validatedHost else {
            connectionMessage = "Enter the ESP8266 IP address first."
            return
        }

        UserDefaults.standard.set(host, forKey: "veya.espHost")

        do {
            let status = try await client.health(host: host)
            lastStatus = status
            lastErrorMessage = nil
            connectionMessage = "Connected to \(status.ip ?? host)"
            pendingStartupCalibration = true
        } catch {
            lastErrorMessage = error.localizedDescription
            connectionMessage = "Connection failed."
        }
    }

    func toggleAutoHold(_ enabled: Bool) {
        autoHoldEnabled = enabled
        if enabled {
            connectionMessage = "Auto hold enabled."
            attemptTracking()
        } else {
            connectionMessage = "Auto hold paused."
        }
    }

    func setTrackingMode(_ mode: TrackingMode) {
        trackingMode = mode
        connectionMessage = mode == .faceTracking ? "Face tracking active." : "North/up hold active."
        attemptTracking()
    }

    func resetNorthAndUpDefaults() {
        desiredHeadingDegrees = 90
        desiredPitchDegrees = 70
        calibrationMessage = "Target reset to north + slight up."
    }

    func captureCurrentPose() {
        desiredHeadingDegrees = currentHeadingDegrees
        desiredPitchDegrees = clampPitch(motion.pitchDegrees)
        calibrationMessage = "Captured current pose as the hold target."
    }

    func calibrateMotorPolarity() {
        Task {
            await runPolarityCalibration()
        }
    }

    func pitchUpTest() {
        Task {
            await jogMotor2TowardMin()
        }
    }

    func pitchDownTest() {
        Task {
            await jogMotor2TowardMax()
        }
    }

    func runStartupCalibrationIfNeeded() async {
        guard pendingStartupCalibration else { return }
        guard validatedHost != nil else { return }
        pendingStartupCalibration = false
        await runPolarityCalibration()
    }

    private var validatedHost: String? {
        let trimmed = espHost.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private var currentHeadingDegrees: Double {
        guard heading.isAvailable else { return 0 }
        return heading.headingDegrees
    }

    private func updateFilteredFaceOffsets(with sample: FaceTrackingSample) {
        guard sample.isAvailable, sample.faceDetected else {
            filteredFaceX = 0
            filteredFaceY = 0
            return
        }

        if filteredFaceX == 0 && filteredFaceY == 0 {
            filteredFaceX = sample.xOffset
            filteredFaceY = sample.yOffset
            return
        }

        filteredFaceX = filteredFaceX + (sample.xOffset - filteredFaceX) * faceSmoothing
        filteredFaceY = filteredFaceY + (sample.yOffset - filteredFaceY) * faceSmoothing
    }

    private func updateFilteredHeading(with sample: HeadingSample) {
        guard sample.isAvailable else { return }

        if filteredHeadingDegrees == 0 && heading.headingDegrees == 0 {
            filteredHeadingDegrees = sample.headingDegrees
            return
        }

        let current = filteredHeadingDegrees
        let delta = normalizeAngleDegrees(sample.headingDegrees - current)
        filteredHeadingDegrees = current + delta * headingSmoothing
    }

    private func attemptTracking() {
        switch trackingMode {
        case .faceTracking:
            attemptFaceTracking()
        case .northHold:
            attemptAutoHold()
        }
    }

    private func attemptAutoHold() {
        guard trackingMode == .northHold else { return }
        guard autoHoldEnabled else { return }
        guard !isSending else { return }
        guard let host = validatedHost else { return }
        guard motion.isAvailable, heading.isAvailable else { return }

        let headingError = normalizeAngleDegrees(desiredHeadingDegrees - currentHeadingDegrees)
        let pitchError = desiredPitchDegrees - motion.pitchDegrees
        headingErrorDegrees = headingError
        pitchErrorDegrees = pitchError

        if abs(headingError) < deadbandHeading, abs(pitchError) < deadbandPitch {
            connectionMessage = "Holding target."
            return
        }

        let now = Date()
        guard now.timeIntervalSince(lastSendTime) >= sendInterval else { return }

        let deltaMotor1 = panDirectionSign * headingError * panCorrectionGain
        let deltaMotor2 = limitedMotor2Delta(desiredDelta: tiltDirectionSign * pitchError * tiltCorrectionGain)

        let clippedMotor1 = clamp(deltaMotor1, min: -4.0, max: 4.0)
        let clippedMotor2 = clamp(deltaMotor2, min: -4.0, max: 4.0)
        lastPanCommandDegrees = clippedMotor1
        lastTiltCommandDegrees = clippedMotor2

        guard abs(clippedMotor1) >= 0.05 || abs(clippedMotor2) >= 0.05 else { return }

        lastSendTime = now
        Task {
            await sendJog(host: host, deltaMotor1: clippedMotor1, deltaMotor2: clippedMotor2, message: "Auto correcting.")
        }
    }

    private func attemptFaceTracking() {
        guard trackingMode == .faceTracking else { return }
        guard !isSending else { return }
        guard let host = validatedHost else { return }
        guard faceTracking.isAvailable else { return }

        let now = Date()
        if faceTracking.faceDetected {
            lastFaceSeenTime = now
            faceSearchStatus = "Tracking face"
            faceSearchInitialized = false

            guard now.timeIntervalSince(lastFaceSendTime) >= faceSendInterval else { return }

            let xError = faceTracking.xOffset
            let yError = faceTracking.yOffset
            faceErrorX = xError
            faceErrorY = yError

            if abs(xError) < faceDeadband, abs(yError) < faceDeadband {
                faceCenterStableCount += 1
                if faceCenterStableCount >= faceCenterHoldFrames {
                    connectionMessage = "Holding face center."
                    lastFacePanCommandDegrees = 0
                    lastFaceTiltCommandDegrees = 0
                }
                return
            }

            faceCenterStableCount = 0

            // Negative sign keeps the camera moving toward the face center.
            let deltaMotor1 = -xError * facePanCorrectionGain * panDirectionSign
            let deltaMotor2 = limitedMotor2Delta(desiredDelta: -yError * faceTiltCorrectionGain * tiltDirectionSign)
            let clippedMotor1 = clamp(deltaMotor1, min: -1.2, max: 1.2)
            let clippedMotor2 = clamp(deltaMotor2, min: -1.2, max: 1.2)
            lastFacePanCommandDegrees = clippedMotor1
            lastFaceTiltCommandDegrees = clippedMotor2

            guard abs(clippedMotor1) >= 0.02 || abs(clippedMotor2) >= 0.02 else { return }

            lastFaceSendTime = now
            Task {
                await sendJog(host: host, deltaMotor1: clippedMotor1, deltaMotor2: clippedMotor2, message: "Tracking face.")
            }
            return
        }

        faceErrorX = 0
        faceErrorY = 0
        lastFacePanCommandDegrees = 0
        lastFaceTiltCommandDegrees = 0
        faceCenterStableCount = 0

        guard now.timeIntervalSince(lastFaceSeenTime) >= faceLostGracePeriod else {
            faceSearchStatus = "Brief face loss"
            connectionMessage = "Face briefly lost."
            return
        }

        runFaceSearch(host: host, now: now)
    }

    private func runFaceSearch(host: String, now: Date) {
        if !faceSearchInitialized || faceSearchStatus == "Tracking face" {
            faceSearchBasePanDegrees = currentHeadingDegrees
            faceSearchBaseTiltDegrees = clampPitch(motion.pitchDegrees)
            faceSearchPanOffset = -faceSearchPanRange
            faceSearchPanDirection = 1
            faceSearchTiltTargetDegrees = faceSearchBaseTiltDegrees
            faceSearchStatus = "Searching face"
            faceSearchInitialized = true

            lastFaceSearchStepTime = now
            Task {
                await sendMove(
                    host: host,
                    motor1: faceSearchBasePanDegrees + faceSearchPanOffset,
                    motor2: faceSearchTiltTargetDegrees,
                    message: "Searching face."
                )
            }
            return
        }

        guard now.timeIntervalSince(lastFaceSearchStepTime) >= faceSearchStepInterval else { return }
        lastFaceSearchStepTime = now

        let liveTiltTarget = clampPitch(motion.pitchDegrees)
        faceSearchTiltTargetDegrees = liveTiltTarget

        faceSearchPanOffset += faceSearchPanDirection * faceSearchPanStep

        if faceSearchPanOffset >= faceSearchPanRange {
            faceSearchPanOffset = faceSearchPanRange
            faceSearchPanDirection = -1
        } else if faceSearchPanOffset <= -faceSearchPanRange {
            faceSearchPanOffset = -faceSearchPanRange
            faceSearchPanDirection = 1
        }

        faceSearchStatus = "Searching face: pan sweep at phone pitch"
        Task {
            await sendMove(
                host: host,
                motor1: faceSearchBasePanDegrees + faceSearchPanOffset,
                motor2: liveTiltTarget,
                message: "Searching face."
            )
        }
    }

    private func sendJog(host: String, deltaMotor1: Double, deltaMotor2: Double, message: String) async {
        do {
            isSending = true
            let boundedDelta2 = limitedMotor2Delta(desiredDelta: deltaMotor2)
            let status = try await client.jog(host: host, delta1: deltaMotor1, delta2: boundedDelta2)
            lastStatus = status
            lastErrorMessage = nil
            connectionMessage = message
        } catch {
            lastErrorMessage = error.localizedDescription
            connectionMessage = "Command failed."
        }

        isSending = false
    }

    private func sendMove(host: String, motor1: Double, motor2: Double, message: String) async {
        do {
            isSending = true
            let status = try await client.move(host: host, motor1: motor1, motor2: clampPitch(motor2))
            lastStatus = status
            lastErrorMessage = nil
            connectionMessage = message
        } catch {
            lastErrorMessage = error.localizedDescription
            connectionMessage = "Command failed."
        }

        isSending = false
    }

    private func runPolarityCalibration() async {
        guard let host = validatedHost else {
            connectionMessage = "Enter the ESP8266 IP address first."
            return
        }

        let wasEnabled = autoHoldEnabled
        autoHoldEnabled = false

        calibrationMessage = "Calibrating motor 1..."
        let panSign = await calibrateAxis(
            host: host,
            motor1Delta: 8,
            motor2Delta: 0,
            expectedSensorDelta: {
                normalizeAngleDegrees(self.currentHeadingDegrees - $0)
            }
        )

        if let panSign {
            panDirectionSign = panSign
        }

        calibrationMessage = "Calibrating motor 2..."
        let tiltSign = await calibrateMotor2PitchSign(host: host)

        if let tiltSign {
            tiltDirectionSign = tiltSign
        }

        calibrationMessage = "Direction calibration complete."
        if wasEnabled {
            autoHoldEnabled = true
            attemptTracking()
        }

        hasAutoCalibrated = true
    }

    private func calibrateMotor2PitchSign(host: String) async -> Double? {
        let baselinePitch = motion.pitchDegrees

        do {
            isSending = true
            let probeDelta: Double = 8

            _ = try await client.jog(host: host, delta1: 0, delta2: probeDelta)
            try await Task.sleep(nanoseconds: 1_000_000_000)

            let pitchAfterPositiveMove = motion.pitchDegrees
            let positiveDelta = pitchAfterPositiveMove - baselinePitch

            _ = try await client.jog(host: host, delta1: 0, delta2: -2 * probeDelta)
            try await Task.sleep(nanoseconds: 600_000_000)

            let pitchAfterNegativeMove = motion.pitchDegrees
            let negativeDelta = pitchAfterNegativeMove - baselinePitch

            _ = try await client.jog(host: host, delta1: 0, delta2: probeDelta)
            try await Task.sleep(nanoseconds: 600_000_000)

            let sign: Double
            if abs(positiveDelta) >= abs(negativeDelta), abs(positiveDelta) > 0.5 {
                sign = positiveDelta > 0 ? 1 : -1
                let direction = positiveDelta > 0 ? "increased" : "decreased"
                calibrationMessage = String(
                    format: "Motor 2 +%.0f° %@ pitch by %.1f°. Then -%.0f° changed it by %.1f°.",
                    probeDelta,
                    direction,
                    abs(positiveDelta),
                    probeDelta,
                    negativeDelta
                )
            } else if abs(negativeDelta) > 0.5 {
                sign = negativeDelta > 0 ? -1 : 1
                let direction = negativeDelta > 0 ? "increased" : "decreased"
                calibrationMessage = String(
                    format: "Motor 2 -%.0f° %@ pitch by %.1f°.",
                    probeDelta,
                    direction,
                    abs(negativeDelta)
                )
            } else {
                sign = 0
                calibrationMessage = "Motor 2 pitch change was too small to measure."
            }

            isSending = false
            return sign == 0 ? nil : sign
        } catch {
            isSending = false
            lastErrorMessage = error.localizedDescription
            calibrationMessage = "Motor 2 calibration failed."
            return nil
        }
    }

    private func calibrateAxis(
        host: String,
        motor1Delta: Double,
        motor2Delta: Double,
        expectedSensorDelta: @escaping (Double) -> Double
    ) async -> Double? {
        let baseline = motor1Delta != 0 ? currentHeadingDegrees : motion.pitchDegrees

        do {
            isSending = true
            _ = try await client.jog(host: host, delta1: motor1Delta, delta2: motor2Delta)
            try await Task.sleep(nanoseconds: 1_000_000_000)

            let delta = expectedSensorDelta(baseline)
            let sign: Double
            if delta > 0.5 {
                sign = 1
            } else if delta < -0.5 {
                sign = -1
            } else {
                sign = 0
            }

            if motor1Delta != 0 {
                _ = try await client.jog(host: host, delta1: -motor1Delta, delta2: 0)
            } else {
                _ = try await client.jog(host: host, delta1: 0, delta2: limitedMotor2Delta(desiredDelta: -motor2Delta))
            }

            try await Task.sleep(nanoseconds: 600_000_000)
            isSending = false
            return sign == 0 ? nil : sign
        } catch {
            isSending = false
            lastErrorMessage = error.localizedDescription
            calibrationMessage = "Calibration failed."
            return nil
        }
    }

    private func clampPitch(_ value: Double) -> Double {
        clamp(value, min: motor2PitchMinDegrees, max: motor2PitchMaxDegrees)
    }

    private func limitedMotor2Delta(desiredDelta: Double) -> Double {
        return limitedMotor2Delta(from: motion.pitchDegrees, desiredDelta: desiredDelta)
    }

    private func limitedMotor2Delta(from current: Double, desiredDelta: Double) -> Double {
        let target = clampPitch(current + desiredDelta)
        return target - current
    }

    private func jogMotor2TowardMin() async {
        guard let host = validatedHost else {
            connectionMessage = "Enter the ESP8266 IP address first."
            return
        }

        let current = motion.pitchDegrees
        let target = clampPitch(current - motor2TestStepDegrees)
        let delta = target - current

        guard abs(delta) > 0.001 else {
            connectionMessage = "Motor 2 already at lower limit."
            return
        }

        await sendJog(host: host, deltaMotor1: 0, deltaMotor2: delta, message: "Pitch moved toward 0°.")
    }

    private func jogMotor2TowardMax() async {
        guard let host = validatedHost else {
            connectionMessage = "Enter the ESP8266 IP address first."
            return
        }

        let current = motion.pitchDegrees
        let target = clampPitch(current + motor2TestStepDegrees)
        let delta = target - current

        guard abs(delta) > 0.001 else {
            connectionMessage = "Motor 2 already at upper limit."
            return
        }

        await sendJog(host: host, deltaMotor1: 0, deltaMotor2: delta, message: "Pitch moved toward 83°.")
    }
}
