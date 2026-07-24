import Foundation

// MARK: - MCP Protocol Types

struct MCPRequest: Decodable {
    let jsonrpc: String
    let id: Int?
    let method: String
    let params: [String: JSONValue]?
}

enum JSONValue: Decodable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case null
    case array([JSONValue])
    case object([String: JSONValue])

    var stringValue: String? {
        if case .string(let v) = self { return v }
        return nil
    }

    var intValue: Int? {
        if case .int(let v) = self { return v }
        return nil
    }

    var stringValueOrDefault: String {
        stringValue ?? ""
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let v = try? container.decode(String.self) { self = .string(v) }
        else if let v = try? container.decode(Int.self) { self = .int(v) }
        else if let v = try? container.decode(Double.self) { self = .double(v) }
        else if let v = try? container.decode(Bool.self) { self = .bool(v) }
        else if let v = try? container.decode([JSONValue].self) { self = .array(v) }
        else if let v = try? container.decode([String: JSONValue].self) { self = .object(v) }
        else { self = .null }
    }
}

// MARK: - MCP Server

final class MCPServer {
    private let client = SupervisorClient.shared

    func run() {
        let input = FileHandle.standardInput
        var buffer = Data()

        while true {
            let chunk = input.availableData
            if chunk.isEmpty { break }
            buffer.append(chunk)

            // Try Content-Length framing first (standard MCP transport)
            while let message = tryExtractFramedMessage(from: &buffer) {
                processLine(message)
            }

            // Fallback: newline-delimited JSON
            while let newlineRange = buffer.range(of: Data("\n".utf8)) {
                let lineData = buffer[buffer.startIndex..<newlineRange.lowerBound]
                buffer = buffer[newlineRange.upperBound..<buffer.endIndex]
                guard let line = String(data: lineData, encoding: .utf8) else { continue }
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { processLine(trimmed) }
            }
        }
    }

    private func tryExtractFramedMessage(from buffer: inout Data) -> String? {
        guard let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let headerData = buffer[buffer.startIndex..<headerEnd.lowerBound]
        guard let headerStr = String(data: headerData, encoding: .utf8) else { return nil }

        for line in headerStr.components(separatedBy: "\r\n") {
            if line.hasPrefix("Content-Length:") {
                let lengthStr = line.dropFirst("Content-Length:".count).trimmingCharacters(in: .whitespaces)
                guard let length = Int(lengthStr) else { return nil }
                let bodyStart = headerEnd.upperBound
                let bodyEnd = bodyStart + length
                guard bodyEnd <= buffer.endIndex else { return nil }
                let body = buffer[bodyStart..<bodyEnd]
                buffer = buffer[bodyEnd..<buffer.endIndex]
                return String(data: body, encoding: .utf8)
            }
        }
        return nil
    }

    private func processLine(_ line: String) {
        guard !line.isEmpty else { return }
        guard let data = line.data(using: .utf8),
              let request = try? JSONDecoder().decode(MCPRequest.self, from: data) else {
            sendError(id: nil, code: -32700, message: "Parse error")
            return
        }

        let result: [String: Any]
        switch request.method {
        case "initialize":
            result = initialize(params: request.params)
        case "tools/list":
            result = listTools()
        case "tools/call":
            result = callTool(params: request.params)
        case "notifications/initialized":
            return  // No response needed
        default:
            sendError(id: request.id, code: -32601, message: "Method not found: \(request.method)")
            return
        }

        sendResult(id: request.id, result: result)
    }

    // MARK: - Protocol Methods

    private func initialize(params: [String: JSONValue]?) -> [String: Any] {
        [
            "protocolVersion": "2024-11-05",
            "capabilities": ["tools": [:]] as [String: Any],
            "serverInfo": [
                "name": "ScriptDock",
                "version": "1.0.0"
            ]
        ]
    }

