import Foundation

/// 供应商托管工具类型（计划 §8 Hosted Tool）。
/// 托管工具由模型服务执行，不进入本地 Function Tool 的审批与执行链路。
enum HostedToolKind: String, Codable, Hashable, Sendable {
    case webSearch
}

enum HostedToolStatus: String, Codable, Sendable {
    case inProgress
    case searching
    case completed
}

enum HostedToolAction: Codable, Sendable, Equatable {
    case search(queries: [String])
    case openPage(url: String)
    case findInPage(url: String, pattern: String)

    private enum CodingKeys: String, CodingKey {
        case type
        case queries
        case url
        case pattern
    }

    private enum Kind: String, Codable {
        case search
        case openPage
        case findInPage
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .type) {
        case .search:
            self = .search(queries: try container.decodeIfPresent([String].self, forKey: .queries) ?? [])
        case .openPage:
            self = .openPage(url: try container.decode(String.self, forKey: .url))
        case .findInPage:
            self = .findInPage(
                url: try container.decode(String.self, forKey: .url),
                pattern: try container.decode(String.self, forKey: .pattern)
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .search(queries):
            try container.encode(Kind.search, forKey: .type)
            try container.encode(queries, forKey: .queries)
        case let .openPage(url):
            try container.encode(Kind.openPage, forKey: .type)
            try container.encode(url, forKey: .url)
        case let .findInPage(url, pattern):
            try container.encode(Kind.findInPage, forKey: .type)
            try container.encode(url, forKey: .url)
            try container.encode(pattern, forKey: .pattern)
        }
    }
}

struct HostedToolSource: Codable, Sendable, Equatable {
    let url: String
    let title: String?
}

struct HostedToolSnapshot: Codable, Sendable, Equatable {
    let id: String
    let kind: HostedToolKind
    var status: HostedToolStatus
    var action: HostedToolAction?
    var sources: [HostedToolSource]
}

struct TextCitation: Codable, Sendable, Equatable {
    let startIndex: Int
    let endIndex: Int
    let url: String
    let title: String?
}

struct TextContent: Codable, Sendable, Equatable {
    var text: String
    var citations: [TextCitation]

    init(text: String, citations: [TextCitation] = []) {
        self.text = text
        self.citations = citations
    }

    /// 把 Responses API 的 UTF-16 citation 区间转换成 Markdown 链接。
    /// 无效或互相重叠的区间不会破坏正文，而是在末尾追加编号链接。
    var citationMarkdown: String {
        let uniqueCitations = citations.deduplicated()
        guard !uniqueCitations.isEmpty else { return text }

        let utf16Count = text.utf16.count
        let sortedCitations = uniqueCitations.enumerated().map {
            (number: $0.offset + 1, citation: $0.element)
        }.sorted {
            if $0.citation.startIndex == $1.citation.startIndex {
                return $0.citation.endIndex < $1.citation.endIndex
            }
            return $0.citation.startIndex < $1.citation.startIndex
        }
        var accepted: [(number: Int, citation: TextCitation)] = []
        var fallback: [(number: Int, citation: TextCitation)] = []
        var lastAcceptedEndIndex = 0

        for entry in sortedCitations {
            let citation = entry.citation
            guard citation.hasSafeWebURL else { continue }
            let canLinkInline = citation.startIndex >= 0
                && citation.endIndex > citation.startIndex
                && citation.endIndex <= utf16Count
                && citation.startIndex >= lastAcceptedEndIndex
                && text.hasUTF16Boundary(at: citation.startIndex)
                && text.hasUTF16Boundary(at: citation.endIndex)
            if canLinkInline {
                accepted.append(entry)
                lastAcceptedEndIndex = citation.endIndex
            } else {
                fallback.append(entry)
            }
        }

        var markdown = text
        for entry in accepted.reversed() {
            let citation = entry.citation
            let start = String.Index(utf16Offset: citation.startIndex, in: markdown)
            let end = String.Index(utf16Offset: citation.endIndex, in: markdown)
            let label = markdown[start..<end]
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "[", with: "\\[")
                .replacingOccurrences(of: "]", with: "\\]")
            let destination = citation.url
                .replacingOccurrences(of: "<", with: "%3C")
                .replacingOccurrences(of: ">", with: "%3E")
            markdown.replaceSubrange(start..<end, with: "[\(label)](<\(destination)>)")
        }

        if !fallback.isEmpty {
            let markers = fallback.map { entry in
                let destination = entry.citation.url
                    .replacingOccurrences(of: "<", with: "%3C")
                    .replacingOccurrences(of: ">", with: "%3E")
                return "[\(entry.number)](<\(destination)>)"
            }.joined(separator: " ")
            markdown += " \(markers)"
        }
        return markdown
    }
}

/// 领域消息（计划 §13 Message：run 内有序内容片段）。
struct ChatMessage: Identifiable, Equatable, Sendable {
    enum Role: String, Sendable {
        case user
        case assistant
    }

    struct ToolCallSnapshot: Codable, Equatable, Sendable {
        let id: String
        let name: String
        let arguments: String
    }

