import Foundation

enum LogBuffer {
    static func tail(_ url: URL, maxBytes: Int) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let offset = size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0
        try? handle.seek(toOffset: offset)
        let data = handle.readDataToEndOfFile()
        let text = String(data: data, encoding: .utf8) ?? ""
        if offset == 0 { return text }
        if let newline = text.firstIndex(of: "\n") {
            return String(text[text.index(after: newline)...])
        }
        return text
    }

    static func recentLogSummary(for task: ScriptTask, store: TaskStore, supervisor: Supervisor? = nil) -> String {
        let stdoutTail: String
        let stderrTail: String

        if let supervisor,
           let outResult = supervisor.readLogs(id: task.id, stream: .stdout, since: 0),
           let errResult = supervisor.readLogs(id: task.id, stream: .stderr, since: 0) {
            let outText = String(data: outResult.data, encoding: .utf8) ?? ""
            let errText = String(data: errResult.data, encoding: .utf8) ?? ""
            // Take last 4000 bytes from ring buffer content
            stdoutTail = outText.count > 4000 ? String(outText.suffix(4000)) : outText
            stderrTail = errText.count > 4000 ? String(errText.suffix(4000)) : errText
        } else {
            stdoutTail = tail(store.stdoutURL(for: task), maxBytes: 4000)
            stderrTail = tail(store.stderrURL(for: task), maxBytes: 4000)
        }

        return """
        Recent logs for \(task.name)

        stdout: \(store.stdoutURL(for: task).path)
        \(stdoutTail.isEmpty ? "(empty)" : stdoutTail)

        stderr: \(store.stderrURL(for: task).path)
        \(stderrTail.isEmpty ? "(empty)" : stderrTail)
        """
    }

    static func logText(for task: ScriptTask, stream: LogStream, store: TaskStore, maxBytes: Int = 2_000_000) -> String {
        switch stream {
        case .stdout:
            return tail(store.stdoutURL(for: task), maxBytes: maxBytes)
        case .stderr:
            return tail(store.stderrURL(for: task), maxBytes: maxBytes)
        }
    }
}