    private func listTools() -> [String: Any] {
        [
            "tools": [
                toolDef("list_processes", "List all registered processes with their status", [:]),
                toolDef("start_process", "Start a process by ID",
                    ["id": ["type": "string", "description": "Task ID"]]),
                toolDef("stop_process", "Stop a running process by ID",
                    ["id": ["type": "string", "description": "Task ID"]]),
                toolDef("restart_process", "Restart a process by ID",
                    ["id": ["type": "string", "description": "Task ID"]]),
                toolDef("get_process_status", "Get detailed status of a process",
                    ["id": ["type": "string", "description": "Task ID"]]),
                toolDef("get_process_logs", "Get recent logs for a process",
                    ["id": ["type": "string", "description": "Task ID"],
                     "stream": ["type": "string", "description": "stdout or stderr", "default": "stdout"],
                     "since": ["type": "integer", "description": "Byte offset to read from", "default": 0]]),
                toolDef("check_ports", "Check which processes are using specified ports",
                    ["ports": ["type": "string", "description": "Comma-separated port numbers"]]),
                toolDef("kill_port_blockers", "Kill processes blocking specified ports",
                    ["pids": ["type": "string", "description": "Comma-separated PIDs to kill"]]),
                toolDef("register_process", "Register a new process in ScriptDock config",
                    ["id": ["type": "string", "description": "Unique task ID"],
                     "name": ["type": "string", "description": "Display name"],
                     "command": ["type": "string", "description": "Shell command to run"],
                     "workingDirectory": ["type": "string", "description": "Working directory path"]])
            ]
        ]
    }

    private func toolDef(_ name: String, _ description: String, _ inputSchema: [String: Any]) -> [String: Any] {
        ["name": name, "description": description, "inputSchema": ["type": "object", "properties": inputSchema]]
    }

    // MARK: - Tool Execution

    private func callTool(params: [String: JSONValue]?) -> [String: Any] {
        guard let params,
              let toolName = params["name"]?.stringValue else {
            return ["content": [["type": "text", "text": "Missing tool name"]], "isError": true]
        }

        switch toolName {
        case "list_processes":
            return textResult(formatProcessList())
        case "start_process":
            return textResult(client.startTask(id: param(params, "id"), source: "mcp") ?? "Started \(param(params, "id"))")
        case "stop_process":
            return textResult(client.stopTask(id: param(params, "id")) ?? "Stopped \(param(params, "id"))")
        case "restart_process":
            return textResult(client.restartTask(id: param(params, "id"), source: "mcp") ?? "Restarted \(param(params, "id"))")
        case "get_process_status":
            return textResult(formatStatus(id: param(params, "id")))
        case "get_process_logs":
            return textResult(formatLogs(params: params))
        case "check_ports":
            return textResult(formatPortCheck(params: params))
        case "kill_port_blockers":
            return textResult(formatKillPorts(params: params))
        case "register_process":
            return textResult(formatRegister(params: params))
        default:
            return textResult("Unknown tool: \(toolName)")
        }
    }

    // MARK: - Tool Implementations

    private func formatProcessList() -> String {
        guard let statuses = client.allStatuses() else {
            return "Cannot connect to ScriptDockSupervisor"
        }
        if statuses.isEmpty { return "No processes registered." }
        return statuses.map { s in
            let state = s.state.rawValue
            let pid = s.pid.map { " pid=\($0)" } ?? ""
            let dur = s.runningDuration.map { String(format: " uptime=%.0fs", $0) } ?? ""
            let retry = if s.state == .retrying {
                " attempt=\(s.retryAttempt ?? 1) retry_in=\(max(0, Int(ceil(s.nextRetryAt?.timeIntervalSinceNow ?? 0))))s"
            } else {
                ""
            }
            return "\(s.id): \(s.name) [\(state)]\(pid)\(dur)\(retry)"
        }.joined(separator: "\n")
    }

    private func formatStatus(id: String) -> String {
        guard let status = client.taskStatus(id: id) else {
            return "Task not found: \(id)"
        }
        var lines = [
            "ID: \(status.id)",
            "Name: \(status.name)",
            "State: \(status.state.rawValue)",
        ]
        if let pid = status.pid { lines.append("PID: \(pid)") }
        if let exit = status.exitCode { lines.append("Exit code: \(exit)") }
        if let started = status.startedAt { lines.append("Started: \(started)") }
        if let dur = status.runningDuration { lines.append(String(format: "Duration: %.0fs", dur)) }
        if status.state == .retrying {
            lines.append("Retry attempt: \(status.retryAttempt ?? 1)")
            if let nextRetryAt = status.nextRetryAt {
                lines.append("Next retry: \(nextRetryAt)")
                lines.append("Retry in: \(max(0, Int(ceil(nextRetryAt.timeIntervalSinceNow))))s")
            }
        }
        if let err = status.lastError { lines.append("Last error: \(err)") }
        if let ports = status.ports, !ports.isEmpty {
            lines.append("Ports: \(ports.map(String.init).joined(separator: ", "))")
        }
        return lines.joined(separator: "\n")
    }

