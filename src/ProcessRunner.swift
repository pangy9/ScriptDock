import Foundation

enum ProcessRunner {
    struct Result {
        let status: Int32
        let output: String
    }

    @discardableResult
    static func run(_ executable: String, arguments: [String]) -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""
            return Result(status: process.terminationStatus, output: output)
        } catch {
            return Result(status: 1, output: "")
        }
    }
}
