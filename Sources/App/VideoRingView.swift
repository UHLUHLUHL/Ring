import SwiftUI

/// Read-only hover preview. Selecting a codec starts the job directly.
struct VideoHubContent: View {
    @ObservedObject var model: RingModel

    var body: some View {
        VStack(spacing: 4) {
            if let image = model.thumbnail {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                    .frame(width: 42, height: 34)
            }
            Text(model.file.name)
                .font(.system(size: 11, weight: .semibold))
                .lineLimit(1).truncationMode(.middle)
            if let options = model.videoPreviewOptions {
                Text("\(options.container.title) · \(options.codec.title)")
                    .font(.system(size: 10, weight: .medium)).lineLimit(1).minimumScaleFactor(0.8)
                if options.codec == .passthrough {
                    Text("재압축 없음").font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
            Text(model.videoStage == .format ? "포맷 선택" : "코덱 선택 시 변환")
                .font(.system(size: 10)).foregroundStyle(.secondary)
        }
        .frame(width: RingMetrics.hubDiameter - 24, height: RingMetrics.hubDiameter)
        .multilineTextAlignment(.center)
        .shadow(color: .black.opacity(0.3), radius: 2, y: 0.5)
        .opacity(model.isWorking ? 0 : 1)
        .accessibilityIdentifier("video.settings")
    }
}
