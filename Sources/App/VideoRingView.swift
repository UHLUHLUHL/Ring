import SwiftUI

/// A single fixed layout survives every video hover, including GIF/WebP.
struct VideoHubContent: View {
    @ObservedObject var model: RingModel

    private var animationFormat:String? {
        guard model.videoStage == .format,let action=model.hoveredAction,AnimationFormat(rawValue: action.id.lowercased()) != nil else { return nil }
        return action.id
    }
    private var selection:String {
        if let format=animationFormat { return "\(format)로 변환" }
        guard let options=model.videoPreviewOptions else { return "영상 정보 확인 중" }
        return "\(options.container.title) · \(options.codec.title)"
    }
    var body: some View {
        VStack(spacing:4) {
            Group {
                if let image=model.thumbnail { Image(nsImage:image).resizable().aspectRatio(contentMode:.fit) }
                else { Image(systemName:"film").font(.system(size:24)) }
            }
            .frame(width:42,height:34)
            Text(selection)
                .font(.system(size:10,weight:.semibold)).lineLimit(1).minimumScaleFactor(0.8)
                .foregroundStyle(animationFormat == nil ? Color.primary:Color.white)
                .padding(.horizontal,6)
                .frame(height:17)
                .background(Capsule().fill(animationFormat == nil ? Color.clear:Color.accentColor))
            Text(animationFormat.map { model.file.baseName+"."+$0.lowercased() } ?? model.file.name)
                .font(.system(size:11,weight:.semibold)).lineLimit(1).truncationMode(.middle)
                .frame(height:14)
            Text(animationFormat != nil ? "움짤로 저장":model.videoPreviewOptions?.codec == .passthrough ? "재압축 없음":model.videoStage == .format ? "포맷 선택":"코덱 선택 시 변환")
                .font(.system(size:10)).foregroundStyle(.secondary).lineLimit(1).frame(height:13)
        }
        .frame(width:RingMetrics.hubDiameter-24,height:RingMetrics.hubDiameter)
        .multilineTextAlignment(.center)
        .transaction { $0.animation=nil }
        .shadow(color:.black.opacity(0.3),radius:2,y:0.5)
        .opacity(model.isWorking ? 0:1)
        .accessibilityIdentifier("video.settings")
    }
}