    private func formatLogs(params: [String: JSONValue]) -> String {
        let id = param(params, "id")
        let stream: LogStream = param(params, "stream") == "stderr" ? .stderr : .stdout
        guard let result = client.logs(id: id, stream: stream) else {
            return "Task not found or no logs: \(id)"
        }
        return result.text.isEmpty ? "(no logs)" : result.text
    }

    private func formatPortCheck(params: [String: JSONValue]) -> String {
        let portStr = param(params, "ports")
        let ports = portStr.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        guard let owners = client.portCheck(ports: ports) else {
            return "Cannot check ports"
        }
        if owners.isEmpty { return "All specified ports are free." }
        return owners.map { "\($0.port): \($0.command) pid=\($0.pid) \($0.endpoint)" }.joined(separator: "\n")
    }

    private func formatKillPorts(params: [String: JSONValue]) -> String {
        let pidStr = param(params, "pids")
        let pids = pidStr.split(separator: ",").compactMap { Int32($0.trimmingCharacters(in: .whitespaces)) }
        guard let result = client.killPorts(pids: pids) else {
            return "Cannot kill processes"
        }
        return "Killed: \(result.killed.map(String.init).joined(separator: ", ")), Failed: \(result.failed.map(String.init).joined(separator: ", "))"
    }

    private func formatRegister(params: [String: JSONValue]) -> String {
        let id = param(params, "id")
        let name = param(params, "name")
        let command = param(params, "command")
        let workDir = param(params, "workingDirectory")

        if id.isEmpty || name.isEmpty || command.isEmpty {
            return "Error: id, name, and command are required."
        }

        // Validate working directory if provided
        if !workDir.isEmpty && !FileManager.default.fileExists(atPath: UserPath.expandingTilde(workDir)) {
            return "Error: working directory does not exist: \(workDir)"
        }

        // Validate ID format
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        if id.rangeOfCharacter(from: allowed.inverted) != nil {
            return "Error: ID can only contain letters, numbers, dots, dashes, underscores."
        }

        // Parse command into args
        var args: [String] = []
        var current = ""
        var inQuote = false
        for char in command {
            if char == "\"" { inQuote.toggle() }
            else if char == " " && !inQuote {
                if !current.isEmpty { args.append(current); current = "" }
            } else { current.append(char) }
        }
        if !current.isEmpty { args.append(current) }

        let task = ScriptTask(
            id: id, name: name, programArguments: args,
            workingDirectory: workDir.isEmpty ? nil : workDir
        )

        let store = TaskStore()
        do {
            try store.addOrUpdateTask(task)
            return "Registered: \(id)"
        } catch {
            return "Error: \(error.localizedDescription)"
        }
    }

    // MARK: - Helpers

    private func param(_ params: [String: JSONValue], _ key: String) -> String {
        // MCP tools/call puts arguments inside params["arguments"]
        if case .object(let dict) = params["arguments"] {
            return dict[key]?.stringValueOrDefault ?? ""
        }
        return params[key]?.stringValueOrDefault ?? ""
    }

    private func textResult(_ text: String) -> [String: Any] {
        ["content": [["type": "text", "text": text]]]
    }

    private func sendResult(id: Int?, result: [String: Any]) {
        var response: [String: Any] = ["jsonrpc": "2.0", "result": result]
        if let id { response["id"] = id }
        sendJSON(response)
    }

    private func sendError(id: Int?, code: Int, message: String) {
        var response: [String: Any] = [
            "jsonrpc": "2.0",
            "error": ["code": code, "message": message]
        ]
        if let id { response["id"] = id }
        sendJSON(response)
    }

    private func sendJSON(_ dict: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: dict),
              var str = String(data: data, encoding: .utf8) else { return }
        str.append("\n")
        FileHandle.standardOutput.write(Data(str.utf8))
    }
}

// MARK: - Entry Point

@main
struct MCPMain {
    static func main() {
        let server = MCPServer()
        server.run()
    }
}