    enum Part: Equatable, Sendable {
        case text(TextContent)
        case reasoning(String)
        case hostedTool(HostedToolSnapshot)
        case toolCall(ToolCallSnapshot)
    }

    let id: UUID
    let role: Role
    var parts: [Part]

    init(id: UUID = UUID(), role: Role, parts: [Part] = []) {
        self.id = id
        self.role = role
        self.parts = parts
    }

    init(id: UUID = UUID(), role: Role, text: String) {
        self.init(id: id, role: role, parts: [.text(TextContent(text: text))])
    }

    init(id: UUID = UUID(), role: Role, text: String, reasoning: String) {
        var parts: [Part] = []
        if !reasoning.isEmpty {
            parts.append(.reasoning(reasoning))
        }
        parts.append(.text(TextContent(text: text)))
        self.init(id: id, role: role, parts: parts)
    }

    var text: String {
        parts.compactMap { part -> String? in
            if case let .text(content) = part { return content.text }
            return nil
        }.joined()
    }

    var reasoning: String {
        parts.compactMap { part -> String? in
            if case let .reasoning(reasoning) = part { return reasoning }
            return nil
        }.joined()
    }

    var sources: [HostedToolSource] {
        var candidates: [HostedToolSource] = []
        for part in parts {
            switch part {
            case let .text(content):
                candidates.append(contentsOf: content.citations.map {
                    HostedToolSource(url: $0.url, title: $0.title)
                })
            case let .hostedTool(tool):
                candidates.append(contentsOf: tool.sources)
            case .reasoning, .toolCall:
                break
            }
        }
        return candidates.deduplicatedByURL()
    }

    var isEmpty: Bool {
        parts.isEmpty
    }

    mutating func appendText(_ delta: String) {
        guard !parts.isEmpty else {
            parts.append(.text(TextContent(text: delta)))
            return
        }
        let lastIndex = parts.count - 1
        switch parts[lastIndex] {
        case var .text(content):
            content.text += delta
            parts[lastIndex] = .text(content)
        default:
            parts.append(.text(TextContent(text: delta)))
        }
    }

    mutating func appendReasoning(_ delta: String) {
        guard !parts.isEmpty else {
            parts.append(.reasoning(delta))
            return
        }
        let lastIndex = parts.count - 1
        switch parts[lastIndex] {
        case var .reasoning(reasoning):
            reasoning += delta
            parts[lastIndex] = .reasoning(reasoning)
        default:
            parts.append(.reasoning(delta))
        }
    }

    mutating func upsertHostedTool(_ snapshot: HostedToolSnapshot) {
        if let index = parts.firstIndex(where: {
            if case let .hostedTool(tool) = $0 { return tool.id == snapshot.id }
            return false
        }) {
            parts[index] = .hostedTool(snapshot)
        } else {
            parts.append(.hostedTool(snapshot))
        }
    }

    mutating func appendCitation(_ citation: TextCitation) {
        guard !parts.containsCitation(citation) else { return }
        if let index = parts.lastIndex(where: {
            if case .text = $0 { return true }
            return false
        }), case var .text(content) = parts[index] {
            content.citations.append(citation)
            parts[index] = .text(content)
        } else {
            parts.append(.text(TextContent(text: "", citations: [citation])))
        }
    }
}

private extension String {
    func hasUTF16Boundary(at offset: Int) -> Bool {
        guard offset >= 0, offset <= utf16.count else { return false }
        let utf16Index = utf16.index(utf16.startIndex, offsetBy: offset)
        return String.Index(utf16Index, within: self) != nil
    }
}

private extension TextCitation {
    var hasSafeWebURL: Bool {
        guard let url = URL(string: url), let scheme = url.scheme?.lowercased() else {
            return false
        }
        return scheme == "https" || scheme == "http"
    }
}

private extension Array where Element == ChatMessage.Part {
    func containsCitation(_ citation: TextCitation) -> Bool {
        contains { part in
            guard case let .text(content) = part else { return false }
            return content.citations.contains {
                $0.url == citation.url
                    && $0.startIndex == citation.startIndex
                    && $0.endIndex == citation.endIndex
            }
        }
    }
}

private extension Array where Element == TextCitation {
    func deduplicated() -> [TextCitation] {
        var keys = Set<String>()
        return filter { keys.insert("\($0.startIndex):\($0.endIndex):\($0.url)").inserted }
    }
}

private extension Array where Element == HostedToolSource {
    func deduplicatedByURL() -> [HostedToolSource] {
        var keys = Set<String>()
        return filter { source in
            keys.insert(source.normalizedURLKey).inserted
        }
    }
}

extension HostedToolSource {
    nonisolated var normalizedURLKey: String {
        guard var components = URLComponents(string: url) else { return url }
        components.scheme = components.scheme?.lowercased()
        components.host = components.host?.lowercased()
        components.fragment = nil
        if components.port == 80, components.scheme == "http" {
            components.port = nil
        } else if components.port == 443, components.scheme == "https" {
            components.port = nil
        }
        return components.string ?? url
    }
}
