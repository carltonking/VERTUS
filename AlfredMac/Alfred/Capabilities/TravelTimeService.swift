import CoreLocation
import Foundation
import MapKit

/// Estimates travel time from the user's current location to a calendar event's location.
///
/// - Driving / walking use Apple's free `MKDirections` (no key).
/// - Transit uses the Google Routes API (`computeRoutes`, `travelMode: TRANSIT`) because Apple's free
///   API can't return transit times; the Google key lives in the Keychain (account "googlemaps"). If no
///   key is set or no transit route is found, it falls back to walking so the reminder still works.
///
/// Current location + geocoded event coordinates are cached briefly since CoreLocation/CLGeocoder are
/// rate-limited and the watcher polls every few minutes.
@MainActor
final class TravelTimeService: NSObject, CLLocationManagerDelegate {

    enum Mode: String {
        case walking, driving, transit
        init(setting: String) { self = Mode(rawValue: setting.lowercased()) ?? .walking }
    }

    struct Estimate {
        let seconds: TimeInterval
        let usedMode: Mode   // may differ from requested (transit → walking fallback)
    }

    private let manager = CLLocationManager()
    private var locationContinuation: CheckedContinuation<CLLocation?, Never>?
    private var cachedLocation: CLLocation?
    private var cachedLocationAt: Date?
    private var geocodeCache: [String: CLLocation] = [:]

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    var authorizationStatus: CLAuthorizationStatus { manager.authorizationStatus }
    var isAuthorized: Bool {
        switch authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse, .authorized: return true
        default: return false
        }
    }

    func requestAuthorization() { manager.requestWhenInUseAuthorization() }

    // MARK: - Travel time

    /// Travel time to `event` in the requested mode, or nil if location/route can't be determined.
    func estimate(to event: LocatedEvent, mode: Mode) async -> Estimate? {
        guard let origin = await currentLocation() else { return nil }
        guard let dest = await coordinate(for: event) else { return nil }

        switch mode {
        case .walking, .driving:
            guard let secs = await appleTravelTime(from: origin, to: dest, mode: mode) else { return nil }
            return Estimate(seconds: secs, usedMode: mode)
        case .transit:
            if let secs = await googleTransitTime(from: origin, to: dest) {
                return Estimate(seconds: secs, usedMode: .transit)
            }
            // No key / no transit route → fall back to walking so the nudge still fires.
            guard let secs = await appleTravelTime(from: origin, to: dest, mode: .walking) else { return nil }
            return Estimate(seconds: secs, usedMode: .walking)
        }
    }

    // MARK: - Current location (one-shot, cached ~5 min)

    private func currentLocation() async -> CLLocation? {
        if let loc = cachedLocation, let at = cachedLocationAt, Date().timeIntervalSince(at) < 300 {
            return loc
        }
        if authorizationStatus == .notDetermined { manager.requestWhenInUseAuthorization(); return nil }
        guard isAuthorized else { return nil }
        return await withCheckedContinuation { cont in
            locationContinuation = cont
            manager.requestLocation()
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        Task { @MainActor in
            if let loc = locations.last { cachedLocation = loc; cachedLocationAt = Date() }
            locationContinuation?.resume(returning: locations.last ?? cachedLocation)
            locationContinuation = nil
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in
            locationContinuation?.resume(returning: cachedLocation)
            locationContinuation = nil
        }
    }

    // MARK: - Geocoding (event location text → coordinate; cached)

    private func coordinate(for event: LocatedEvent) async -> CLLocation? {
        if let c = event.coordinate { return c }
        let key = event.location.lowercased()
        if let cached = geocodeCache[key] { return cached }
        guard let placemarks = try? await CLGeocoder().geocodeAddressString(event.location),
              let loc = placemarks.first?.location else { return nil }
        geocodeCache[key] = loc
        return loc
    }

    // MARK: - Apple driving / walking (free)

    private func appleTravelTime(from origin: CLLocation, to dest: CLLocation, mode: Mode) async -> TimeInterval? {
        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: origin.coordinate))
        request.destination = MKMapItem(placemark: MKPlacemark(coordinate: dest.coordinate))
        request.transportType = (mode == .walking) ? .walking : .automobile
        guard let response = try? await MKDirections(request: request).calculate(),
              let route = response.routes.first else { return nil }
        return route.expectedTravelTime
    }

    // MARK: - Google transit (needs a Keychain key)

    private func googleTransitTime(from origin: CLLocation, to dest: CLLocation) async -> TimeInterval? {
        guard let key = KeychainHelper.load(service: "com.alfred.app", account: "googlemaps")?
            .trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else { return nil }

        var request = URLRequest(url: URL(string: "https://routes.googleapis.com/directions/v2:computeRoutes")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(key, forHTTPHeaderField: "X-Goog-Api-Key")
        request.setValue("routes.duration", forHTTPHeaderField: "X-Goog-FieldMask")
        request.timeoutInterval = 15
        let body: [String: Any] = [
            "origin": ["location": ["latLng": ["latitude": origin.coordinate.latitude,
                                               "longitude": origin.coordinate.longitude]]],
            "destination": ["location": ["latLng": ["latitude": dest.coordinate.latitude,
                                                    "longitude": dest.coordinate.longitude]]],
            "travelMode": "TRANSIT",
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let routes = json["routes"] as? [[String: Any]],
              let durationStr = routes.first?["duration"] as? String else { return nil }
        // Google returns duration like "1234s".
        return TimeInterval(durationStr.replacingOccurrences(of: "s", with: ""))
    }
}
