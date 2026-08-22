import CoreLocation
import Foundation

final class HeadingCoordinator: NSObject, CLLocationManagerDelegate {
    var onUpdate: ((HeadingSample) -> Void)?

    private let manager = CLLocationManager()
    private var latestSample = HeadingSample.zero

    override init() {
        super.init()
        manager.delegate = self
        manager.headingFilter = kCLHeadingFilterNone
    }

    func start() {
        let status = manager.authorizationStatus
        if status == .notDetermined {
            manager.requestWhenInUseAuthorization()
        }

        guard CLLocationManager.headingAvailable() else {
            latestSample = HeadingSample(isAvailable: false, usesTrueNorth: false, timestamp: .now)
            onUpdate?(latestSample)
            return
        }

        manager.startUpdatingHeading()
    }

    func stop() {
        manager.stopUpdatingHeading()
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        if manager.authorizationStatus == .authorizedWhenInUse || manager.authorizationStatus == .authorizedAlways {
            if CLLocationManager.headingAvailable() {
                manager.startUpdatingHeading()
            }
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        let headingDegrees: Double
        let usesTrueNorth: Bool

        if newHeading.trueHeading >= 0 {
            headingDegrees = newHeading.trueHeading
            usesTrueNorth = true
        } else {
            headingDegrees = newHeading.magneticHeading
            usesTrueNorth = false
        }

        latestSample = HeadingSample(
            headingDegrees: headingDegrees,
            accuracyDegrees: newHeading.headingAccuracy,
            isAvailable: true,
            usesTrueNorth: usesTrueNorth,
            timestamp: .now
        )
        onUpdate?(latestSample)
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        latestSample = HeadingSample(
            headingDegrees: latestSample.headingDegrees,
            accuracyDegrees: latestSample.accuracyDegrees,
            isAvailable: false,
            usesTrueNorth: latestSample.usesTrueNorth,
            timestamp: .now
        )
        onUpdate?(latestSample)
    }
}

