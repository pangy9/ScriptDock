import Foundation

final class SupervisorClient {
    static let shared = SupervisorClient()
    static let defaultPort = 26216
    static let baseURL = URL(string: "http://127.0.0.1:\(defaultPort)")!

    private var cachedStatuses: [TaskStatus]?
    private var cacheTime: Date = .distantPast
    private let cacheTTL: TimeInterval = 2.0

    private let session = URLSession(configuration: {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 2
        config.timeoutIntervalForResource = 3
        return config
    }())

    private init() {}

    // MARK: - Generic Request

    private func request(_ path: String, method: String = "GET", body: String? = nil) -> (status: Int, data: Data)? {
        guard let url = URL(string: path, relativeTo: SupervisorClient.baseURL) else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = method
        if let body {
            request.httpBody = Data(body.utf8)
            request.setValue("text/plain", forHTTPHeaderField: "Content-Type")
        }

        let semaphore = DispatchSemaphore(value: 0)
        var result: (status: Int, data: Data)?
        var requestError: Error?

        session.dataTask(with: request) { data, response, error in
            if let error {
                requestError = error
            } else {
                let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
                result = (statusCode, data ?? Data())
            }
            semaphore.signal()
        }.resume()

        guard semaphore.wait(timeout: .now() + 8) == .success else { return nil }
        if requestError != nil { return nil }
        return result
    }

    // MARK: - Status

    var isAvailable: Bool {
        request("/api/tasks") != nil
    }

    func allStatuses() -> [TaskStatus]? {
        if let cached = cachedStatuses, Date().timeIntervalSince(cacheTime) < cacheTTL {
            return cached
        }
        guard let result = request("/api/tasks"), result.status == 200 else { return nil }
        let statuses = try? JSONDecoder().decode([TaskStatus].self, from: result.data)
        cachedStatuses = statuses
        cacheTime = Date()
        return statuses
    }

    func taskStatus(id: String) -> TaskStatus? {
        allStatuses()?.first { $0.id == id }
    }

    // MARK: - Task Control

    func startTask(id: String, source: String? = nil) -> String? {
        let path = if let source { "/api/tasks/\(id)/start?source=\(source)" } else { "/api/tasks/\(id)/start" }
        guard let result = request(path, method: "POST") else {
            return "Supervisor not reachable"
        }
        if result.status == 200 { return nil }
        return errorMessage(from: result.data) ?? "Start failed (\(result.status))"
    }

    func stopTask(id: String) -> String? {
        guard let result = request("/api/tasks/\(id)/stop", method: "POST") else {
            return "Supervisor not reachable"
        }
        if result.status == 200 { return nil }
        return errorMessage(from: result.data) ?? "Stop failed (\(result.status))"
    }

    func restartTask(id: String, source: String? = nil) -> String? {
        let path = if let source { "/api/tasks/\(id)/restart?source=\(source)" } else { "/api/tasks/\(id)/restart" }
        guard let result = request(path, method: "POST") else {
            return "Supervisor not reachable"
        }
        if result.status == 200 { return nil }
        return errorMessage(from: result.data) ?? "Restart failed (\(result.status))"
    }

    // MARK: - Logs

    func logs(id: String, stream: LogStream = .stdout, since offset: Int = 0) -> (text: String, total: Int)? {
        let streamStr = stream == .stderr ? "stderr" : "stdout"
        guard let result = request("/api/tasks/\(id)/logs?stream=\(streamStr)&since=\(offset)"),
              result.status == 200 else { return nil }
        guard let json = try? JSONSerialization.jsonObject(with: result.data) as? [String: Any] else { return nil }
        let total = json["total"] as? Int ?? 0
        let text = json["data"] as? String ?? ""
        return (text, total)
    }

    // MARK: - Ports

    func portCheck(ports: [Int]) -> [PortOwner]? {
        let portStr = ports.map(String.init).joined(separator: ",")
        guard let result = request("/api/ports?ports=\(portStr)"), result.status == 200 else { return nil }
        return try? JSONDecoder().decode([PortOwner].self, from: result.data)
    }

    func killPorts(pids: [Int32]) -> (killed: [Int32], failed: [Int32])? {
        let pidStr = pids.map(String.init).joined(separator: ",")
        guard let result = request("/api/ports/kill", method: "POST", body: pidStr),
              result.status == 200 else { return nil }
        guard let json = try? JSONSerialization.jsonObject(with: result.data) as? [String: Any] else { return nil }
        let killed = (json["killed"] as? [Int32]) ?? []
        let failed = (json["failed"] as? [Int32]) ?? []
        return (killed, failed)
    }

    // MARK: - Config

    func reloadConfig() -> [String]? {
        guard let result = request("/api/reload", method: "POST") else { return nil }
        if result.status == 200 { return [] }
        return [errorMessage(from: result.data) ?? "Reload failed"]
    }

    // MARK: - Helpers

    private func errorMessage(from data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return json["error"] as? String
    }
}
