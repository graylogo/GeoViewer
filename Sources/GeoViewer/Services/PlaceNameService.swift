import CoreLocation
import Foundation

/// 逆地理编码，把坐标变成可读地名。带内存缓存，避免频繁请求。
actor PlaceNameService {
    static let shared = PlaceNameService()

    private var cache: [String: String] = [:]

    func placeName(for coordinate: GeoCoordinate) async -> String? {
        let key = String(format: "%.4f,%.4f", coordinate.latitude, coordinate.longitude)
        if let cached = cache[key] {
            return cached.isEmpty ? nil : cached
        }

        let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        let geocoder = CLGeocoder()

        do {
            let placemarks = try await geocoder.reverseGeocodeLocation(location)
            guard let placemark = placemarks.first else {
                cache[key] = ""
                return nil
            }

            var parts: [String] = []
            for part in [placemark.administrativeArea, placemark.locality, placemark.subLocality, placemark.name] {
                guard let part, !part.isEmpty, parts.last != part else { continue }
                parts.append(part)
            }

            let name = parts.joined(separator: " ")
            cache[key] = name
            return name.isEmpty ? nil : name
        } catch {
            cache[key] = ""
            return nil
        }
    }
}
