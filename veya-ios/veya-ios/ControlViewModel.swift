import Combine
import AVFoundation
import Foundation
import OSLog
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
    private let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "veya-ios", category: "ControlViewModel")
    private let motionCoordinator = MotionCoordinator()
    private let headingCoordinator = HeadingCoordinator()
    private let faceTracker = FaceTrackingCoordinator()
    private let panCorrectionGain: Double = 0.14
    private let tiltCorrectionGain: Double = 0.12
    private let facePanCorrectionGain: Double = 0.55
    private let faceTiltCorrectionGain: Double = 0.50
    private let deadbandHeading: Double = 5.0
    private let deadbandPitch: Double = 5.0
    private let faceDeadband: Double = 0.22
    private let faceLockedPanMoveThreshold: Double = 0.12
    private let faceLockedPitchMoveThreshold: Double = 0.30
    private let sendInterval: TimeInterval = 0.10
    private let faceSendInterval: TimeInterval = 0.08
    private let headingSmoothing: Double = 0.22
    private let faceSmoothing: Double = 0.30
    private let faceSearchPanRange: Double = 135
    private let faceSearchPanSpeedDegreesPerSecond: Double = 30
    private let faceSearchLoopTick: UInt64 = 50_000_000
    private let faceSearchRetryInterval: TimeInterval = 5.0
    private let faceLostGracePeriod: TimeInterval = 5
    private let faceSearchInitialPanStepMinDegrees: Double = 4
    private let faceSearchInitialPanStepMaxDegrees: Double = 18
    private let faceSearchInitialPanBiasMultiplier: Double = 12
    private let faceCenterHoldFrames = 3
    private let motor2PitchMinDegrees: Double = 0
    private let motor2PitchMaxDegrees: Double = 83
    private let motor1TestStepDegrees: Double = 5
    private let motor2TestStepDegrees: Double = 5
    private var lastSendTime = Date.distantPast
    private var lastFaceSendTime = Date.distantPast
    private var lastFaceSeenTime = Date.distantPast
    private var faceSearchPanOffset: Double = 0
    private var faceSearchPanDirection: Double = 1
    private var faceSearchTiltTargetDegrees: Double = 0
    private var faceSearchLegsCompleted: Int = 0
    private var faceCenterStableCount = 0
    private var faceSearchInitialized = false
    private var faceSearchLoopTask: Task<Void, Never>?
    private var faceLockedOnTarget = false
    private var lastFaceLockXOffset: Double = 0
    private var lastFaceLockYOffset: Double = 0
    private var lastFaceXMotionDelta: Double = 0
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

    func panLeftTest() {
        Task {
            await jogMotor1TowardLeft()
        }
    }

    func panRightTest() {
        Task {
            await jogMotor1TowardRight()
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
        guard hasAutoCalibrated else {
            connectionMessage = "Calibrating first..."
            return
        }
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
        guard let host = validatedHost else { return }
        guard faceTracking.isAvailable else { return }
        guard hasAutoCalibrated else {
            faceSearchStatus = "Calibrating first..."
            connectionMessage = "Calibrating first..."
            return
        }

        let now = Date()
        log.debug("Face tick detected=\(self.faceTracking.faceDetected, privacy: .public) sending=\(self.isSending, privacy: .public) searchInit=\(self.faceSearchInitialized, privacy: .public) locked=\(self.faceLockedOnTarget, privacy: .public) status=\(self.faceSearchStatus, privacy: .public)")
        if faceTracking.faceDetected {
            lastFaceSeenTime = now
            faceSearchStatus = "Face found"
            stopFaceSearchLoop()

            let sinceLastFaceSend = now.timeIntervalSince(lastFaceSendTime)
            guard sinceLastFaceSend >= faceSendInterval else {
                log.debug("Face move skipped by send interval elapsed=\(sinceLastFaceSend, privacy: .public)s wait=\(self.faceSendInterval, privacy: .public)s")
                return
            }

            let xError = faceTracking.xOffset
            let yError = faceTracking.yOffset
            faceErrorX = xError
            faceErrorY = yError

            let faceMotionX = xError - lastFaceLockXOffset
            if abs(faceMotionX) > 0.02 {
                lastFaceXMotionDelta = faceMotionX
            }

            let panMovedEnough = abs(xError - lastFaceLockXOffset) > faceLockedPanMoveThreshold
            let pitchMovedEnough = abs(yError - lastFaceLockYOffset) > faceLockedPitchMoveThreshold
            let faceMovedEnough = panMovedEnough || pitchMovedEnough

            if faceLockedOnTarget, !faceMovedEnough {
                log.debug("Face locked, below movement threshold x=\(xError, privacy: .public) y=\(yError, privacy: .public) lastX=\(self.lastFaceLockXOffset, privacy: .public) lastY=\(self.lastFaceLockYOffset, privacy: .public)")
                return
            }

            faceLockedOnTarget = true
            faceSearchInitialized = false
            lastFaceLockXOffset = xError
            lastFaceLockYOffset = yError

            let coarseX = clamp(xError, min: -0.65, max: 0.65)
            let coarseY = pitchMovedEnough || !faceLockedOnTarget ? clamp(yError, min: -0.45, max: 0.45) : 0
            let deltaMotor1 = -coarseX * facePanCorrectionGain * panDirectionSign
            let deltaMotor2 = limitedMotor2Delta(desiredDelta: -coarseY * faceTiltCorrectionGain * tiltDirectionSign)
            let clippedMotor1 = clamp(deltaMotor1, min: -3.0, max: 3.0)
            let clippedMotor2 = clamp(deltaMotor2, min: -2.5, max: 2.5)
            lastFacePanCommandDegrees = clippedMotor1
            lastFaceTiltCommandDegrees = clippedMotor2
            log.debug("Face command x=\(xError, privacy: .public) y=\(yError, privacy: .public) coarseX=\(coarseX, privacy: .public) coarseY=\(coarseY, privacy: .public) d1=\(clippedMotor1, privacy: .public) d2=\(clippedMotor2, privacy: .public)")

            guard abs(clippedMotor1) >= faceDeadband || abs(clippedMotor2) >= faceDeadband else {
                log.debug("Face command suppressed below threshold.")
                connectionMessage = "Face found. Holding."
                return
            }

            lastFaceSendTime = now
            log.debug("Face command sending.")
            Task {
                await sendJog(host: host, deltaMotor1: clippedMotor1, deltaMotor2: clippedMotor2, message: "Face found. Holding.")
            }
            return
        }

        faceErrorX = 0
        faceErrorY = 0
        lastFacePanCommandDegrees = 0
        lastFaceTiltCommandDegrees = 0
        faceCenterStableCount = 0
        lastFaceLockXOffset = 0
        lastFaceLockYOffset = 0
        log.debug("Face not detected; lastSeenAge=\(now.timeIntervalSince(self.lastFaceSeenTime), privacy: .public)s")

        guard now.timeIntervalSince(lastFaceSeenTime) >= faceLostGracePeriod else {
            faceSearchStatus = "Face briefly lost; holding."
            connectionMessage = "Face briefly lost; holding."
            log.debug("Face briefly lost; still within grace period.")
            return
        }

        faceLockedOnTarget = false
        startFaceSearchLoop(host: host)
    }

    private func startFaceSearchLoop(host: String) {
        guard faceSearchLoopTask == nil else {
            return
        }

        faceSearchLoopTask = Task { [weak self] in
            guard let self else { return }
            await self.runFaceSearchLoop(host: host)
        }
    }

    private func stopFaceSearchLoop() {
        faceSearchLoopTask?.cancel()
        faceSearchLoopTask = nil
    }

    private func runFaceSearchLoop(host: String) async {
        if !faceSearchInitialized {
            let initialSearch = faceSearchStartupBias()
            faceSearchPanOffset = initialSearch.panDelta
            faceSearchPanDirection = initialSearch.direction
            faceSearchLegsCompleted = 0
            faceSearchTiltTargetDegrees = clampPitch(70)
            faceSearchStatus = "Searching face at 70°"
            faceSearchInitialized = true
            let initialTiltDelta = limitedMotor2Delta(
                from: motion.pitchDegrees,
                desiredDelta: faceSearchTiltTargetDegrees - motion.pitchDegrees
            )
            log.debug("Face search init tiltDelta=\(initialTiltDelta, privacy: .public) panDelta=\(initialSearch.panDelta, privacy: .public) panDir=\(self.faceSearchPanDirection, privacy: .public) lastFaceXMotion=\(self.lastFaceXMotionDelta, privacy: .public) lastFaceX=\(self.lastFaceLockXOffset, privacy: .public)")
            if abs(initialSearch.panDelta) >= 0.05 || abs(initialTiltDelta) >= 0.05 {
                await sendJog(
                    host: host,
                    deltaMotor1: initialSearch.panDelta,
                    deltaMotor2: initialTiltDelta,
                    message: "Searching face."
                )
            }
        }

        let tickSeconds = Double(faceSearchLoopTick) / 1_000_000_000.0

        while !Task.isCancelled {
            guard trackingMode == .faceTracking else { break }
            guard !faceTracking.faceDetected else { break }

            try? await Task.sleep(nanoseconds: faceSearchLoopTick)
            guard !Task.isCancelled else { break }
            guard !faceTracking.faceDetected else { break }

            let step = faceSearchPanDirection * faceSearchPanSpeedDegreesPerSecond * tickSeconds
            var nextOffset = faceSearchPanOffset + step

            if nextOffset >= faceSearchPanRange {
                nextOffset = faceSearchPanRange
                faceSearchPanDirection = -1
                faceSearchLegsCompleted += 1
            } else if nextOffset <= -faceSearchPanRange {
                nextOffset = -faceSearchPanRange
                faceSearchPanDirection = 1
                faceSearchLegsCompleted += 1
            }

            let appliedStep = nextOffset - faceSearchPanOffset
            faceSearchPanOffset = nextOffset
            faceSearchTiltTargetDegrees = clampPitch(70)
            faceSearchStatus = "Searching face: sweeping at 70°"
            log.debug("Face search sweep step=\(appliedStep, privacy: .public) targetTilt=\(self.faceSearchTiltTargetDegrees, privacy: .public) panOffset=\(self.faceSearchPanOffset, privacy: .public) panDir=\(self.faceSearchPanDirection, privacy: .public)")

            await sendJog(
                host: host,
                deltaMotor1: appliedStep,
                deltaMotor2: 0,
                message: "Searching face."
            )

            guard faceSearchLegsCompleted >= 2 else {
                continue
            }

            faceSearchLegsCompleted = 0
            faceSearchStatus = "No face found. Retrying in 5s."
            log.debug("Face search sweep completed without a face; waiting \(self.faceSearchRetryInterval, privacy: .public)s before retry.")

            var remainingDelay = faceSearchRetryInterval
            while remainingDelay > 0, !Task.isCancelled {
                if faceTracking.faceDetected || trackingMode != .faceTracking {
                    break
                }

                let chunk = min(1.0, remainingDelay)
                try? await Task.sleep(nanoseconds: UInt64(chunk * 1_000_000_000))
                remainingDelay -= chunk
            }

            guard !Task.isCancelled else { break }
            guard trackingMode == .faceTracking else { break }
            guard !faceTracking.faceDetected else { break }

            let retrySearch = faceSearchStartupBias()
            faceSearchPanOffset = retrySearch.panDelta
            faceSearchPanDirection = retrySearch.direction
            faceSearchTiltTargetDegrees = clampPitch(70)
            faceSearchStatus = "Retrying face search at 70°"
            let retryTiltDelta = limitedMotor2Delta(
                from: motion.pitchDegrees,
                desiredDelta: faceSearchTiltTargetDegrees - motion.pitchDegrees
            )
            log.debug("Face search retrying tiltDelta=\(retryTiltDelta, privacy: .public) panDelta=\(retrySearch.panDelta, privacy: .public) panDir=\(self.faceSearchPanDirection, privacy: .public) lastFaceXMotion=\(self.lastFaceXMotionDelta, privacy: .public) lastFaceX=\(self.lastFaceLockXOffset, privacy: .public)")
            if abs(retrySearch.panDelta) >= 0.05 || abs(retryTiltDelta) >= 0.05 {
                await sendJog(
                    host: host,
                    deltaMotor1: retrySearch.panDelta,
                    deltaMotor2: retryTiltDelta,
                    message: "Searching face."
                )
            }
        }

        if !Task.isCancelled {
            log.debug("Face search loop ended.")
        }

        faceSearchLoopTask = nil
    }

    private func sendJog(host: String, deltaMotor1: Double, deltaMotor2: Double, message: String) async {
        do {
            isSending = true
            let boundedDelta2 = limitedMotor2Delta(desiredDelta: deltaMotor2)
            log.debug("sendJog start host=\(host, privacy: .public) d1=\(deltaMotor1, privacy: .public) d2=\(deltaMotor2, privacy: .public) boundedD2=\(boundedDelta2, privacy: .public)")
            let status = try await client.jog(host: host, delta1: deltaMotor1, delta2: boundedDelta2)
            lastStatus = status
            lastErrorMessage = nil
            connectionMessage = message
            log.debug("sendJog success message=\(message, privacy: .public) status=\(status.message, privacy: .public)")
        } catch {
            lastErrorMessage = error.localizedDescription
            connectionMessage = "Command failed."
            log.debug("sendJog failed error=\(error.localizedDescription, privacy: .public)")
        }

        isSending = false
    }

    private func faceSearchStartupBias() -> (panDelta: Double, direction: Double) {
        let direction: Double
        if abs(lastFaceXMotionDelta) > 0.02 {
            direction = lastFaceXMotionDelta > 0 ? 1 : -1
        } else if abs(lastFaceLockXOffset) > 0.02 {
            direction = lastFaceLockXOffset > 0 ? 1 : -1
        } else {
            direction = 1
        }

        let magnitude = clamp(
            abs(lastFaceLockXOffset) * faceSearchInitialPanBiasMultiplier,
            min: faceSearchInitialPanStepMinDegrees,
            max: faceSearchInitialPanStepMaxDegrees
        )

        return (panDelta: direction * magnitude, direction: direction)
    }

    private func runPolarityCalibration() async {
        guard let host = validatedHost else {
            connectionMessage = "Enter the ESP8266 IP address first."
            return
        }

        let wasEnabled = autoHoldEnabled
        autoHoldEnabled = false
        hasAutoCalibrated = false

        calibrationMessage = "Calibrating motor 1..."
        let panSign = await calibrateMotor1PanSign(host: host)

        if let panSign {
            panDirectionSign = -panSign
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

    private func calibrateMotor1PanSign(host: String) async -> Double? {
        guard heading.isAvailable else {
            calibrationMessage = "Heading sensor unavailable."
            return nil
        }

        let probeDelta: Double = 10
        let settleDelay: UInt64 = 900_000_000
        let restoreDelay: UInt64 = 600_000_000

        do {
            isSending = true

            while heading.accuracyDegrees < 0 || heading.accuracyDegrees > 25 {
                try await Task.sleep(nanoseconds: 200_000_000)
            }

            let baselineHeading = currentHeadingDegrees
            calibrationMessage = "Motor 1 test: nudging clockwise/anticlockwise..."
            log.debug("Motor 1 calibration baseline heading=\(baselineHeading, privacy: .public) accuracy=\(self.heading.accuracyDegrees, privacy: .public)")

            _ = try await client.jog(host: host, delta1: probeDelta, delta2: 0)
            try await Task.sleep(nanoseconds: settleDelay)

            let headingAfterPositiveMove = currentHeadingDegrees
            let positiveDelta = normalizeAngleDegrees(headingAfterPositiveMove - baselineHeading)

            _ = try await client.jog(host: host, delta1: -2 * probeDelta, delta2: 0)
            try await Task.sleep(nanoseconds: settleDelay)

            let headingAfterNegativeMove = currentHeadingDegrees
            let negativeDelta = normalizeAngleDegrees(headingAfterNegativeMove - baselineHeading)

            _ = try await client.jog(host: host, delta1: probeDelta, delta2: 0)
            try await Task.sleep(nanoseconds: restoreDelay)

            let sign: Double
            if abs(positiveDelta) >= abs(negativeDelta), abs(positiveDelta) > 0.5 {
                sign = positiveDelta > 0 ? 1 : -1
                let direction = positiveDelta > 0 ? "clockwise/right" : "anticlockwise/left"
                calibrationMessage = String(
                    format: "Motor 1 +%.0f° moved %@ by %.1f°.",
                    probeDelta,
                    direction,
                    abs(positiveDelta)
                )
            } else if abs(negativeDelta) > 0.5 {
                sign = negativeDelta > 0 ? -1 : 1
                let direction = negativeDelta > 0 ? "clockwise/right" : "anticlockwise/left"
                calibrationMessage = String(
                    format: "Motor 1 -%.0f° moved %@ by %.1f°.",
                    probeDelta,
                    direction,
                    abs(negativeDelta)
                )
            } else {
                sign = 0
                calibrationMessage = "Motor 1 heading change was too small to measure."
            }

            log.debug("Motor 1 calibration positiveDelta=\(positiveDelta, privacy: .public) negativeDelta=\(negativeDelta, privacy: .public) sign=\(sign, privacy: .public)")
            isSending = false
            return sign == 0 ? nil : sign
        } catch {
            isSending = false
            lastErrorMessage = error.localizedDescription
            calibrationMessage = "Motor 1 calibration failed."
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

    private func jogMotor1TowardLeft() async {
        guard let host = validatedHost else {
            connectionMessage = "Enter the ESP8266 IP address first."
            return
        }
        guard heading.isAvailable else {
            connectionMessage = "Heading sensor unavailable."
            return
        }

        let delta = -panDirectionSign * motor1TestStepDegrees
        await sendJog(host: host, deltaMotor1: delta, deltaMotor2: 0, message: "Pan moved left.")
    }

    private func jogMotor1TowardRight() async {
        guard let host = validatedHost else {
            connectionMessage = "Enter the ESP8266 IP address first."
            return
        }
        guard heading.isAvailable else {
            connectionMessage = "Heading sensor unavailable."
            return
        }

        let delta = panDirectionSign * motor1TestStepDegrees
        await sendJog(host: host, deltaMotor1: delta, deltaMotor2: 0, message: "Pan moved right.")
    }
}
