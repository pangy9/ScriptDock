import Darwin
import Foundation

// MARK: - Ring Buffer

final class RingBuffer {
    private let maxSize: Int
    private var buffer = Data()
    private let lock = NSLock()

    init(maxSize: Int = 5 * 1024 * 1024) { // 5 MB
        self.maxSize = maxSize
    }

    func append(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        buffer.append(data)
        if buffer.count > maxSize {
            let excess = buffer.count - maxSize
            buffer = buffer.subdata(in: excess..<buffer.count)
        }
    }

    func read() -> Data {
        lock.lock()
        defer { lock.unlock() }
        return buffer
    }

    func read(since offset: Int) -> Data {
        lock.lock()
        defer { lock.unlock() }
        guard offset < buffer.count else { return Data() }
        return buffer.subdata(in: offset..<buffer.count)
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return buffer.count
    }

    func clear() {
        lock.lock()
        defer { lock.unlock() }
        buffer.removeAll(keepingCapacity: true)
    }
}

// 任务状态变化通知 —— 取代 UI 轮询。ManagedTask.state 变化时 post，监听方按需刷新（如 menu bar 标题）。
extension Notification.Name {
    static let scriptDockTaskStateChanged = Notification.Name("ScriptDockTaskStateChanged")
}

// MARK: - Managed Task

