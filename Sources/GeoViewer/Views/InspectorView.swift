import SwiftUI

struct InspectorView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("照片信息")
                    .font(.headline)
                Spacer()
                if let primary = model.primaryPhoto {
                    Button {
                        model.revealInFinder(primary)
                    } label: {
                        Image(systemName: "folder")
                    }
                    .buttonStyle(.borderless)
                    .help("在访达中显示")
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Divider()

            if let photo = model.primaryPhoto {
                content(for: photo)
            } else {
                ContentUnavailableView(
                    "未选择照片",
                    systemImage: "photo",
                    description: Text("在左侧列表或地图上选择一张照片，查看它的拍摄信息和位置。")
                )
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private func content(for photo: PhotoItem) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                preview(for: photo)

                Text(photo.displayName)
                    .font(.callout.weight(.medium))
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .textSelection(.enabled)

                if model.selection.count > 1 {
                    Label("已选择 \(model.selection.count) 张照片，定位操作会同时应用", systemImage: "square.stack.3d.up")
                        .font(.caption)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                }

                locationSection(for: photo)
                cameraSection(for: photo)
                fileSection(for: photo)

                Text("GeoViewer 只写入 EXIF 中的 GPS 字段，不重新编码图像，也不改动拍摄时间、相机参数等其它信息。")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(14)
        }
    }

    private func preview(for photo: PhotoItem) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.black.opacity(0.06))

            if let image = photo.thumbnails[900] {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .frame(height: 190)
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .task(id: photo.thumbnailToken) {
            await model.loadThumbnail(for: photo, maxPixel: 900)
        }
    }

    private func locationSection(for photo: PhotoItem) -> some View {
        section("位置") {
            if let coordinate = photo.stagedCoordinate {
                InfoRow(title: "坐标", value: coordinate.formatted, monospaced: true, copyValue: coordinate.formatted)
                InfoRow(title: "经度", value: "\(Format.longitudeDirection(coordinate)) \(String(format: "%.6f°", abs(coordinate.longitude)))")
                InfoRow(title: "纬度", value: "\(Format.latitudeDirection(coordinate)) \(String(format: "%.6f°", abs(coordinate.latitude)))")
                InfoRow(title: "海拔", value: Format.altitude(photo.details.gps))
                InfoRow(title: "方向", value: Format.direction(photo.details.gps))
                PlaceNameView(coordinate: coordinate)
            } else {
                Text("未记录位置")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("开启「定位模式」后点击地图，或使用「照片 › 输入经纬度…」。")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if photo.isDirty {
                Label("位置已修改，尚未保存", systemImage: "circle.fill")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }

            HStack(spacing: 8) {
                Button("在地图上显示") { model.focus(on: photo) }
                    .disabled(!photo.hasLocation)
                Button("删除位置") { model.setLocationForSelection(nil) }
                    .disabled(!photo.hasLocation || !photo.isWritable)
            }
            .font(.caption)
            .buttonStyle(.bordered)
            .controlSize(.small)

            if !photo.isWritable {
                Label("该格式为只读，暂不支持写入位置", systemImage: "lock")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func cameraSection(for photo: PhotoItem) -> some View {
        let details = photo.details
        return section("拍摄") {
            InfoRow(title: "相机", value: Format.camera(make: details.make, model: details.model))
            InfoRow(title: "镜头", value: Format.text(details.lensModel))
            InfoRow(title: "焦距", value: Format.focalLength(details.focalLength, equivalent: details.focalLength35mm))
            InfoRow(title: "光圈", value: Format.aperture(details.aperture))
            InfoRow(title: "快门", value: Format.shutter(details.exposureTime))
            InfoRow(title: "ISO", value: Format.iso(details.iso))
            InfoRow(title: "曝光补偿", value: Format.exposureBias(details.exposureBias))
            InfoRow(title: "拍摄时间", value: Format.dateTime(details.captureDate))
            if let software = details.software {
                InfoRow(title: "软件", value: software)
            }
        }
    }

    private func fileSection(for photo: PhotoItem) -> some View {
        let details = photo.details
        return section("文件") {
            InfoRow(title: "格式", value: details.formatDescription)
            InfoRow(title: "尺寸", value: Format.dimensions(width: details.width, height: details.height))
            InfoRow(title: "大小", value: Format.fileSize(details.fileSize))
            InfoRow(title: "修改时间", value: Format.dateTime(details.fileModificationDate))
            InfoRow(title: "权限", value: Format.filePermission(writable: details.isWritable))
            InfoRow(title: "路径", value: photo.directoryPath, copyValue: photo.url.path)
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct InfoRow: View {
    let title: String
    let value: String
    var monospaced = false
    var copyValue: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 56, alignment: .leading)

            Text(value)
                .font(monospaced ? .system(.caption, design: .monospaced) : .caption)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            if let copyValue {
                Button {
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString(copyValue, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 9))
                }
                .buttonStyle(.borderless)
                .help("拷贝")
            }
        }
    }
}

/// 坐标对应的可读地名，失败时静默隐藏。
private struct PlaceNameView: View {
    let coordinate: GeoCoordinate

    @State private var placeName: String?
    @State private var isLoading = true

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("地点")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 56, alignment: .leading)

            if let placeName {
                Text(placeName)
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
            } else if isLoading {
                HStack(spacing: 5) {
                    ProgressView().controlSize(.mini)
                    Text("正在解析…")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            } else {
                Text("未知")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)
        }
        .task(id: coordinate) {
            isLoading = true
            placeName = await PlaceNameService.shared.placeName(for: coordinate)
            isLoading = false
        }
    }
}
