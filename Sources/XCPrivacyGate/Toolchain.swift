import Foundation
import os

package enum Toolchain {
    private static let stderrTailLength = 2_000

    package static func run(_ arguments: [String], in directory: URL?) throws -> String {
        let command = arguments.joined(separator: " ")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = arguments
        process.currentDirectoryURL = directory
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        do {
            try process.run()
        } catch {
            throw ToolError(message: "\(command) could not start: \(error.localizedDescription)")
        }
        let errorReader = errors.fileHandleForReading
        let errorData = OSAllocatedUnfairLock(initialState: Data())
        let drained = DispatchGroup()
        DispatchQueue.global().async(group: drained) {
            let data = errorReader.readDataToEndOfFile()
            errorData.withLock { $0 = data }
        }
        let outputData = output.fileHandleForReading.readDataToEndOfFile()
        drained.wait()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let stderr = errorData.withLock { String(bytes: $0, encoding: .utf8) } ?? "stderr is not UTF-8"
            let tail = stderr.suffix(stderrTailLength).trimmingCharacters(in: .whitespacesAndNewlines)
            throw ToolError(message: "\(command) failed (\(process.terminationStatus)): \(tail)")
        }
        guard let text = String(bytes: outputData, encoding: .utf8) else {
            throw ToolError(message: "\(command) printed output that is not UTF-8")
        }
        return text
    }
}