final class ManagedTask {
    var config: ScriptTask
    var state: TaskState = .stopped {
        didSet {
            let taskID = config.id
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .scriptDockTaskStateChanged, object: taskID)
            }
        }
    }
    var pid: Int32?
    var exitCode: Int32?
    var startedAt: Date?
    var lastError: String?
    var startedBy: String?
    var stoppedManually = false
    var retryAttempt = 0
    var nextRetryAt: Date?
    var pendingRetry: DispatchWorkItem?
    var retryGeneration: UInt = 0
    var restartRequested = false
    var restartSource: String?
    let stdoutBuffer = RingBuffer()
    let stderrBuffer = RingBuffer()
    private var process: Process?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?
    private var stdoutHandle: FileHandle?
    private var stderrHandle: FileHandle?

    init(config: ScriptTask) {
        self.config = config
    }

    private static func timestamp() -> String {
        var tv = timeval()
        gettimeofday(&tv, nil)
        var time = time_t(tv.tv_sec)
        var tm = tm()
        localtime_r(&time, &tm)
        return String(format: "%02d:%02d:%02d", tm.tm_hour, tm.tm_min, tm.tm_sec)
    }

    static func injectTimestamps(_ data: Data) -> Data {
        guard let text = String(data: data, encoding: .utf8), !text.isEmpty else { return data }
        let ts = timestamp()
        var lines = text.components(separatedBy: "\n")
        if let last = lines.last, last.isEmpty { lines.removeLast() }
        guard !lines.isEmpty else { return data }
        var result = lines.map { "[\(ts)] \($0)" }.joined(separator: "\n")
        if text.hasSuffix("\n") { result += "\n" }
        return Data(result.utf8)
    }

    static func resolveExecutable(_ path: String) -> String {
        let expandedPath = UserPath.expandingTilde(path)
        if expandedPath.contains("/") { return expandedPath }
        let result = ProcessRunner.run("/usr/bin/which", arguments: [expandedPath])
        if result.status == 0 {
            return result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return expandedPath
    }

    var status: TaskStatus {
        let duration: TimeInterval?
        if let started = startedAt, state == .running {
            duration = Date().timeIntervalSince(started)
        } else {
            duration = nil
        }
        return TaskStatus(
            id: config.id,
            name: config.name,
            state: state,
            pid: pid,
            exitCode: exitCode,
            startedAt: startedAt,
            lastError: lastError,
            ports: config.ports,
            runningDuration: duration,
            startedBy: startedBy,
            retryAttempt: state == .retrying ? retryAttempt : nil,
            nextRetryAt: state == .retrying ? nextRetryAt : nil
        )
    }

    func start(
        logsURL: URL,
        source: String? = nil,
        extraArgs: [String]? = nil,
        onExit: @escaping (ManagedTask, Int32) -> Void
    ) throws {
        guard state != .running else { return }
        self.startedBy = source

        // Clear buffers and files for a fresh run
        stdoutBuffer.clear()
        stderrBuffer.clear()

        let allArgs = (config.programArguments + (extraArgs ?? [])).map(UserPath.expandingTilde)
        let process = Process()
        let executable = ManagedTask.resolveExecutable(allArgs[0])
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = Array(allArgs.dropFirst())
        let workingDirectory = config.workingDirectory.map(UserPath.expandingTilde)
            ?? FileManager.default.homeDirectoryForCurrentUser.path
        process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory)

        var environment = ProcessInfo.processInfo.environment
        environment["PYTHONUNBUFFERED"] = "1"
        if let env = config.environment {
            for (key, value) in env {
                environment[key] = value
            }
        }
        process.environment = environment

        let stdoutURL = logsURL.appendingPathComponent("\(config.id).out.log")
        let stderrURL = logsURL.appendingPathComponent("\(config.id).err.log")
        // Truncate log files for a fresh run
        try? "".write(to: stdoutURL, atomically: true, encoding: .utf8)
        try? "".write(to: stderrURL, atomically: true, encoding: .utf8)

        let stdoutHandle = try FileHandle(forWritingTo: stdoutURL)
        let stderrHandle = try FileHandle(forWritingTo: stderrURL)
        try stdoutHandle.seekToEnd()
        try stderrHandle.seekToEnd()

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let usesPipeLogging = config.keepRunningOnQuit != true
        if usesPipeLogging {
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe
        } else {
            process.standardOutput = stdoutHandle
            process.standardError = stderrHandle
        }

        self.process = process
        self.stdoutPipe = usesPipeLogging ? stdoutPipe : nil
        self.stderrPipe = usesPipeLogging ? stderrPipe : nil
        self.stdoutHandle = stdoutHandle
        self.stderrHandle = stderrHandle

        if usesPipeLogging {
            // Read stdout into ring buffer + file (with timestamp injection)
            stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                guard !data.isEmpty else {
                    // EOF：子进程关闭了该输出流（典型如 ssh -N）。
                    // 不注销的话 GCD 会持续重派此回调 → 空读 busy-loop 跑满一个核心。
                    handle.readabilityHandler = nil
                    return
                }
                let tsData = ManagedTask.injectTimestamps(data)
                self?.stdoutBuffer.append(tsData)
                self?.stdoutHandle?.write(tsData)
            }

            // Read stderr into ring buffer + file (with timestamp injection)
            stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                guard !data.isEmpty else {
                    // EOF：同上，必须注销，否则空读 busy-loop。
                    handle.readabilityHandler = nil
                    return
                }
                let tsData = ManagedTask.injectTimestamps(data)
                self?.stderrBuffer.append(tsData)
                self?.stderrHandle?.write(tsData)
            }
        }

        process.terminationHandler = { [weak self] process in
            guard let self else { return }
            onExit(self, process.terminationStatus)
        }

        do {
            try process.run()
        } catch {
            cleanupProcessResources()
            self.process = nil
            throw error
        }
        self.pid = process.processIdentifier
        self.state = .running
        self.startedAt = Date()
        self.lastError = nil
        self.exitCode = nil
    }

    func completeExit(status: Int32) -> TimeInterval {
        let runtime = startedAt.map { Date().timeIntervalSince($0) } ?? 0
        pid = nil
        exitCode = status
        lastError = status == 0 ? nil : "Exited with code \(status)"
        startedAt = nil
        process = nil
        cleanupProcessResources()
        return runtime
    }

    func interrupt() {
        process?.interrupt()
    }

    func terminate() {
        process?.terminate()
    }

    private func cleanupProcessResources() {
        stdoutPipe?.fileHandleForReading.readabilityHandler = nil
        stderrPipe?.fileHandleForReading.readabilityHandler = nil
        try? stdoutHandle?.close()
        try? stderrHandle?.close()
        stdoutPipe = nil
        stderrPipe = nil
        stdoutHandle = nil
        stderrHandle = nil
    }

    var shouldStopOnAppQuit: Bool {
        state == .running && config.keepRunningOnQuit != true
    }
}

