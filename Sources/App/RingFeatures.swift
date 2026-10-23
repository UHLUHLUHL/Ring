import Foundation

/// Optional engine paths. Existing menus remain the default; unknown saved IDs are ignored.
enum RingFeatures {
    struct Feature: Identifiable {
        let id: String
        let title: String
    }
    static let groups: [(id: String, title: String, items: [Feature])] = [
        ("image", "사진 변환 · 한 장 저장", [Feature(id: "AVIF", title: "AVIF"), Feature(id: "JXL", title: "JPEG XL"), Feature(id: "TIFF", title: "TIFF"), Feature(id: "BMP", title: "BMP")]),
        ("animation", "움짤 변환", [Feature(id: "AVIF", title: "애니메이션 AVIF"), Feature(id: "JXL", title: "애니메이션 JPEG XL")]),
        ("video", "영상 변환", [Feature(id: "WEBM", title: "WebM · AV1"), Feature(id: "AV1", title: "AV1 코덱 · MP4 / WebM")])
    ]
    static func key(_ group: String) -> String { "ring.features." + group }
    static func enabled(_ group: String, _ id: String, defaults: UserDefaults = .standard) -> Bool {
        (defaults.stringArray(forKey: key(group)) ?? []).contains(id)
    }
    static func set(_ group: String, _ id: String, enabled: Bool, defaults: UserDefaults = .standard) {
        var values = defaults.stringArray(forKey: key(group)) ?? []
        values.removeAll { $0 == id }
        if enabled { values.append(id) }
        defaults.set(values, forKey: key(group))
    }
    static func selected(_ group: String) -> [String] {
        groups.first { $0.id == group }?.items.filter { enabled(group, $0.id) }.map(\.id) ?? []
    }
    static var frameFormats: [String] { ["PNG", "JPG", "WEBP"] + selected("image").filter { ["AVIF", "JXL"].contains($0) } }
}
