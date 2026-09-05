import Foundation

struct AgentBackendConfiguration {
    let backends: [AgentID: AgentBackend]
    let executableURLs: [AgentID: URL]

    init(executableURLs: [AgentID: URL], localAgents: [LocalAgentConfiguration] = []) {
        self.executableURLs = executableURLs
        var backends: [AgentID: AgentBackend] = [:]

        if let executableURL = executableURLs[.codex] {
            backends[.codex] = CodexBackend(executableURL: executableURL)
        }
        if let executableURL = executableURLs[.opencode] {
            backends[.opencode] = OpenCodeBackend(executableURL: executableURL)
        }
        for agent in localAgents {
            let kind = AgentID.acp(id: agent.id)
            if let executableURL = executableURLs[kind] {
                backends[kind] = ACPBackend(executableURL: executableURL, arguments: agent.arguments)
            }
        }
        self.backends = backends
    }

    static func discover(environment: [String: String]) -> AgentBackendConfiguration {
        AgentBackendConfiguration(
            executableURLs: discoverExecutableURLs(environment: environment)
        )
    }

    static func discoverExecutableURLs(
        environment: [String: String] = ExecutableLocator.environmentIncludingLoginShell()
    ) -> [AgentID: URL] {
        var executableURLs: [AgentID: URL] = [:]
        if let executableURL = ExecutableLocator.locate("codex", environment: environment) {
            executableURLs[.codex] = executableURL
        }
        if let executableURL = ExecutableLocator.locate("opencode", environment: environment) {
            executableURLs[.opencode] = executableURL
        }
        return executableURLs
    }
}

struct AppDependencies {
    let databaseURL: URL
    let store: SQLiteStore
    let agentHost: AgentHost

    static func live(eventHandler: @escaping AgentHost.EventHandler) throws -> AppDependencies {
        let environment = try AppEnvironment.live()
        let store = try SQLiteStore(databaseURL: environment.databaseURL)
        let localAgents = try LocalAgentConfigurationStore().load()
        var executableURLs = AgentBackendConfiguration.discoverExecutableURLs(
            environment: ProcessInfo.processInfo.environment
        )
        for agent in localAgents {
            executableURLs[.acp(id: agent.id)] = ExecutableLocator.locate(agent.command)
        }
        let backendConfiguration = AgentBackendConfiguration(executableURLs: executableURLs, localAgents: localAgents)

        return AppDependencies(
            databaseURL: environment.databaseURL,
            store: store,
            agentHost: AgentHost(
                store: store,
                eventHandler: eventHandler,
                backends: backendConfiguration.backends,
                executableURLs: backendConfiguration.executableURLs,
                localAgents: localAgents,
                localAgentProvider: { try LocalAgentConfigurationStore().load() },
                executableURLProvider: {
                    await Task.detached(priority: .utility) {
                        AgentBackendConfiguration.discoverExecutableURLs()
                    }.value
                }
            )
        )
    }
}
