import Foundation

struct ScriptConfig: Codable {
    var tasks: [ScriptTask]
}

enum UserPath {
    static func expandingTilde(_ value: String) -> String {
        guard value == "~" || value.hasPrefix("~/") else { return value }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        guard value != "~" else { return home }
        return URL(fileURLWithPath: home)
            .appendingPathComponent(String(value.dropFirst(2)))
            .path
    }
}

struct ScriptTask: Codable {
    var id: String
    var name: String
    var programArguments: [String]
    var workingDirectory: String?
    var runAtLoad: Bool?
    var keepAlive: Bool?
    var openURL: String?
    var ports: [Int]?
    var environment: [String: String]?
    var optionalArguments: [OptionalArgument]?
    var keepRunningOnQuit: Bool?
    var mode: TaskMode?

    var label: String {
        "com.pangyun.ScriptDock.\(id)"
    }

    var effectiveMode: TaskMode {
        mode ?? ((keepAlive == true || runAtLoad == true) ? .daemon : .oneshot)
    }
}

enum TaskMode: String, Codable {
    case daemon    // 常驻进程，崩溃自动重启
    case oneshot   // 一次性执行，完成后停止
}

struct PortOwner: Codable {
    var port: Int
    var pid: Int32
    var command: String
    var endpoint: String
}

enum LogStream {
    case stdout
    case stderr
}

enum TaskState: String, Codable {
    case stopped
    case running
    case errored
}

struct TaskStatus: Codable {
    let id: String
    let name: String
    let state: TaskState
    let pid: Int32?
    let exitCode: Int32?
    let startedAt: Date?
    let lastError: String?
    let ports: [Int]?
    let runningDuration: TimeInterval?
    let startedBy: String?   // "mcp", "manual", "auto", or nil
}

/// A pre-defined optional argument that can be toggled at task start
struct OptionalArgument: Codable {
    var label: String       // e.g. "Verbose output"
    var argument: String    // e.g. "--verbose"
    var requiresValue: Bool // e.g. true for "--port=XXXX"
    var defaultValue: String? // e.g. "8080" for --port
}
