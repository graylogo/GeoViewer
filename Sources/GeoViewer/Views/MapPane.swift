import MapKit
import SwiftUI

struct MapPane: View {
    @Environment(AppModel.self) private var model
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var model = model

        MapReader { proxy in
            Map(position: $model.cameraPosition) {
                ForEach(model.clusters) { cluster in
                    Annotation("", coordinate: cluster.coordinate.location, anchor: .bottom) {
                        PhotoPinView(cluster: cluster)
                            // MapContent 的标注内容不一定继承上层 Environment，显式注入避免读取时崩溃。
                            .environment(model)
                            .environment(settings)
                            .onTapGesture { model.handleMapTap(on: cluster) }
                    }
                }
            }
            .mapStyle(settings.mapStyle.mapStyle)
            .onMapCameraChange(frequency: .onEnd) { context in
                model.mapRegion = context.region
            }
            .onTapGesture { point in
                guard model.locationMode,
                      let location = proxy.convert(point, from: .local)
                else { return }
                model.setLocationForSelection(
                    GeoCoordinate(latitude: location.latitude, longitude: location.longitude)
                )
            }
            .overlay(alignment: .top) { hint }
            .overlay(alignment: .topTrailing) { MapStylePicker() }
            .overlay(alignment: .bottomTrailing) { zoomControls }
            .overlay { locationModeBorder }
            .overlay(alignment: .bottomLeading) { clusterSummary }
        }
    }

    private var hint: some View {
        HStack(spacing: 6) {
            Image(systemName: "mappin.and.ellipse")
            Text(model.locationHint)
        }
        .font(.caption)
        .padding(.horizontal, 11)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: Capsule())
        .overlay(
            Capsule()
                .strokeBorder(model.locationMode ? Color.accentColor.opacity(0.8) : Color.black.opacity(0.08), lineWidth: 1)
        )
        .padding(.top, 10)
        .allowsHitTesting(false)
    }

    private var zoomControls: some View {
        VStack(spacing: 0) {
            Button {
                model.zoom(by: 0.5)
            } label: {
                Image(systemName: "plus")
                    .frame(width: 26, height: 28)
            }
            Divider()
            Button {
                model.zoom(by: 2)
            } label: {
                Image(systemName: "minus")
                    .frame(width: 26, height: 28)
            }
            Divider()
            Button {
                model.fitAll()
            } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .frame(width: 26, height: 28)
            }
            .help("显示全部照片")
        }
        .buttonStyle(.plain)
        .padding(3)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.black.opacity(0.08))
        )
        .padding(14)
    }

    @ViewBuilder
    private var locationModeBorder: some View {
        if model.locationMode {
            Rectangle()
                .strokeBorder(Color.accentColor.opacity(0.55), lineWidth: 2)
                .allowsHitTesting(false)
                .transition(.opacity)
        }
    }

    @ViewBuilder
    private var clusterSummary: some View {
        if !model.photos.isEmpty, model.locatedCount == 0 {
            HStack(spacing: 6) {
                Image(systemName: "mappin.slash")
                Text("还没有带位置的照片")
                Button("开启定位模式") {
                    model.locationMode = true
                }
                .buttonStyle(.link)
            }
            .font(.caption)
            .padding(.horizontal, 11)
            .padding(.vertical, 7)
            .background(.regularMaterial, in: Capsule())
            .padding(14)
        }
    }
}

struct MapStylePicker: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings

        Picker("地图样式", selection: $settings.mapStyle) {
            ForEach(MapStyleKind.allCases) { kind in
                Text(kind.title).tag(kind)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(width: 172)
        .padding(6)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.black.opacity(0.08))
        )
        .padding(12)
    }
}

/// 地图标记：单张照片显示缩略图，多张照片显示封面 + 数量角标。
struct PhotoPinView: View {
    let cluster: PhotoCluster

    @Environment(AppModel.self) private var model
    @Environment(AppSettings.self) private var settings

    private var isSelected: Bool {
        cluster.photos.contains { model.selection.contains($0.id) }
    }

    private var size: CGFloat { settings.pinSize }

    var body: some View {
        VStack(spacing: -1) {
            ZStack(alignment: .topTrailing) {
                card

                if cluster.isMultiple {
                    Text("\(cluster.count)")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1.5)
                        .background(Capsule().fill(Color.accentColor))
                        .offset(x: 6, y: -6)
                }
            }

            PinTail()
                .fill(Color(nsColor: .textBackgroundColor))
                .frame(width: 12, height: 7)
                .shadow(color: .black.opacity(0.25), radius: 2, y: 2)
        }
        .scaleEffect(isSelected ? 1.06 : 1, anchor: .bottom)
        .animation(.snappy(duration: 0.2), value: isSelected)
        .contentShape(Rectangle())
        .help(helpText)
    }

    private var card: some View {
        Group {
            if let photo = cluster.coverPhoto {
                PhotoThumbnail(photo: photo, maxPixel: 220, size: size - 6, cornerRadius: 5)
            } else {
                Color.clear.frame(width: size - 6, height: size - 6)
            }
        }
        .padding(3)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color(nsColor: .textBackgroundColor))
                .shadow(color: .black.opacity(0.28), radius: 5, y: 2)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(
                    isSelected ? Color.accentColor : Color.black.opacity(0.12),
                    lineWidth: isSelected ? 2.5 : 1
                )
        )
    }

    private var helpText: String {
        if cluster.isMultiple {
            return "\(cluster.count) 张照片"
        }
        return cluster.coverPhoto?.displayName ?? ""
    }
}

struct PinTail: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}
