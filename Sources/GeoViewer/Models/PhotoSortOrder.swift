import Foundation

/// 照片列表的排序方式。
///
/// 默认按拍摄时间升序：连拍或同一次出行拍下的照片会自然挨在一起，
/// 据此即可判断哪些照片属于同一批，而不必去比对左侧的经纬度。
enum PhotoSortOrder: String, CaseIterable, Identifiable, Sendable {
    case captureDateAscending
    case captureDateDescending
    case fileNameAscending
    case folderPathAscending

    var id: String { rawValue }

    var title: String {
        switch self {
        case .captureDateAscending: return "拍摄时间（早→晚）"
        case .captureDateDescending: return "拍摄时间（晚→早）"
        case .fileNameAscending: return "文件名（A→Z）"
        case .folderPathAscending: return "文件夹路径"
        }
    }

    /// 排序比较器。
    ///
    /// 没有拍摄时间的照片一律沉到末尾，避免把「未知时间」混进时间轴里；
    /// 时间相同或同为未知时再按文件名兜底，保证顺序稳定。
    @MainActor
    func precedes(_ lhs: PhotoItem, _ rhs: PhotoItem) -> Bool {
        switch self {
        case .captureDateAscending:
            return compareByCaptureDate(lhs, rhs, ascending: true)
        case .captureDateDescending:
            return compareByCaptureDate(lhs, rhs, ascending: false)
        case .fileNameAscending:
            return compareByFileName(lhs, rhs)
        case .folderPathAscending:
            if lhs.directoryPath != rhs.directoryPath {
                return lhs.directoryPath.localizedStandardCompare(rhs.directoryPath) == .orderedAscending
            }
            return compareByFileName(lhs, rhs)
        }
    }

    @MainActor
    private func compareByCaptureDate(_ lhs: PhotoItem, _ rhs: PhotoItem, ascending: Bool) -> Bool {
        switch (lhs.details.captureDate, rhs.details.captureDate) {
        case let (lhsDate?, rhsDate?):
            return ascending ? lhsDate < rhsDate : lhsDate > rhsDate
        case (_?, nil):
            return true
        case (nil, _?):
            return false
        case (nil, nil):
            return compareByFileName(lhs, rhs)
        }
    }

    @MainActor
    private func compareByFileName(_ lhs: PhotoItem, _ rhs: PhotoItem) -> Bool {
        lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
    }
}