// MARK: - Supervisor

struct RetryPolicy {
    static let defaultDelays: [TimeInterval] = [2, 3, 5, 8, 13, 21, 30, 45, 60, 90, 120, 180, 300]

    let delays: [TimeInterval]
    let stableRunThreshold: TimeInterval

    func delay(forAttempt attempt: Int) -> TimeInterval {
        guard !delays.isEmpty else { return 60 }
        let index = max(0, min(attempt - 1, delays.count - 1))
        return delays[index]
    }
}

final class Supervisor {
    private let store: TaskStore
    private var managedTasks: [String: ManagedTask] = [:]
    private var httpServer: HTTPServer?
    private let eventListeners = NSMutableSet()
    private let retryPolicy: RetryPolicy
    private let controlQueue = DispatchQueue(label: "com.pangyun.ScriptDock.supervisor")
    private let controlQueueKey = DispatchSpecificKey<Void>()
    private var isShuttingDown = false

    init(
        store: TaskStore,
        retryDelays: [TimeInterval] = RetryPolicy.defaultDelays,
        stableRunThreshold: TimeInterval = 60
    ) {
        self.store = store
        self.retryPolicy = RetryPolicy(
            delays: retryDelays,
            stableRunThreshold: stableRunThreshold
        )
        controlQueue.setSpecific(key: controlQueueKey, value: ())
    }

    func start(autoStart: Bool = true, startHTTPServer: Bool = true) {
        var serverToStart: HTTPServer?
        withControlQueue {
            isShuttingDown = false
            let result = store.reload()
            for task in result.tasks {
                let managed = ManagedTask(config: task)
                managedTasks[task.id] = managed
                if autoStart && task.runAtLoad == true {
                    _ = startTaskLocked(id: task.id, source: "auto", extraArgs: nil)
                }
            }

            if startHTTPServer {
                let server = HTTPServer(supervisor: self)
                httpServer = server
                serverToStart = server
            }
        }
        serverToStart?.start()
    }

    func taskIDs() -> [String] {
        withControlQueue {
            store.tasks.map(\.id)
        }
    }

    func taskStatus(id: String) -> TaskStatus? {
        withControlQueue {
            managedTasks[id]?.status
        }
    }

    func allStatuses() -> [TaskStatus] {
        withControlQueue {
            store.tasks.compactMap { managedTasks[$0.id]?.status }
        }
    }

    func hasTasksToStopOnAppQuit() -> Bool {
        withControlQueue {
            managedTasks.values.contains { $0.shouldStopOnAppQuit }
        }
    }

    func startTask(id: String, source: String? = nil, extraArgs: [String]? = nil) -> String? {
        withControlQueue {
            startTaskLocked(id: id, source: source, extraArgs: extraArgs)
        }
    }

    private func startTaskLocked(id: String, source: String?, extraArgs: [String]?) -> String? {
        guard let managed = managedTasks[id] else { return "Task not found: \(id)" }
        guard !isShuttingDown else { return "ScriptDock is shutting down" }
        guard managed.state != .running else { return nil }

        cancelPendingRetryLocked(managed)
        managed.retryAttempt = 0
        managed.stoppedManually = false
        managed.restartRequested = false
        managed.restartSource = nil
        return launchTaskLocked(managed, source: source, extraArgs: extraArgs)
    }

    private func launchTaskLocked(_ managed: ManagedTask, source: String?, extraArgs: [String]? = nil) -> String? {
        do {
            try managed.start(logsURL: store.logsURL, source: source, extraArgs: extraArgs) { [weak self] task, status in
                guard let self else { return }
                self.controlQueue.async {
                    self.handleTaskExitLocked(task, status: status)
                }
            }
            return nil
        } catch {
            managed.lastError = error.localizedDescription
            managed.exitCode = nil
            if managed.config.keepAlive == true && !managed.stoppedManually && !isShuttingDown {
                scheduleRetryLocked(managed)
            } else {
                managed.state = .errored
            }
            return error.localizedDescription
        }
    }

