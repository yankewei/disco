import Foundation

struct AgentBackendConfiguration {
    let backends: [BackendKind: AgentBackend]
    let executableURLs: [BackendKind: URL]

    init(executableURLs: [BackendKind: URL]) {
        self.executableURLs = executableURLs
        var backends: [BackendKind: AgentBackend] = [:]

        if let executableURL = executableURLs[.codex] {
            backends[.codex] = CodexBackend(executableURL: executableURL)
        }
        if let executableURL = executableURLs[.opencode] {
            backends[.opencode] = OpenCodeBackend(executableURL: executableURL)
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
    ) -> [BackendKind: URL] {
        var executableURLs: [BackendKind: URL] = [:]
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
        let backendConfiguration = AgentBackendConfiguration.discover(
            environment: ProcessInfo.processInfo.environment
        )

        return AppDependencies(
            databaseURL: environment.databaseURL,
            store: store,
            agentHost: AgentHost(
                store: store,
                eventHandler: eventHandler,
                backends: backendConfiguration.backends,
                executableURLs: backendConfiguration.executableURLs,
                executableURLProvider: {
                    await Task.detached(priority: .utility) {
                        AgentBackendConfiguration.discoverExecutableURLs()
                    }.value
                }
            )
        )
    }
}
