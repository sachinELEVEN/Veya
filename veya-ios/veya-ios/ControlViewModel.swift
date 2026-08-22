import Combine
import Foundation
import SwiftUI

@MainActor
final class ControlViewModel: ObservableObject {
    @Published var espHost: String = UserDefaults.standard.string(forKey: "veya.espHost") ?? ""
    @Published var motion: MotionSample = .zero
    @Published var heading: HeadingSample = .zero
    @Published var autoHoldEnabled = false
    @Published var desiredHeadingDegrees: Double = 90
    @Published var desiredPitchDegrees: Double = 70
    @Published var panDirectionSign: Double = 1
    @Published var tiltDirectionSign: Double = 1
    @Published var connectionMessage = "Waiting for an ESP8266 address."
    @Published var calibrationMessage = "Not calibrated yet."
    @Published var headingErrorDegrees: Double = 0
    @Published var pitchErrorDegrees: Double = 0
    @Published var lastPanCommandDegrees: Double = 0
    @Published var lastTiltCommandDegrees: Double = 0
    @Published var filteredHeadingDegrees: Double = 0
    @Published var lastStatus: ESP8266Status?
    @Published var lastErrorMessage: String?
    @Published var isSending = false
    @Published var hasAutoCalibrated = false

    private let client = ESP8266Client()
    private let motionCoordinator = MotionCoordinator()
    private let headingCoordinator = HeadingCoordinator()
    private let panCorrectionGain: Double = 0.14
    private let tiltCorrectionGain: Double = 0.12
    private let deadbandHeading: Double = 5.0
    private let deadbandPitch: Double = 5.0
    private let sendInterval: TimeInterval = 0.10
    private let headingSmoothing: Double = 0.22
    private var lastSendTime = Date.distantPast
    private var pendingStartupCalibration = false

    init() {
        motionCoordinator.onUpdate = { [weak self] sample in
            self?.motion = sample
            self?.attemptAutoHold()
        }

        headingCoordinator.onUpdate = { [weak self] sample in
            self?.heading = sample
            self?.updateFilteredHeading(with: sample)
            self?.attemptAutoHold()
        }

        motionCoordinator.start()
        headingCoordinator.start()

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
            attemptAutoHold()
        } else {
            connectionMessage = "Auto hold paused."
        }
    }

    func resetNorthAndUpDefaults() {
        desiredHeadingDegrees = 90
        desiredPitchDegrees = 70
        calibrationMessage = "Target reset to north + slight up."
    }

    func captureCurrentPose() {
        desiredHeadingDegrees = currentHeadingDegrees
        desiredPitchDegrees = motion.pitchDegrees
        calibrationMessage = "Captured current pose as the hold target."
    }

    func calibrateMotorPolarity() {
        Task {
            await runPolarityCalibration()
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

    private func attemptAutoHold() {
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
        let deltaMotor2 = tiltDirectionSign * pitchError * tiltCorrectionGain

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

    private func sendJog(host: String, deltaMotor1: Double, deltaMotor2: Double, message: String) async {
        do {
            isSending = true
            let status = try await client.jog(host: host, delta1: deltaMotor1, delta2: deltaMotor2)
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
        let tiltSign = await calibrateAxis(
            host: host,
            motor1Delta: 0,
            motor2Delta: 8,
            expectedSensorDelta: {
                self.motion.pitchDegrees - $0
            }
        )

        if let tiltSign {
            tiltDirectionSign = tiltSign
        }

        calibrationMessage = "Direction calibration complete."
        if wasEnabled {
            autoHoldEnabled = true
            attemptAutoHold()
        }

        hasAutoCalibrated = true
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
                _ = try await client.jog(host: host, delta1: 0, delta2: -motor2Delta)
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
}