    func stopTask(id: String) -> String? {
        withControlQueue {
            stopTaskLocked(id: id)
        }
    }

    private func stopTaskLocked(id: String, timeout: TimeInterval = 5.0) -> String? {
        guard let managed = managedTasks[id] else { return "Task not found: \(id)" }
        cancelPendingRetryLocked(managed)
        managed.restartRequested = false
        managed.restartSource = nil
        managed.stoppedManually = true
        managed.retryAttempt = 0

        if managed.state == .running {
            interruptLocked(managed, timeout: timeout)
        } else {
            managed.nextRetryAt = nil
            managed.state = .stopped
        }
        return nil
    }

    func restartTask(id: String, source: String? = nil) -> String? {
        withControlQueue {
            restartTaskLocked(id: id, source: source)
        }
    }

    private func restartTaskLocked(id: String, source: String?) -> String? {
        guard let managed = managedTasks[id] else { return "Task not found: \(id)" }
        guard !isShuttingDown else { return "ScriptDock is shutting down" }

        cancelPendingRetryLocked(managed)
        managed.retryAttempt = 0
        if managed.state == .running {
            managed.restartRequested = true
            managed.restartSource = source
            managed.stoppedManually = true
            interruptLocked(managed, timeout: 5.0)
            return nil
        }

        managed.stoppedManually = false
        managed.restartRequested = false
        managed.restartSource = nil
        return launchTaskLocked(managed, source: source)
    }

    func readLogs(id: String, stream: LogStream, since offset: Int) -> (data: Data, total: Int)? {
        withControlQueue {
            guard let managed = managedTasks[id] else { return nil }
            let buffer = stream == .stdout ? managed.stdoutBuffer : managed.stderrBuffer
            let data = buffer.read(since: offset)
            return (data, buffer.count)
        }
    }

    func clearLogs(id: String) {
        withControlQueue {
            guard let managed = managedTasks[id] else { return }
            managed.stdoutBuffer.clear()
            managed.stderrBuffer.clear()
        }
    }

    /// Sync managed tasks with the store's task list (called after config reload).
    /// Does not call store.reload() — the caller should do that first.
    func syncTasks() {
        withControlQueue {
            syncTasksLocked(store.tasks)
        }
    }

    func reloadConfig() -> [String] {
        withControlQueue {
            let result = store.reload()
            syncTasksLocked(result.tasks)
            return Array(result.errors.values)
        }
    }

    func portCheck(ports: [Int]) -> [PortOwner] {
        PortInspector.portOwners(for: ports)
    }

    func killPort(pids: [Int32]) -> (killed: [Int32], failed: [Int32]) {
        PortInspector.killPIDs(pids)
    }

    func shutdownForAppQuit(timeout: TimeInterval = 1.0) {
        withControlQueue {
            isShuttingDown = true
            for managed in managedTasks.values {
                cancelPendingRetryLocked(managed)
                managed.restartRequested = false
                managed.restartSource = nil
                if managed.state == .retrying {
                    managed.state = .stopped
                }
                if managed.shouldStopOnAppQuit {
                    managed.stoppedManually = true
                    interruptLocked(managed, timeout: timeout)
                }
            }
        }
    }

    func cancelPendingRetriesForAppQuit() {
        withControlQueue {
            isShuttingDown = true
            for managed in managedTasks.values {
                cancelPendingRetryLocked(managed)
                managed.restartRequested = false
                managed.restartSource = nil
                if managed.state == .retrying {
                    managed.state = .stopped
                }
            }
        }
    }

