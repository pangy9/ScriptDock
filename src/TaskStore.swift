import Foundation

final class TaskStore {
    let appSupportURL: URL
    let configURL: URL
    let logsURL: URL
    let launchAgentsURL: URL

    private(set) var tasks: [ScriptTask] = []

    convenience init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        self.init(appSupportURL: home.appendingPathComponent("Library/Application Support/ScriptDock", isDirectory: true))
    }

    init(appSupportURL: URL) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        self.appSupportURL = appSupportURL
        self.configURL = appSupportURL.appendingPathComponent("scripts.json")
        self.logsURL = appSupportURL.appendingPathComponent("logs", isDirectory: true)
        self.launchAgentsURL = home.appendingPathComponent("Library/LaunchAgents", isDirectory: true)
    }

    func ensureSupportFiles() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: appSupportURL, withIntermediateDirectories: true)
        try fm.createDirectory(at: logsURL, withIntermediateDirectories: true)
        if !fm.fileExists(atPath: configURL.path) {
            try defaultConfig().write(to: configURL, atomically: true, encoding: .utf8)
        }
    }

    func reload() -> (tasks: [ScriptTask], errors: [String: String]) {
        do {
            let data = try Data(contentsOf: configURL)
            let config = try JSONDecoder().decode(ScriptConfig.self, from: data)
            var validTasks: [ScriptTask] = []
            var errors: [String: String] = [:]  // taskID -> errorMessage
            for task in config.tasks {
                if let error = validate(task) {
                    errors[task.id] = error
                    validTasks.append(task)  // Include broken tasks too
                } else {
                    validTasks.append(task)
                }
            }
            self.tasks = validTasks
            return (validTasks, errors)
        } catch {
            self.tasks = []
            return ([], ["_config": "Failed to load config: \(error.localizedDescription)"])
        }
    }

    func task(byID id: String) -> ScriptTask? {
        tasks.first { $0.id == id }
    }

    func addOrUpdateTask(_ task: ScriptTask) throws {
        if let index = tasks.firstIndex(where: { $0.id == task.id }) {
            tasks[index] = task
        } else {
            tasks.append(task)
        }
        try saveConfig()
    }

    func removeTask(id: String) {
        tasks.removeAll { $0.id == id }
        try? saveConfig()
    }

    private func saveConfig() throws {
        let config = ScriptConfig(tasks: tasks)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(config)
        let tmpURL = configURL.deletingLastPathComponent().appendingPathComponent(".scripts.json.tmp")
        try data.write(to: tmpURL, options: .atomic)
        // Backup existing, then remove original so moveItem succeeds
        if FileManager.default.fileExists(atPath: configURL.path) {
            let bakURL = configURL.deletingLastPathComponent().appendingPathComponent("scripts.json.bak")
            try? FileManager.default.removeItem(at: bakURL)
            try? FileManager.default.copyItem(at: configURL, to: bakURL)
            try FileManager.default.removeItem(at: configURL)
        }
        try FileManager.default.moveItem(at: tmpURL, to: configURL)
    }

    func stdoutURL(for task: ScriptTask) -> URL {
        logsURL.appendingPathComponent("\(task.id).out.log")
    }

    func stderrURL(for task: ScriptTask) -> URL {
        logsURL.appendingPathComponent("\(task.id).err.log")
    }

    // MARK: - Validation

    func validate(_ task: ScriptTask) -> String? {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        if task.id.isEmpty || task.id.rangeOfCharacter(from: allowed.inverted) != nil {
            return "Invalid task id: \(task.id)"
        }
        if task.programArguments.isEmpty {
            return "Task has empty programArguments: \(task.name)"
        }
        if task.programArguments[0].contains("/") && !FileManager.default.isExecutableFile(atPath: task.programArguments[0]) {
            return "Program is not executable: \(task.programArguments[0])"
        }
        return argumentShapeProblem(for: task)
    }

    func preflightProblem(for task: ScriptTask) -> String? {
        if let shapeProblem = argumentShapeProblem(for: task) {
            return shapeProblem
        }

        if task.programArguments.isEmpty {
            return "\(task.name) has empty programArguments."
        }

        let executable = task.programArguments[0]
        if executable.contains("/") && !FileManager.default.isExecutableFile(atPath: executable) {
            return """
            Program is not executable or does not exist:
            \(executable)

            Task:
            \(task.name)
            """
        }

        for argument in task.programArguments.dropFirst() {
            if shouldValidatePathArgument(argument), !FileManager.default.fileExists(atPath: argument) {
                return """
                Config path does not exist:
                \(argument)

                Task:
                \(task.name)

                Edit:
                \(configURL.path)
                """
            }
        }

        if let cwd = task.workingDirectory, !FileManager.default.fileExists(atPath: cwd) {
            return """
            Working directory does not exist:
            \(cwd)

            Task:
            \(task.name)
            """
        }
        return nil
    }

    func argumentShapeProblem(for task: ScriptTask) -> String? {
        for (index, argument) in task.programArguments.enumerated() {
            if argument != argument.trimmingCharacters(in: .whitespacesAndNewlines) {
                return """
                Argument \(index) has leading or trailing whitespace:
                "\(argument)"

                ScriptDock passes argv directly to launchd. It does not split a shell command string for you.

                For example, use:
                ["ssh", "-v", "-p", "22222", "-N", "-L", "8080:127.0.0.1:8080", "user@example.com"]

                Task:
                \(task.name)
                """
            }
        }

        for (index, argument) in task.programArguments.dropFirst().enumerated() {
            if argument.contains(" ") {
                // Check if any space-separated part looks like a flag (starts with -)
                // This catches pasted shell fragments like "-p 22222 -N -L 8080:..."
                // but allows legitimate values like "Authorization: Bearer sk-key"
                let parts = argument.split(separator: " ")
                if parts.contains(where: { $0.hasPrefix("-") && $0.count > 1 }) {
                    return """
                    Argument \(index + 1) looks like a pasted shell tail instead of a single argv element:
                    "\(argument)"

                    ScriptDock expects one array item per argument. Split it explicitly.

                    For example, use:
                    ["ssh", "-v", "-p", "22222", "-N", "-L", "8080:127.0.0.1:8080", "user@example.com"]

                    Task:
                    \(task.name)
                    """
                }
            }
        }

        return nil
    }

    // MARK: - Private

    private func shouldValidatePathArgument(_ argument: String) -> Bool {
        if argument.isEmpty || argument.hasPrefix("-") { return false }
        if argument.hasPrefix("http://") || argument.hasPrefix("https://") { return false }
        if argument.hasPrefix("/") { return true }
        return argument.contains("/") && (argument.hasSuffix(".py") || argument.hasSuffix(".sh") || argument.hasSuffix(".js"))
    }

    private func defaultConfig() -> String {
        """
        {
          "tasks": []
        }
        """
    }
}
