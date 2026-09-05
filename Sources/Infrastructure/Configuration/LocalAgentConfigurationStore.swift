import Foundation

struct LocalAgentConfigurationStore {
    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() throws -> [LocalAgentConfiguration] {
        guard let data = defaults.data(forKey: "acpAgentConfigurations") else {
            return LocalAgentConfiguration.presets
        }
        return try JSONDecoder().decode([LocalAgentConfiguration].self, from: data)
    }

    func save(_ configurations: [LocalAgentConfiguration]) throws {
        let data = try JSONEncoder().encode(configurations)
        defaults.set(data, forKey: "acpAgentConfigurations")
    }
}