    private func handleTaskExitLocked(_ task: ManagedTask, status: Int32) {
        guard managedTasks[task.config.id] === task else { return }
        let runtime = task.completeExit(status: status)

        if task.restartRequested && !isShuttingDown {
            let source = task.restartSource
            task.restartRequested = false
            task.restartSource = nil
            task.stoppedManually = false
            task.retryAttempt = 0
            _ = launchTaskLocked(task, source: source)
            return
        }

        guard !task.stoppedManually && !isShuttingDown else {
            task.state = .stopped
            return
        }

        if task.config.keepAlive == true {
            if runtime >= retryPolicy.stableRunThreshold {
                task.retryAttempt = 0
            }
            scheduleRetryLocked(task)
        } else {
            task.state = status == 0 ? .stopped : .errored
        }
    }

    private func scheduleRetryLocked(_ task: ManagedTask) {
        guard task.config.keepAlive == true,
              !task.stoppedManually,
              !isShuttingDown,
              managedTasks[task.config.id] === task else {
            task.state = task.exitCode == 0 ? .stopped : .errored
            return
        }

        cancelPendingRetryLocked(task)
        task.retryAttempt += 1
        let delay = retryPolicy.delay(forAttempt: task.retryAttempt)
        task.nextRetryAt = Date().addingTimeInterval(delay)
        task.retryGeneration &+= 1
        let generation = task.retryGeneration
        let taskID = task.config.id
        let source = task.startedBy

        let workItem = DispatchWorkItem { [weak self, weak task] in
            guard let self, let task,
                  task.retryGeneration == generation,
                  self.managedTasks[taskID] === task,
                  task.config.keepAlive == true,
                  !task.stoppedManually,
                  !self.isShuttingDown else {
                return
            }
            task.pendingRetry = nil
            task.nextRetryAt = nil
            _ = self.launchTaskLocked(task, source: source)
        }
        task.pendingRetry = workItem
        task.state = .retrying
        controlQueue.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func cancelPendingRetryLocked(_ task: ManagedTask) {
        task.pendingRetry?.cancel()
        task.pendingRetry = nil
        task.nextRetryAt = nil
        task.retryGeneration &+= 1
    }

    private func interruptLocked(_ task: ManagedTask, timeout: TimeInterval) {
        let expectedPID = task.pid
        task.interrupt()
        controlQueue.asyncAfter(deadline: .now() + timeout) { [weak self, weak task] in
            guard let self, let task,
                  self.managedTasks[task.config.id] === task,
                  task.state == .running,
                  task.pid == expectedPID else {
                return
            }
            task.terminate()
        }
    }

    private func syncTasksLocked(_ tasks: [ScriptTask]) {
        let currentIDs = Set(tasks.map(\.id))
        for id in Array(managedTasks.keys) where !currentIDs.contains(id) {
            guard let managed = managedTasks.removeValue(forKey: id) else { continue }
            cancelPendingRetryLocked(managed)
            managed.stoppedManually = true
            managed.restartRequested = false
            managed.terminate()
        }

        for task in tasks {
            if let existing = managedTasks[task.id] {
                existing.config = task
                if task.keepAlive != true && existing.state == .retrying {
                    cancelPendingRetryLocked(existing)
                    existing.retryAttempt = 0
                    existing.state = existing.exitCode == 0 ? .stopped : .errored
                }
            } else {
                managedTasks[task.id] = ManagedTask(config: task)
            }
        }
    }

    private func withControlQueue<T>(_ operation: () -> T) -> T {
        if DispatchQueue.getSpecific(key: controlQueueKey) != nil {
            return operation()
        }
        return controlQueue.sync(execute: operation)
    }
}

// MARK: - HTTP Server

final class HTTPServer {
    private let supervisor: Supervisor
    private var serverSocket: Int32 = -1
    private var serverSource: DispatchSourceRead?

    init(supervisor: Supervisor) {
        self.supervisor = supervisor
    }

    func start() {
        serverSocket = socket(AF_INET, SOCK_STREAM, 0)
        guard serverSocket >= 0 else {
            print("Failed to create socket")
            return
        }

        // Allow address reuse
        var opt: Int32 = 1
        setsockopt(serverSocket, SOL_SOCKET, SO_REUSEADDR, &opt, socklen_t(MemoryLayout.size(ofValue: opt)))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(26216).bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            bind(serverSocket, UnsafeRawPointer(ptr).assumingMemoryBound(to: sockaddr.self), socklen_t(MemoryLayout<sockaddr_in>.size))
        }

