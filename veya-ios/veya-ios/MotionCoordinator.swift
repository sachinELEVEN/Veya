import CoreMotion
import Foundation

final class MotionCoordinator {
    var onUpdate: ((MotionSample) -> Void)?

    private let manager = CMMotionManager()

    var isAvailable: Bool {
        manager.isDeviceMotionAvailable
    }

    func start() {
        guard manager.isDeviceMotionAvailable else {
            onUpdate?(MotionSample(isAvailable: false, timestamp: .now))
            return
        }

        manager.deviceMotionUpdateInterval = 1.0 / 20.0

        manager.startDeviceMotionUpdates(using: .xArbitraryZVertical, to: .main) { [weak self] motion, _ in
            guard let motion else {
                self?.onUpdate?(MotionSample(isAvailable: false, timestamp: .now))
                return
            }

            let sample = MotionSample(
                yawDegrees: degrees(fromRadians: motion.attitude.yaw),
                pitchDegrees: degrees(fromRadians: motion.attitude.pitch),
                rollDegrees: degrees(fromRadians: motion.attitude.roll),
                isAvailable: true,
                timestamp: .now
            )

            self?.onUpdate?(sample)
        }
    }

    func stop() {
        manager.stopDeviceMotionUpdates()
    }
}
