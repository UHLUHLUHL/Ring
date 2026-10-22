import SwiftUI

/// The same glass hub becomes the explicit final confirmation target. Hover
/// previews are never submitted: the button always runs the committed options.
struct VideoHubContent: View {
    @ObservedObject var model: RingModel

    var body: some View {
        Button { model.startVideoConversion() } label: {
            VStack(spacing: 4) {
                if let options = model.videoPreviewOptions {
                    Text("\(options.container.title) · \(options.codec.title)")
                        .font(.system(size: 10, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.8)
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(.primary.opacity(0.10), in: Capsule())
                }
                if let plan = model.videoPreviewPlan {
                    Text("약 " + ByteCountFormatter.string(fromByteCount: plan.estimatedBytes, countStyle: .file))
                        .font(.system(size: 23, weight: .semibold, design: .rounded))
                        .lineLimit(1).minimumScaleFactor(0.65).monospacedDigit()
                } else {
                    Text(model.videoSource == nil && model.videoError == nil ? "확인 중…" : "추정 불가")
                        .font(.system(size: 18, weight: .semibold))
                }
                Text("원본 " + model.file.sizeText)
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                if model.videoPreviewOptions?.codec == .passthrough {
                    Text("재압축 없음").font(.system(size: 10, weight: .medium))
                } else if let quality = model.videoPreviewOptions?.quality {
                    Text(quality.title + (model.videoIsPreview ? " 미리보기" : ""))
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Text(model.videoReady ? (model.videoIsPreview ? "선택 유지 · 미리보기" : "변환 시작") : stageTitle)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(model.videoReady ? Color.accentColor : .primary)
            }
            .frame(width: RingMetrics.hubDiameter - 22, height: RingMetrics.hubDiameter)
            .multilineTextAlignment(.center)
            .contentShape(Circle())
            .shadow(color: .black.opacity(0.3), radius: 2, y: 0.5)
        }
        .buttonStyle(VideoHubButtonStyle()).focusEffectDisabled()
        .disabled(!model.videoReady || model.isWorking || model.isNavigating)
        .opacity(model.isWorking ? 0 : 1)
        .accessibilityIdentifier("video.start")
        .accessibilityLabel(model.videoReady ? "선택한 설정으로 변환 시작" : stageTitle)
        .accessibilityValue(summary)
        .accessibilityHint("설정을 선택한 뒤 중앙 클릭 또는 Command Return으로 실행")
    }

    private var stageTitle: String {
        switch model.videoStage { case .format: return "포맷 선택"; case .codec: return "코덱 선택"; case .quality: return "화질 선택" }
    }

    private var summary: String {
        let options = model.videoPreviewOptions
        let format = options.map { "\($0.container.title) · \($0.codec.title)" } ?? "영상 정보"
        let size = model.videoPreviewPlan.map { "약 " + ByteCountFormatter.string(fromByteCount: $0.estimatedBytes, countStyle: .file) } ?? "추정 불가"
        let quality = options?.codec == .passthrough ? "재압축 없음" : (options?.quality?.title ?? "")
        return "\(format), \(size), 원본 \(model.file.sizeText), \(quality)\(model.videoIsPreview ? " 미리보기" : "")"
    }
}

// The hub is a readable settings summary before it is an enabled button.
// Keep disabled semantics without the system button's dimmed label treatment.
private struct VideoHubButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { configuration.label }
}
