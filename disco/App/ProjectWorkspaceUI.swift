import AppKit

/// Project 目录选择的 AppKit 边界；AppState 只接收已选 URL。
enum ProjectDirectoryPicker {
    enum Mode {
        case openProject
        case reconnect(initialDirectory: URL?)

        var prompt: String {
            switch self {
            case .openProject: return "打开项目"
            case .reconnect: return "重新关联"
            }
        }

        var message: String {
            switch self {
            case .openProject: return "选择一个可读目录作为 Project 工作区"
            case .reconnect: return "选择新的 Project 工作区目录"
            }
        }
    }

    static func chooseDirectory(mode: Mode) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.prompt = mode.prompt
        panel.message = mode.message
        if case let .reconnect(initialDirectory?) = mode,
           FileManager.default.fileExists(atPath: initialDirectory.path) {
            panel.directoryURL = initialDirectory
        }
        return panel.runModal() == .OK ? panel.url : nil
    }
}
