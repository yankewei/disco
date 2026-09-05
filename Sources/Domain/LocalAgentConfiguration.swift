import Foundation

struct LocalAgentConfiguration: Codable, Identifiable, Hashable {
    let id: String
    var name: String
    var command: String
    var arguments: [String]

    static let presets: [LocalAgentConfiguration] = [
        .init(id: "kimi", name: "Kimi", command: "kimi", arguments: ["acp"]),
        .init(id: "pi", name: "pi", command: "pi-acp", arguments: []),
    ]
}
