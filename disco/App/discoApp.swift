//
//  discoApp.swift
//  disco
//
//  Created by 闫柯玮 on 2026/8/4.
//

import SwiftUI

@main
struct DiscoApp: App {
    @StateObject private var appState: AppState

    init() {
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            _appState = StateObject(
                wrappedValue: AppState(
                    keychain: InMemoryAuthStore(),
                    persistence: VolatileConversationPersistence()
                )
            )
        } else {
            _appState = StateObject(wrappedValue: AppState())
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
                .tint(DiscoTheme.accent)
                .frame(minWidth: 820, minHeight: 560)
        }
        .defaultSize(width: 1120, height: 760)
        .windowToolbarStyle(.unified(showsTitle: false))

        Settings {
            SettingsView()
                .environmentObject(appState)
                .tint(DiscoTheme.accent)
        }
    }
}
