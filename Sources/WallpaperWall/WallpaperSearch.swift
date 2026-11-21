import Foundation

struct WallpaperSearch: Sendable {
    private struct Concept: Sendable {
        let aliases: [String]
        let english: String
    }

    private static let concepts = [
        Concept(aliases: ["自然风光", "自然景观", "风光", "风景", "自然"], english: "landscape"),
        Concept(aliases: ["城市夜景", "都市夜景", "夜景"], english: "city night"),
        Concept(aliases: ["人物插画", "动画", "动漫"], english: "anime"),
        Concept(aliases: ["女性写真", "女性肖像", "美女", "女神"], english: "female portrait"),
        Concept(aliases: ["人物写真", "人像", "肖像", "写真"], english: "portrait"),
        Concept(aliases: ["海边", "海岸线", "海岸", "海滩", "沙滩"], english: "coast"),
        Concept(aliases: ["日落", "落日", "夕阳", "黄昏"], english: "sunset"),
        Concept(aliases: ["日出", "朝阳"], english: "sunrise"),
        Concept(aliases: ["下雪", "雪景", "雪地"], english: "snow"),
        Concept(aliases: ["雪山"], english: "snow mountains"),
        Concept(aliases: ["山脉", "高山", "群山", "山峰"], english: "mountains"),
        Concept(aliases: ["星空", "繁星", "星夜"], english: "starry sky"),
        Concept(aliases: ["极光"], english: "aurora"),
        Concept(aliases: ["星云"], english: "nebula"),
        Concept(aliases: ["星系"], english: "galaxy"),
        Concept(aliases: ["月球", "月面"], english: "moon"),
        Concept(aliases: ["地球"], english: "earth"),
        Concept(aliases: ["森林", "树林", "林间"], english: "forest"),
        Concept(aliases: ["海洋", "大海"], english: "ocean"),
        Concept(aliases: ["太空", "宇宙"], english: "space"),
        Concept(aliases: ["极简", "简约"], english: "minimalism"),
        Concept(aliases: ["国风", "中国风"], english: "chinese art"),
        Concept(aliases: ["赛博朋克"], english: "cyberpunk"),
        Concept(aliases: ["银河"], english: "milky way"),
        Concept(aliases: ["猫咪", "小猫", "猫"], english: "cat"),
        Concept(aliases: ["湖泊", "湖畔", "湖面"], english: "lake"),
        Concept(aliases: ["沙漠", "沙丘"], english: "desert"),
        Concept(aliases: ["城市", "都市"], english: "cityscape"),
        Concept(aliases: ["蓝色"], english: "blue")
    ]
    private static let pattern = "\\b(?:wallpapers?|[48]k|uhd|mac(?:book)?)\\b|(?:超高清|高清|桌面|壁纸|背景图)"
    private static let han = #"\p{Han}"#
    private static let aliases = concepts.flatMap { concept in
        concept.aliases.map { ($0, concept) }
    }.sorted { $0.0.count > $1.0.count }

    let text: String
    private let terms: [String]

    init(_ input: String) {
        text = input.replacingOccurrences(of: Self.pattern, with: " ", options: [.regularExpression, .caseInsensitive])
            .split(whereSeparator: { $0.isWhitespace || "，、,；;。".contains($0) }).joined(separator: " ")
        let pattern = Self.aliases.map(\.0).joined(separator: "|")
        terms = text.replacingOccurrences(of: "(\(pattern))", with: " $1 ", options: .regularExpression)
            .split(whereSeparator: \.isWhitespace).map(String.init)
    }

    var containsChinese: Bool { text.range(of: Self.han, options: .regularExpression) != nil }

    var domesticTopic: String? {
        switch text {
        case "美女", "女性写真", "人物写真", "人像": "美女"
        case "自然风光", "风光", "自然", "风景": "风景"
        case "人物插画", "动漫", "动画": "动漫"
        case "城市夜景", "夜景": "夜景"
        case "国风", "极简": text
        default: nil
        }
    }

    var isPortraitPhotography: Bool {
        !isAnime && includes(#"美女|女神|人像|肖像|写真|明星|演员|模特|\b(?:portrait|headshot|woman|women|female|actress|actor|fashion model|celebrity)\b"#)
    }

    var isAnime: Bool {
        includes(#"动漫|动画|二次元|人物插画|\b(?:anime|manga)\b"#)
    }

    private func includes(_ pattern: String) -> Bool {
        text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    var wallhavenQuery: String? {
        let translated = terms.map { term in
            Self.aliases.first { $0.0 == term }?.1.english ?? term
        }.joined(separator: " ")
        return translated.range(of: Self.han, options: .regularExpression) == nil ? translated : nil
    }

    var chineseFallback: String? {
        guard terms.count > 1 else { return nil }
        return terms.first { term in !Self.aliases.contains { $0.0 == term } } ?? terms.first
    }

    func matches(_ text: String) -> Bool {
        terms.allSatisfy { term in
            let concept = Self.aliases.first { $0.0 == term || $0.1.english == term.lowercased() }?.1
            let variants = concept.map { $0.aliases + [$0.english] } ?? [term]
            return variants.contains { variant in
                if variant.range(of: Self.han, options: .regularExpression) != nil {
                    return text.localizedCaseInsensitiveContains(variant)
                }
                let escaped = NSRegularExpression.escapedPattern(for: variant)
                return text.range(of: "\\b\(escaped)\\b", options: [.regularExpression, .caseInsensitive]) != nil
            }
        }
    }
}
