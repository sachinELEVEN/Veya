import Foundation

struct MotionSample: Equatable {
    var yawDegrees: Double = 0
    var pitchDegrees: Double = 0
    var rollDegrees: Double = 0
    var isAvailable: Bool = false
    var timestamp: Date = .now

    static let zero = MotionSample()
}

struct HeadingSample: Equatable {
    var headingDegrees: Double = 0
    var accuracyDegrees: Double = 0
    var isAvailable: Bool = false
    var usesTrueNorth: Bool = false
    var timestamp: Date = .now

    static let zero = HeadingSample()
}

struct StepperTarget: Equatable {
    var motor1Degrees: Double
    var motor2Degrees: Double

    static let home = StepperTarget(motor1Degrees: 0, motor2Degrees: 0)
    static let lookUp = StepperTarget(motor1Degrees: 0, motor2Degrees: 70)
}

struct ESP8266AxisState: Decodable, Equatable {
    let currentDeg: Double
    let targetDeg: Double
    let currentSteps: Double
    let targetSteps: Double
}

struct ESP8266Status: Decodable, Equatable {
    let ok: Bool
    let message: String
    let wifiSsid: String?
    let ip: String?
    let uptimeMs: Double?
    let motor1: ESP8266AxisState
    let motor2: ESP8266AxisState
}

func clamp(_ value: Double, min lowerBound: Double, max upperBound: Double) -> Double {
    Swift.min(Swift.max(value, lowerBound), upperBound)
}

func normalizeAngleDegrees(_ value: Double) -> Double {
    var normalized = value.truncatingRemainder(dividingBy: 360)
    if normalized > 180 {
        normalized -= 360
    } else if normalized < -180 {
        normalized += 360
    }
    return normalized
}

func degrees(fromRadians radians: Double) -> Double {
    radians * 180 / .pi
}
