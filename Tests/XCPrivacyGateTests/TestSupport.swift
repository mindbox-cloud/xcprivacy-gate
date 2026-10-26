import Foundation
import Testing
import XCPrivacyGate

let repositoryRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()

func makeTemporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

func withTemporaryDirectory<Result>(_ body: (URL) throws -> Result) throws -> Result {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    return try body(directory)
}

func canonical(_ directory: URL) throws -> URL {
    try URL(fileURLWithPath: #require(directory.resourceValues(forKeys: [.canonicalPathKey]).canonicalPath), isDirectory: true)
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

func packageManifest(_ package: String) -> String {
    "// swift-tools-version:5.9\nimport PackageDescription\n\nlet package = \(package)\n"
}

func writeFiles(_ files: [String: String], to root: URL) throws {
    for (path, contents) in files {
        let file = root.appending(path: path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: file)
    }
}

func testData(_ path: String) throws -> URL {
    try #require(Bundle.module.url(forResource: "Data", withExtension: nil)).appendingPathComponent(path)
}

func applePage(_ name: String) throws -> [String: Any] {
    try AppleDocs.document(Data(contentsOf: testData(name)), from: name)
}

func appleRules() throws -> Rules {
    let required = try AppleDocs.requiredReasons(applePage("nsprivacyaccessedapitype-2026-10-25.json"))
    var apis: [String: ApiRule] = [:]
    for (category, body) in required.sorted(by: { $0.key < $1.key }) {
        for entry in body.apis {
            apis[entry.api, default: ApiRule(api: entry.api, docc: entry.docc, categories: [])].categories.append(category)
        }
    }
    return try Rules(RulesFile(
        categories: required.mapValues { CategoryReasons(reasons: $0.reasons) },
        apis: apis.values.sorted { $0.api < $1.api },
        collectedDataTypes: AppleDocs.possibleValueNames(applePage("nsprivacycollecteddatatype-2026-10-25.json")),
        purposes: AppleDocs.possibleValueNames(applePage("nsprivacycollecteddatatypepurposes-2026-10-25.json"))
    ))
}
