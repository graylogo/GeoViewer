import SwiftUI

struct PhotoListView: View {
    @Environment(AppModel.self) private var model
    @Environment(AppSettings.self) private var settings
    /// 被折叠的文件夹路径；没被折叠过的一律视为展开，省掉一份「展开」状态。
    @State private var collapsedFolders: Set<String> = []

    var body: some View {
        @Bindable var model = model

        VStack(spacing: 0) {
            header
            Divider()
            List(selection: $model.selection) {
                ForEach(model.groupedPhotos, id: \.folder) { group in
                    if let folder = group.folder {
                        Section {
                            if !collapsedFolders.contains(folder) {
                                rows(group.photos)
                            }
                        } header: {
                            FolderHeader(
                                path: folder,
                                count: group.photos.count,
                                isExpanded: !collapsedFolders.contains(folder),
                                onToggle: { toggle(folder) },
                                onRemove: { removeGroup(group) }
                            )
                        }
                    } else {
                        rows(group.photos)
                    }
                }
            }
            .listStyle(.inset)
            .onDeleteCommand { model.clearLocationForSelection() }
            .onChange(of: model.selection) { _, newValue in
                if newValue.count == 1, let id = newValue.first {
                    model.primaryID = id
                }
                model.revealSelectedIfNeeded()
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var header: some View {
        @Bindable var model = model
        @Bindable var settings = settings

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
                Picker("", selection: $settings.sortOrder) {
                    ForEach(PhotoSortOrder.allCases) { order in
                        Text(order.title).tag(order)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(maxWidth: .infinity, alignment: .leading)
                .help("切换照片列表的排序方式")

                Toggle("分组", isOn: $settings.groupByFolder)
                    .toggleStyle(.checkbox)
                    .font(.caption2)
                    .help("按所在文件夹分组显示")
            }

            HStack(spacing: 8) {
                Label("\(model.locatedCount) 已定位", systemImage: "mappin.circle.fill")
                if model.dirtyCount > 0 {
                    Label("\(model.dirtyCount) 待保存", systemImage: "circle.fill")
                        .foregroundStyle(.orange)
                }

                Spacer()

                // 用文字而非图标：侧边栏空间有限，图标再叠上菜单箭头容易挤成一团看不清。
                if settings.groupByFolder {
                    Button("全部展开") { collapsedFolders.removeAll() }
                        .disabled(!hasCollapsedFolder)
                        .help("展开所有文件夹")

                    Button("全部折叠") { collapseAll() }
                        .disabled(!hasExpandedFolder)
                        .help("折叠所有文件夹")
                }
            }
            .buttonStyle(.borderless)
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .padding(10)
    }

    @ViewBuilder
    private func rows(_ photos: [PhotoItem]) -> some View {
        ForEach(photos) { photo in
            PhotoRow(photo: photo)
                .tag(photo.id)
                .contextMenu { contextMenu(for: photo) }
        }
    }

    private func toggle(_ path: String) {
        if collapsedFolders.contains(path) {
            collapsedFolders.remove(path)
        } else {
            collapsedFolders.insert(path)
        }
    }

    private func collapseAll() {
        collapsedFolders = Set(model.groupedPhotos.compactMap(\.folder))
    }

    private var hasCollapsedFolder: Bool {
        !collapsedFolders.isEmpty
    }

    private var hasExpandedFolder: Bool {
        model.groupedPhotos.contains { group in
            guard let folder = group.folder else { return false }
            return !collapsedFolders.contains(folder)
        }
    }

    /// 只从列表里移除该文件夹下的照片，不动磁盘上的任何文件。
    private func removeGroup(_ group: (folder: String?, photos: [PhotoItem])) {
        model.removeFromList(ids: Set(group.photos.map(\.id)))
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

        Button("粘贴坐标") {
            // 右键的照片若已在选中范围内就沿用当前多选，实现一次粘贴到多张照片；
            // 否则说明只是对着某张照片右键，仅作用于这一张。
            if !model.selection.contains(photo.id) {
                model.select([photo])
            }
            model.pasteCoordinateToSelection()
        }
        .disabled(!model.canPasteCoordinate)

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
                    Image(systemName: "clock")
                        .font(.system(size: 9))
                    Text(Format.captureTimestamp(photo.details.captureDate))
                        .lineLimit(1)
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                .monospacedDigit()
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
        .help(helpText)
    }

    /// 坐标不再占用列表第二行，改为放进悬浮提示，需要时再看。
    private var helpText: String {
        let location = photo.stagedCoordinate?.formatted ?? "未记录"
        return "\(photo.url.path)\n位置：\(location)"
    }
}

/// 文件夹分组标题：整行可点击展开 / 折叠，右侧 × 只把该文件夹从列表中移除。
private struct FolderHeader: View {
    let path: String
    let count: Int
    let isExpanded: Bool
    let onToggle: () -> Void
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            // 展开 / 折叠：铺满除 × 以外的整行，点击区域尽量大。
            Button(action: onToggle) {
                HStack(spacing: 6) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .bold))
                        .frame(width: 12, height: 12)
                        .foregroundStyle(.secondary)

                    Image(systemName: isExpanded ? "folder.fill" : "folder")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)

                    Text(folderName)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Spacer(minLength: 6)

                    Text("\(count)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                .padding(.vertical, 7)
                .padding(.horizontal, 5)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(path)

            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("从列表中移除该文件夹（不会删除磁盘上的文件）")
        }
    }

    private var folderName: String {
        URL(fileURLWithPath: path, isDirectory: true).lastPathComponent
    }
}
