import SwiftUI

/// 带占位与异步加载的缩略图视图。
struct PhotoThumbnail: View {
    let photo: PhotoItem
    var maxPixel: Int = 160
    var size: CGFloat = 42
    var cornerRadius: CGFloat = 6

    @Environment(AppModel.self) private var model

    private var image: NSImage? { photo.thumbnails[maxPixel] }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Color(nsColor: .quaternaryLabelColor).opacity(0.28))

            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.medium)
                    .aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: "photo")
                    .font(.system(size: max(10, size * 0.32), weight: .light))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .task(id: photo.id) {
            await model.loadThumbnail(for: photo, maxPixel: maxPixel)
        }
    }
}
