import MapKit
import SwiftUI

/// 地图上的聚合点：同一网格内的照片合成一个缩略图标记。
@MainActor
struct PhotoCluster: Identifiable {
    let id: String
    var coordinate: GeoCoordinate
    var photos: [PhotoItem]

    var count: Int { photos.count }
    var isMultiple: Bool { count > 1 }
    var coverPhoto: PhotoItem? { photos.first }

    var allCoordinates: [GeoCoordinate] {
        photos.compactMap(\.stagedCoordinate)
    }

    /// 聚合点的包围盒，用于点击后放大。
    var boundingRegion: MKCoordinateRegion? {
        let coordinates = allCoordinates
        guard !coordinates.isEmpty else { return nil }
        return AppModel.boundingRegion(for: coordinates, padding: 1.35)
    }
}

enum MapDefaults {
    static var region: MKCoordinateRegion {
        MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 33.5, longitude: 105.0),
            span: MKCoordinateSpan(latitudeDelta: 38, longitudeDelta: 52)
        )
    }
}

enum MapStyleKind: String, CaseIterable, Identifiable, Sendable {
    case standard
    case hybrid
    case imagery

    var id: String { rawValue }

    var title: String {
        switch self {
        case .standard: return "标准"
        case .hybrid: return "混合"
        case .imagery: return "卫星"
        }
    }

    var mapStyle: MapStyle {
        switch self {
        case .standard:
            return .standard(elevation: .flat, pointsOfInterest: .excludingAll)
        case .hybrid:
            return .hybrid(elevation: .flat, pointsOfInterest: .excludingAll)
        case .imagery:
            return .imagery(elevation: .flat)
        }
    }
}
