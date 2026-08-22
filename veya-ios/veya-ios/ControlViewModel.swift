import Foundation
import Combine
import SwiftUI

@MainActor
final class ControlViewModel: ObservableObject {
    @Published var espHost: String = ""
    @Published var motion: MotionSample = .zero
    @Published var zeroReference: MotionSample = .zero
    @Published var manualTarget: StepperTarget = .lookUp
    @Published var commandTarget: StepperTarget = .lookUp
    @Published var liveHoldEnabled = false
    @Published var connectionMessage = "Waiting for an ESP8266 address."
    @Published var lastStatus: ESP8266Status?
    @Published var lastErrorMessage: String?
    @Published var isSending = false

    private let client = ESP8266Client()
    private let motionCoordinator = MotionCoordinator()
    private let liveSendInterval: TimeInterval = 0.12
    private let correctionGain: Double = 0.18
    private var lastLiveSend = Date.distantPast

    init() {
        motionCoordinator.onUpdate = { [weak self] sample in
            self?.handleMotion(sample)
        }

        motionCoordinator.start()
    }

    func connect() {
        Task {
            await refreshStatus()
        }
    }

    func refreshStatus() async {
        guard let host = validatedHost else {
            connectionMessage = "Enter the ESP8266 IP address first."
            return
        }

        do {
            let status = try await client.health(host: host)
            lastStatus = status
            lastErrorMessage = nil
            connectionMessage = "Connected to \(status.ip ?? host)"
        } catch {
            lastErrorMessage = error.localizedDescription
            connectionMessage = "Connection failed."
        }
    }

    func sendManualTarget() {
        Task {
            await sendTarget(manualTarget, message: "Manual target sent.")
        }
    }

    func sendHome() {
        manualTarget = .home
        Task {
            await sendTarget(.home, message: "Home preset sent.")
        }
    }

    func sendLookUp() {
        manualTarget = .lookUp
        Task {
            await sendTarget(.lookUp, message: "Look-up preset sent.")
        }
    }

    func zeroHardware() {
        Task {
            guard let host = validatedHost else {
                connectionMessage = "Enter the ESP8266 IP address first."
                return
            }

            do {
                isSending = true
                let status = try await client.zero(host: host)
                lastStatus = status
                zeroReference = motion
                commandTarget = .home
                manualTarget = .home
                lastErrorMessage = nil
                connectionMessage = "Hardware zeroed."
            } catch {
                lastErrorMessage = error.localizedDescription
                connectionMessage = "Zeroing failed."
            }

            isSending = false
        }
    }

    func setLiveHoldEnabled(_ enabled: Bool) {
        liveHoldEnabled = enabled
        lastLiveSend = .distantPast

        if enabled {
            if zeroReference == .zero {
                zeroReference = motion
            }
            connectionMessage = "Live hold enabled."
        } else {
            connectionMessage = "Live hold paused."
        }
    }

    func calibrateMotionZero() {
        zeroReference = motion
        connectionMessage = "Motion zero captured."
    }

    private var validatedHost: String? {
        let trimmed = espHost.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func handleMotion(_ sample: MotionSample) {
        motion = sample

        guard liveHoldEnabled else {
            return
        }

        guard sample.isAvailable, let host = validatedHost else {
            return
        }

        let now = Date()
        guard now.timeIntervalSince(lastLiveSend) >= liveSendInterval else {
            return
        }

        let relativeYaw = normalizeAngleDegrees(sample.yawDegrees - zeroReference.yawDegrees)
        let relativePitch = sample.pitchDegrees - zeroReference.pitchDegrees

        let headingError = normalizeAngleDegrees(manualTarget.motor1Degrees - relativeYaw)
        let tiltError = manualTarget.motor2Degrees - relativePitch

        let nextTarget = StepperTarget(
            motor1Degrees: clamp(commandTarget.motor1Degrees + headingError * correctionGain, min: -160, max: 160),
            motor2Degrees: clamp(commandTarget.motor2Degrees + tiltError * correctionGain, min: -160, max: 160)
        )

        guard abs(nextTarget.motor1Degrees - commandTarget.motor1Degrees) > 0.1 ||
                abs(nextTarget.motor2Degrees - commandTarget.motor2Degrees) > 0.1 else {
            return
        }

        lastLiveSend = now
        Task {
            await sendTarget(nextTarget, message: "Live hold updated.", hostOverride: host)
        }
    }

    private func sendTarget(_ target: StepperTarget, message: String, hostOverride: String? = nil) async {
        guard let host = hostOverride ?? validatedHost else {
            connectionMessage = "Enter the ESP8266 IP address first."
            return
        }

        do {
            isSending = true
            let status = try await client.move(host: host, motor1: target.motor1Degrees, motor2: target.motor2Degrees)
            lastStatus = status
            commandTarget = target
            lastErrorMessage = nil
            connectionMessage = message
        } catch {
            lastErrorMessage = error.localizedDescription
            connectionMessage = "Command failed."
        }

        isSending = false
    }
}
