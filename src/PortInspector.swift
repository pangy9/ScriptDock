import Darwin
import Foundation

enum PortInspector {
    static func isValidPort(_ port: Int) -> Bool {
        (1...65535).contains(port)
    }

    static func inferredPorts(for task: ScriptTask) -> [Int] {
        var ports = Set<Int>()
        for port in task.ports ?? [] {
            if isValidPort(port) { ports.insert(port) }
        }
        if let rawURL = task.openURL, let url = URLComponents(string: rawURL), let port = url.port, isValidPort(port) {
            ports.insert(port)
        }

        let args = task.programArguments
        for (index, argument) in args.enumerated() {
            if argument.hasPrefix("http://") || argument.hasPrefix("https://") {
                if let url = URLComponents(string: argument), let port = url.port, isValidPort(port) {
                    ports.insert(port)
                }
            }
            if argument == "--port", index + 1 < args.count, let port = Int(args[index + 1]), isValidPort(port) {
                ports.insert(port)
            }
            if argument.hasPrefix("--port=") {
                let value = String(argument.dropFirst("--port=".count))
                if let port = Int(value), isValidPort(port) {
                    ports.insert(port)
                }
            }
            if argument == "-L", index + 1 < args.count {
                ports.formUnion(portsFromForwardSpec(args[index + 1]))
            } else if argument.hasPrefix("-L"), argument.count > 2 {
                ports.formUnion(portsFromForwardSpec(String(argument.dropFirst(2))))
            }
        }

        for (key, value) in task.environment ?? [:] {
            if key.uppercased().contains("PORT"), let port = Int(value), isValidPort(port) {
                ports.insert(port)
            }
        }
        return ports.sorted()
    }

    static func portOwners(for port: Int) -> [PortOwner] {
        let result = ProcessRunner.run(
            "/usr/sbin/lsof",
            arguments: ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN", "-Fpcn"]
        )
        guard result.status == 0 else { return [] }

        var owners: [PortOwner] = []
        var pid: Int32?
        var command = ""
        var endpoint = ""

        func flush() {
            guard let pid else { return }
            owners.append(PortOwner(port: port, pid: pid, command: command.isEmpty ? "unknown" : command, endpoint: endpoint))
        }

        for line in result.output.split(separator: "\n") {
            guard let marker = line.first else { continue }
            let value = String(line.dropFirst())
            switch marker {
            case "p":
                flush()
                pid = Int32(value)
                command = ""
                endpoint = ""
            case "c":
                command = value
            case "n":
                endpoint = value
            default:
                continue
            }
        }
        flush()
        return owners
    }

    static func portOwners(for ports: [Int]) -> [PortOwner] {
        ports.flatMap { portOwners(for: $0) }
    }

    /// Ports the task will bind/listen on (from explicit `ports` field and --port args).
    /// These are the only ports that should be checked for conflicts before starting.
    static func bindingPorts(for task: ScriptTask) -> [Int] {
        var ports = Set<Int>()
        for port in task.ports ?? [] {
            if isValidPort(port) { ports.insert(port) }
        }
        let args = task.programArguments
        for (index, argument) in args.enumerated() {
            if argument == "--port", index + 1 < args.count, let port = Int(args[index + 1]), isValidPort(port) {
                ports.insert(port)
            }
            if argument.hasPrefix("--port=") {
                let value = String(argument.dropFirst("--port=".count))
                if let port = Int(value), isValidPort(port) {
                    ports.insert(port)
                }
            }
            if argument == "-L", index + 1 < args.count {
                ports.formUnion(portsFromForwardSpec(args[index + 1]))
            } else if argument.hasPrefix("-L"), argument.count > 2 {
                ports.formUnion(portsFromForwardSpec(String(argument.dropFirst(2))))
            }
        }
        for (key, value) in task.environment ?? [:] {
            if key.uppercased().contains("PORT"), let port = Int(value), isValidPort(port) {
                ports.insert(port)
            }
        }
        return ports.sorted()
    }

    static func blockingPortOwners(for task: ScriptTask, taskPid: Int32?) -> [PortOwner] {
        portOwners(for: bindingPorts(for: task)).filter { owner in
            guard let taskPid else { return true }
            return owner.pid != taskPid
        }
    }

    static func portReport(for task: ScriptTask) -> String {
        let ports = inferredPorts(for: task)
        if ports.isEmpty {
            return "\(task.name) has no configured or inferred ports."
        }
        let owners = portOwners(for: ports)
        if owners.isEmpty {
            return """
            Ports for \(task.name)

            \(ports.map { "\($0): free" }.joined(separator: "\n"))
            """
        }
        return """
        Ports for \(task.name)

        \(formatPortOwners(owners))
        """
    }

    static func formatPortOwners(_ owners: [PortOwner]) -> String {
        owners.map { owner in
            let endpoint = owner.endpoint.isEmpty ? "port \(owner.port)" : owner.endpoint
            return "\(owner.port): \(owner.command) pid=\(owner.pid) \(endpoint)"
        }.joined(separator: "\n")
    }

    static func killPIDs(_ pids: [Int32]) -> (killed: [Int32], failed: [Int32]) {
        var killed: [Int32] = []
        var failed: [Int32] = []
        for pid in pids {
            if kill(pid, SIGTERM) == 0 {
                killed.append(pid)
            } else {
                failed.append(pid)
            }
        }
        return (killed, failed)
    }

    // MARK: - Private

    private static func portsFromForwardSpec(_ value: String) -> [Int] {
        let pieces = value.split(separator: ":", maxSplits: 1).map(String.init)
        guard let first = pieces.first, let port = Int(first), isValidPort(port) else {
            return []
        }
        return [port]
    }
}
