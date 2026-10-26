import Foundation

enum WorkDirectory {
    static func with<Result>(_ body: (URL) throws -> Result) throws -> Result {
        let directory = FileManager.default.temporaryDirectory.appending(path: "xcprivacy-gate-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        return try body(directory)
    }

    static func copy(_ file: URL, to copy: URL) throws {
        try FileManager.default.createDirectory(at: copy.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: file, to: copy)
    }
}

extension URL {
    var canonicalPath: String {
        guard let resolved = realpath(path, nil) else {
            return path
        }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    func text() throws -> String {
        do {
            return try String(contentsOf: self, encoding: .utf8)
        } catch {
            throw ToolError(message: "\(path): cannot read the file: \(error.localizedDescription)")
        }
    }
}
