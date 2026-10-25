import Foundation
import Testing
import XCPrivacyGate

let repositoryRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()

func withTemporaryDirectory<Result>(_ body: (URL) throws -> Result) throws -> Result {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    return try body(directory)
}

func relativeFiles(under directory: URL) throws -> Set<String> {
    let enumerator = try #require(
        FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])
    )
    let prefix = directory.standardizedFileURL.path + "/"
    var files: Set<String> = []
    for case let url as URL in enumerator where try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
        files.insert(String(url.standardizedFileURL.path.dropFirst(prefix.count)))
    }
    return files
}

func testData(_ path: String) throws -> URL {
    try #require(Bundle.module.url(forResource: "Data", withExtension: nil)).appendingPathComponent(path)
}

func applePage(_ name: String) throws -> [String: Any] {
    try AppleDocs.document(Data(contentsOf: testData(name)), from: name)
}
