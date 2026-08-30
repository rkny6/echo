import Foundation
import CoreLocation

/// Protocol for providing location data
protocol LocationProviding: Sendable {
    /// Get current location
    var currentLocation: CLLocationCoordinate2D? { get }
    
    /// Request location updates
    func requestLocationUpdates() async
    
    /// Stop location updates
    func stopLocationUpdates()
    
    /// Check if user is currently out (has moved significantly)
    func isUserOut() async -> Bool
    
    /// Register a callback for location-driven companion events
    func setLocationEventHandler(_ handler: @escaping (CompanionEvent) async -> Void)
}
