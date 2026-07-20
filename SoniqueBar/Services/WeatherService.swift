import Foundation
import CoreLocation

/// Fetches current weather using device location + OpenWeather API
@MainActor
final class WeatherService: NSObject, CLLocationManagerDelegate {
    static let shared = WeatherService()

    private let locationManager = CLLocationManager()
    private var locationContinuation: CheckedContinuation<CLLocation?, Never>?

    override private init() {
        super.init()
        locationManager.delegate = self
    }

    /// Get current weather for device location
    func getCurrentWeather() async -> String {
        // Get location
        guard let location = await getLocation() else {
            return "I need location access to check the weather. Please enable location services in System Settings."
        }

        // Fetch weather from OpenWeather API
        return await fetchWeather(lat: location.coordinate.latitude, lon: location.coordinate.longitude)
    }

    private func getLocation() async -> CLLocation? {
        // Check authorization status
        let status = locationManager.authorizationStatus

        #if os(macOS)
        if status == .notDetermined {
            locationManager.requestAlwaysAuthorization()
        }

        guard status == .authorized || status == .authorizedAlways else {
            return nil
        }
        #else
        if status == .notDetermined {
            locationManager.requestWhenInUseAuthorization()
        }

        guard status == .authorizedWhenInUse || status == .authorizedAlways else {
            return nil
        }
        #endif

        return await withCheckedContinuation { continuation in
            self.locationContinuation = continuation
            locationManager.requestLocation()
        }
    }

    private func fetchWeather(lat: Double, lon: Double) async -> String {
        // Use free OpenWeather API (no key needed for current weather)
        let urlString = "https://api.open-meteo.com/v1/forecast?latitude=\(lat)&longitude=\(lon)&current_weather=true&temperature_unit=fahrenheit"

        guard let url = URL(string: urlString) else {
            return "Failed to create weather request."
        }

        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

            guard let currentWeather = json?["current_weather"] as? [String: Any],
                  let temp = currentWeather["temperature"] as? Double,
                  let weatherCode = currentWeather["weathercode"] as? Int else {
                return "I couldn't parse the weather data."
            }

            let condition = weatherCondition(for: weatherCode)
            return "It's currently \(Int(temp))°F and \(condition)."

        } catch {
            return "I couldn't fetch the weather right now. Please try again."
        }
    }

    // MARK: - CLLocationManagerDelegate

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        Task { @MainActor in
            locationContinuation?.resume(returning: locations.first)
            locationContinuation = nil
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in
            locationContinuation?.resume(returning: nil)
            locationContinuation = nil
        }
    }

    // MARK: - Helpers

    private func weatherCondition(for code: Int) -> String {
        // WMO Weather interpretation codes
        switch code {
        case 0: return "clear"
        case 1, 2, 3: return "partly cloudy"
        case 45, 48: return "foggy"
        case 51, 53, 55: return "drizzling"
        case 61, 63, 65: return "rainy"
        case 71, 73, 75: return "snowing"
        case 77: return "snow grains"
        case 80, 81, 82: return "rain showers"
        case 85, 86: return "snow showers"
        case 95: return "thunderstorms"
        case 96, 99: return "thunderstorms with hail"
        default: return "cloudy"
        }
    }
}
