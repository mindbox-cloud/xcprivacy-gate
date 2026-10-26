import Foundation

enum WorkDirectory {
    static func with<Result>(_ body: (URL) throws -> Result) throws -> Result {
        let directory = FileManager.default.temporaryDirectory.appending(path: "xcprivacy-gate-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        return try body(directory)
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
}
