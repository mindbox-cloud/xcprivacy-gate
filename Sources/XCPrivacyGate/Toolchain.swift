import Foundation
import os

package enum Toolchain {
    private static let stderrTailLength = 2_000

    package static func libIndexStore() throws -> URL {
        let swift = try URL(fileURLWithPath: find("swift"))
        let library = swift.deletingLastPathComponent().appending(path: "../lib/libIndexStore.dylib").standardized
        guard FileManager.default.fileExists(atPath: library.path) else {
            throw ToolError(message: "\(library.path) does not exist: the selected toolchain cannot read the build index")
        }
        return library
    }

    static func find(_ tool: String) throws -> String {
        try trimmedOutput(of: ["xcrun", "--find", tool])
    }

    static func sdkPath(_ sdk: String) throws -> String {
        try trimmedOutput(of: ["xcrun", "--sdk", sdk, "--show-sdk-path"])
    }

    private static func trimmedOutput(of arguments: [String]) throws -> String {
        try run(arguments).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    package static func run(_ arguments: [String]) throws -> String {
        let command = arguments.joined(separator: " ")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = arguments
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do {
            try process.run()
        } catch {
            throw ToolError(message: "\(command) could not start: \(error.localizedDescription)")
        }
        let errorReader = errors.fileHandleForReading
        let errorRead = OSAllocatedUnfairLock<Result<Data?, any Error>>(initialState: .success(nil))
        let drained = DispatchGroup()
        drained.enter()
        Thread {
            let result = Result { try errorReader.readToEnd() }
            errorRead.withLock { $0 = result }
            drained.leave()
        }.start()
        let outputRead = Result { try output.fileHandleForReading.readToEnd() }
        drained.wait()
        exited.wait()
        let outputData: Data
        let errorData: Data
        do {
            outputData = try outputRead.get() ?? Data()
            errorData = try errorRead.withLock { $0 }.get() ?? Data()
        } catch {
            throw ToolError(message: "\(command) output could not be read: \(error.localizedDescription)")
        }
        guard process.terminationStatus == 0 else {
            let stderr = String(bytes: errorData, encoding: .utf8) ?? "stderr is not UTF-8"
            let errorLines = stderr.split(whereSeparator: \.isNewline).filter { $0.contains("error:") }
            let log = errorLines.isEmpty ? stderr : errorLines.joined(separator: "\n")
            let tail = log.suffix(stderrTailLength).trimmingCharacters(in: .whitespacesAndNewlines)
            throw ToolError(message: "\(command) failed (\(process.terminationStatus)): \(tail)")
        }
        guard let text = String(bytes: outputData, encoding: .utf8) else {
            throw ToolError(message: "\(command) printed output that is not UTF-8")
        }
        return text
    }
}