        guard bindResult == 0 else {
            print("Failed to bind to 127.0.0.1:26216")
            close(serverSocket)
            return
        }

        listen(serverSocket, 16)

        let source = DispatchSource.makeReadSource(fileDescriptor: serverSocket, queue: .global(qos: .utility))
        source.setEventHandler { [weak self] in
            self?.acceptConnection()
        }
        serverSource = source
        source.resume()

        print("HTTP API listening on http://127.0.0.1:26216")
    }

    private func acceptConnection() {
        var addr = sockaddr_in()
        var addrLen = socklen_t(MemoryLayout<sockaddr_in>.size)
        let clientSocket = withUnsafeMutablePointer(to: &addr) { ptr in
            accept(serverSocket, UnsafeMutableRawPointer(ptr).assumingMemoryBound(to: sockaddr.self), &addrLen)
        }
        guard clientSocket >= 0 else { return }

        DispatchQueue.global(qos: .utility).async { [weak self] in
            self?.handleClient(clientSocket)
        }
    }

    private func handleClient(_ socket: Int32) {
        defer { close(socket) }

        // Read request
        var buffer = [UInt8](repeating: 0, count: 8192)
        let bytesRead = recv(socket, &buffer, buffer.count, 0)
        guard bytesRead > 0 else { return }
        let request = String(bytes: buffer[0..<bytesRead], encoding: .utf8) ?? ""

        // Parse HTTP request line
        let lines = request.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else { return }
        let method = String(parts[0])
        let path = String(parts[1])

        // Route
        let (statusCode, body) = route(method: method, path: path, request: request)
        let response = formatResponse(statusCode: statusCode, body: body)
        let responseData = Data(response.utf8)
        _ = responseData.withUnsafeBytes { ptr in
            send(socket, ptr.baseAddress, responseData.count, 0)
        }
    }

