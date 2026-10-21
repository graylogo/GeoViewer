import SwiftUI

struct PhotoListView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model

        VStack(spacing: 0) {
            header
            Divider()
            List(selection: $model.selection) {
                ForEach(model.filteredPhotos) { photo in
                    PhotoRow(photo: photo)
                        .tag(photo.id)
                        .contextMenu { contextMenu(for: photo) }
                }
            }
            .listStyle(.inset)
            .onDeleteCommand { model.clearLocationForSelection() }
            .onChange(of: model.selection) { _, newValue in
                if newValue.count == 1, let id = newValue.first {
                    model.primaryID = id
                }
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var header: some View {
        @Bindable var model = model

        return VStack(spacing: 9) {
            HStack {
                Text("照片")
                    .font(.headline)
                Spacer()
                Text("\(model.photos.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("搜索文件名", text: $model.searchText)
                    .textFieldStyle(.plain)
                    .font(.callout)
                if !model.searchText.isEmpty {
                    Button {
                        model.searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.borderless)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6, style: .continuous))

            HStack(spacing: 6) {
                Label("\(model.locatedCount) 已定位", systemImage: "mappin.circle.fill")
                Spacer()
                if model.dirtyCount > 0 {
                    Label("\(model.dirtyCount) 待保存", systemImage: "circle.fill")
                        .foregroundStyle(.orange)
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .padding(10)
    }

    @ViewBuilder
    private func contextMenu(for photo: PhotoItem) -> some View {
        Button("在地图上显示") { model.focus(on: photo) }
            .disabled(!photo.hasLocation)

        Button("在访达中显示") { model.revealInFinder(photo) }

        Divider()

        Button("拷贝坐标") {
            model.select([photo])
            model.copySelectedCoordinate()
        }
        .disabled(!photo.hasLocation)

        Button("删除位置") {
            model.select([photo])
            model.setLocationForSelection(nil)
        }
        .disabled(!photo.hasLocation || !photo.isWritable)

        Divider()

        Button("从列表中移除") {
            model.removeFromList(ids: [photo.id])
        }
    }
}

private struct PhotoRow: View {
    let photo: PhotoItem

    var body: some View {
        HStack(spacing: 9) {
            PhotoThumbnail(photo: photo, maxPixel: 120, size: 42, cornerRadius: 5)

            VStack(alignment: .leading, spacing: 3) {
                Text(photo.displayName)
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.middle)

                HStack(spacing: 4) {
                    Image(systemName: photo.hasLocation ? "mappin.circle.fill" : "mappin.slash")
                        .font(.system(size: 9))
                    Text(photo.hasLocation ? (photo.stagedCoordinate?.formatted ?? "") : "未记录位置")
                        .lineLimit(1)
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }

            Spacer(minLength: 4)

            VStack(spacing: 5) {
                if photo.isDirty {
                    Circle()
                        .fill(Color.orange)
                        .frame(width: 6, height: 6)
                        .help("有未保存的修改")
                }
                if !photo.isWritable {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 8))
                        .foregroundStyle(.secondary)
                        .help("只读格式，暂不支持写入位置")
                }
            }
        }
        .padding(.vertical, 3)
        .help(photo.url.path)
    }
}
