import Foundation
import CoreLocation

/// Service for reading location data
final class LocationService: NSObject, LocationProviding, CLLocationManagerDelegate, @unchecked Sendable {
    private let locationManager = CLLocationManager()
    private(set) var currentLocation: CLLocationCoordinate2D?
    private var eventHandler: ((CompanionEvent) async -> Void)?

    // How long a significant-location-change is still considered "the user is
    // currently out and about" for the purposes of `isUserOut()`. Previously
    // this was `currentLocation != nil`, which becomes permanently true after
    // the very first location fix ever received — meaning every later call
    // (e.g. from EventDetectionService.detectEvents(), which runs on every
    // background refresh) generated *another* redundant "outing" event
    // forever, on top of the real-time one already delivered by
    // didUpdateLocations below. That's the main reason pending "outing"
    // events built up in the queue without anything meaningful behind them.
    private static let outingRecencyWindow: TimeInterval = 2 * 60 * 60 // 2 hours
    private var lastLocationUpdateAt: Date?

    override init() {
        super.init()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyKilometer
    }

    func requestLocationUpdates() async {
        switch locationManager.authorizationStatus {
        case .notDetermined:
            // Monitoring never actually starts without authorization —
            // startMonitoringSignificantLocationChanges() silently no-ops
            // when status is .notDetermined. We request it, then start
            // monitoring from locationManagerDidChangeAuthorization once the
            // user responds.
            locationManager.requestAlwaysAuthorization()
        case .authorizedAlways, .authorizedWhenInUse:
            locationManager.startMonitoringSignificantLocationChanges()
        case .denied, .restricted:
            break
        @unknown default:
            break
        }
    }

    func stopLocationUpdates() {
        locationManager.stopMonitoringSignificantLocationChanges()
    }

    func isUserOut() async -> Bool {
        guard let lastUpdate = lastLocationUpdateAt else { return false }
        return Date().timeIntervalSince(lastUpdate) <= Self.outingRecencyWindow
    }

    func setLocationEventHandler(_ handler: @escaping (CompanionEvent) async -> Void) {
        eventHandler = handler
    }

    // MARK: - CLLocationManagerDelegate

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            manager.startMonitoringSignificantLocationChanges()
        default:
            break
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        currentLocation = location.coordinate
        lastLocationUpdateAt = Date()
        let event = CompanionEvent(
            type: .outing,
            priority: CompanionEventType.outing.defaultPriority,
            metadata: [
                "source": "location_change",
                "latitude": "\(location.coordinate.latitude)",
                "longitude": "\(location.coordinate.longitude)"
            ]
        )
        if let eventHandler = eventHandler {
            Task {
                await eventHandler(event)
            }
        }
    }
}