    private func route(method: String, path: String, request: String) -> (Int, String) {
        let jsonEncoder = JSONEncoder()
        jsonEncoder.dateEncodingStrategy = .iso8601

        // GET /api/tasks
        if method == "GET" && path == "/api/tasks" {
            let statuses = supervisor.allStatuses()
            guard let data = try? jsonEncoder.encode(statuses) else { return (500, "{\"error\":\"encode failed\"}") }
            return (200, String(data: data, encoding: .utf8) ?? "[]")
        }

        // GET /api/tasks/:id/logs
        if method == "GET", path.hasPrefix("/api/tasks/"), path.hasSuffix("/logs") {
            let id = extractTaskID(from: path, suffix: "/logs")
            guard let id else { return (400, "{\"error\":\"invalid path\"}") }

            let params = extractQueryParams(from: path)
            let stream: LogStream = params["stream"] == "stderr" ? .stderr : .stdout
            let since = Int(params["since"] ?? "0") ?? 0

            guard let result = supervisor.readLogs(id: id, stream: stream, since: since) else {
                return (404, "{\"error\":\"task not found\"}")
            }

            let response: [String: Any] = [
                "offset": since,
                "total": result.total,
                "data": String(data: result.data, encoding: .utf8) ?? ""
            ]
            guard let jsonData = try? JSONSerialization.data(withJSONObject: response) else {
                return (500, "{\"error\":\"encode failed\"}")
            }
            return (200, String(data: jsonData, encoding: .utf8) ?? "{}")
        }

        // POST /api/tasks/:id/start
        if method == "POST", path.hasPrefix("/api/tasks/"), path.hasSuffix("/start") {
            let id = extractTaskID(from: path, suffix: "/start")
            guard let id else { return (400, "{\"error\":\"invalid path\"}") }
            let source = extractQueryParams(from: path)["source"]
            if let error = supervisor.startTask(id: id, source: source) {
                return (500, "{\"error\":\"\(error.escapedJSON())\"}")
            }
            return (200, "{\"ok\":true}")
        }

        // POST /api/tasks/:id/stop
        if method == "POST", path.hasPrefix("/api/tasks/"), path.hasSuffix("/stop") {
            let id = extractTaskID(from: path, suffix: "/stop")
            guard let id else { return (400, "{\"error\":\"invalid path\"}") }
            if let error = supervisor.stopTask(id: id) {
                return (500, "{\"error\":\"\(error.escapedJSON())\"}")
            }
            return (200, "{\"ok\":true}")
        }

        // POST /api/tasks/:id/restart
        if method == "POST", path.hasPrefix("/api/tasks/"), path.hasSuffix("/restart") {
            let id = extractTaskID(from: path, suffix: "/restart")
            guard let id else { return (400, "{\"error\":\"invalid path\"}") }
            let source = extractQueryParams(from: path)["source"]
            if let error = supervisor.restartTask(id: id, source: source) {
                return (500, "{\"error\":\"\(error.escapedJSON())\"}")
            }
            return (200, "{\"ok\":true}")
        }

        // GET /api/ports
        if method == "GET" && path.hasPrefix("/api/ports") {
            let params = extractQueryParams(from: path)
            let portStr = params["ports"] ?? ""
            let ports = portStr.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            let owners = supervisor.portCheck(ports: ports)
            guard let data = try? JSONEncoder().encode(owners) else { return (500, "{\"error\":\"encode failed\"}") }
            return (200, String(data: data, encoding: .utf8) ?? "[]")
        }

        // POST /api/ports/kill
        if method == "POST" && path == "/api/ports/kill" {
            let body = extractBody(from: request)
            let pids = body.split(separator: ",").compactMap { Int32($0.trimmingCharacters(in: .whitespaces)) }
            let result = supervisor.killPort(pids: pids)
            let response: [String: Any] = [
                "killed": result.killed,
                "failed": result.failed
            ]
            guard let data = try? JSONSerialization.data(withJSONObject: response) else {
                return (500, "{\"error\":\"encode failed\"}")
            }
            return (200, String(data: data, encoding: .utf8) ?? "{}")
        }

        // POST /api/reload
        if method == "POST" && path == "/api/reload" {
            let errors = supervisor.reloadConfig()
            return (200, "{\"errors\":\(errors.count)}")
        }

        return (404, "{\"error\":\"not found\"}")
    }

    private func extractTaskID(from path: String, suffix: String) -> String? {
        let prefix = "/api/tasks/"
        guard path.hasPrefix(prefix), path.hasSuffix(suffix) else { return nil }
        let start = path.index(path.startIndex, offsetBy: prefix.count)
        let end = path.index(path.endIndex, offsetBy: -suffix.count)
        guard start < end else { return nil }
        return String(path[start..<end])
    }

    private func extractQueryParams(from path: String) -> [String: String] {
        guard let queryStart = path.firstIndex(of: "?") else { return [:] }
        let queryString = path[path.index(after: queryStart)...]
        var params: [String: String] = [:]
        for pair in queryString.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1)
            guard kv.count == 2 else { continue }
            params[String(kv[0])] = String(kv[1]).removingPercentEncoding ?? String(kv[1])
        }
        return params
    }

    private func extractBody(from request: String) -> String {
        guard let bodyStart = request.range(of: "\r\n\r\n") else { return "" }
        return String(request[bodyStart.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func formatResponse(statusCode: Int, body: String) -> String {
        let statusText: String
        switch statusCode {
        case 200: statusText = "OK"
        case 400: statusText = "Bad Request"
        case 404: statusText = "Not Found"
        case 500: statusText = "Internal Server Error"
        default: statusText = "Unknown"
        }
        return "HTTP/1.1 \(statusCode) \(statusText)\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
    }
}

// MARK: - String Helper

extension String {
    func escapedJSON() -> String {
        replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
    }
}

// MARK: - (Entry point removed — Supervisor is embedded in the main app)
