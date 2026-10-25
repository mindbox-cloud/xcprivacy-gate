import Foundation
import Testing
import XCPrivacyGate
import XCPrivacyGateRules

private let learnedUsrs = [
    "creationDate": ["c:@NSFileCreationDate"],
    "stat": ["c:@F@stat"],
    "systemFreeSize": ["c:@NSFileSystemFreeSize"],
    "systemUptime": ["c:objc(cs)NSProcessInfo(im)systemUptime"]
]

private struct Sample {
    let root: URL
    let store: URL
    private let objects: URL

    init(in directory: URL) throws {
        let base = try URL(fileURLWithPath: #require(directory.resourceValues(forKeys: [.canonicalPathKey]).canonicalPath), isDirectory: true)
        root = base.appending(path: "repository", directoryHint: .isDirectory)
        store = base.appending(path: "store", directoryHint: .isDirectory)
        objects = base.appending(path: "objects", directoryHint: .isDirectory)
    }

    func source(_ path: String, _ lines: String...) throws -> URL {
        let file = root.appending(path: path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(lines.joined(separator: "\n").utf8).write(to: file)
        return file
    }

    func compile(_ module: String, _ sources: [URL]) throws {
        let output = objects.appending(path: module, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        _ = try Toolchain.run([
            "xcrun", "--sdk", "iphonesimulator", "swiftc", "-c", "-parse-as-library", "-module-name", module,
            "-target", "arm64-apple-ios15.0-simulator", "-index-store-path", store.path, "-index-ignore-system-modules",
            "-working-directory", output.path
        ] + sources.map(\.path))
    }

    func target(_ name: String, _ sources: [URL]) -> PackageTarget {
        PackageTarget(
            name: name,
            path: root.appending(path: "Sources/\(name)", directoryHint: .isDirectory),
            sources: sources,
            manifest: nil,
            definesDebugInRelease: false
        )
    }
}

private func calls(_ module: ModuleFindings?) -> [String] {
    (module?.findings ?? []).map { "\($0.api) \($0.file ?? ""):\($0.line ?? 0) \($0.evidence)" }
}

@Suite("Index scanner")
struct IndexScannerTests {
    private let rules: Rules

    init() throws {
        var file = try JSONDecoder().decode(RulesFile.self, from: Data(contentsOf: RulesBundle.directory.appending(path: "rules.json")))
        file.apis = file.apis.map { rule in
            var rule = rule
            rule.usrs = learnedUsrs[rule.api] ?? rule.usrs
            return rule
        }
        rules = try Rules(file)
    }

    @Test("attributes[.systemFreeSize] is systemFreeSize at its line")
    func systemFreeSizeIsFoundAtItsLine() throws {
        try withTemporaryDirectory { directory in
            let sample = try Sample(in: directory)
            let disk = try sample.source(
                "Sources/Core/Disk.swift",
                "import Foundation",
                "",
                "func freeSpace() throws -> Any? {",
                #"    let attributes = try FileManager.default.attributesOfFileSystem(forPath: "/")"#,
                "    return attributes[.systemFreeSize]",
                "}"
            )
            try sample.compile("Core", [disk])

            let modules = try IndexScanner(store: sample.store).findings(targets: [sample.target("Core", [disk])], rules: rules, root: sample.root)

            #expect(calls(modules["Core"]) == ["systemFreeSize Sources/Core/Disk.swift:5 systemFreeSize"])
            #expect(modules["Core"]?.findings.map(\.categories) == [["NSPrivacyAccessedAPICategoryDiskSpace"]])
            #expect(modules["Core"]?.usesStandardDefaults == false)
            #expect(modules["Core"]?.privateSuites == [])
        }
    }

    @Test("implicit .standard sets usesStandardDefaults")
    func implicitStandardSetsUsesStandardDefaults() throws {
        try withTemporaryDirectory { directory in
            let sample = try Sample(in: directory)
            let store = try sample.source(
                "Sources/Core/Store.swift",
                "import Foundation",
                "",
                "struct Store {",
                "    let defaults: UserDefaults",
                "",
                "    init(defaults: UserDefaults = .standard) {",
                "        self.defaults = defaults",
                "    }",
                "}"
            )
            let log = try sample.source("Sources/Logger/Log.swift", "func log(_ message: String) {", "    print(message)", "}")
            try sample.compile("Core", [store])
            try sample.compile("Logger", [log])

            let modules = try IndexScanner(store: sample.store).findings(
                targets: [sample.target("Core", [store]), sample.target("Logger", [log])],
                rules: rules,
                root: sample.root
            )

            #expect(modules["Core"]?.usesStandardDefaults == true)
            #expect(calls(modules["Core"]) == [
                "UserDefaults Sources/Core/Store.swift:6 standard",
                "UserDefaults Sources/Core/Store.swift:6 getter:standard"
            ])
            let logger = try #require(modules["Logger"])
            #expect(!logger.usesStandardDefaults)
            #expect(logger.findings.isEmpty)
        }
    }

    @Test("stat() as a struct is not stat, stat(path, &buf) is")
    func statStructIsNotStatCall() throws {
        try withTemporaryDirectory { directory in
            let sample = try Sample(in: directory)
            let size = try sample.source(
                "Sources/Core/Size.swift",
                "import Foundation",
                "",
                "func size(of path: String) -> Int64 {",
                "    var buffer = stat()",
                "    guard stat(path, &buffer) == 0 else { return 0 }",
                "    return Int64(buffer.st_size)",
                "}"
            )
            try sample.compile("Core", [size])

            let modules = try IndexScanner(store: sample.store).findings(targets: [sample.target("Core", [size])], rules: rules, root: sample.root)

            #expect(calls(modules["Core"]) == ["stat Sources/Core/Size.swift:5 stat(_:_:)"])
        }
    }

    @Test("own members named creationDate and systemUptime are not APIs")
    func ownMembersAreNotAPIs() throws {
        try withTemporaryDirectory { directory in
            let sample = try Sample(in: directory)
            let snapshot = try sample.source(
                "Sources/Core/Snapshot.swift",
                "import Foundation",
                "",
                "struct Snapshot {",
                "    let creationDate: Date",
                "    let systemUptime: TimeInterval",
                "}",
                "",
                "func own(_ snapshot: Snapshot) -> [Any] {",
                "    [snapshot.creationDate, snapshot.systemUptime]",
                "}",
                "",
                "func system(_ attributes: [FileAttributeKey: Any]) -> [Any?] {",
                "    [ProcessInfo.processInfo.systemUptime, attributes[.creationDate]]",
                "}"
            )
            try sample.compile("Core", [snapshot])

            let modules = try IndexScanner(store: sample.store).findings(targets: [sample.target("Core", [snapshot])], rules: rules, root: sample.root)

            #expect(calls(modules["Core"]) == [
                "systemUptime Sources/Core/Snapshot.swift:13 getter:systemUptime",
                "creationDate Sources/Core/Snapshot.swift:13 creationDate"
            ])
        }
    }

    @Test("UserDefaults(suiteName:) matches by prefix")
    func suiteInitializerMatchesByPrefix() throws {
        try withTemporaryDirectory { directory in
            let sample = try Sample(in: directory)
            let shared = try sample.source(
                "Sources/Core/Shared.swift",
                "import Foundation",
                "",
                "func shared() -> UserDefaults? {",
                #"    UserDefaults(suiteName: "group.com.example.sample")"#,
                "}"
            )
            try sample.compile("Core", [shared])

            let modules = try IndexScanner(store: sample.store).findings(targets: [sample.target("Core", [shared])], rules: rules, root: sample.root)

            #expect(calls(modules["Core"]) == ["UserDefaults Sources/Core/Shared.swift:4 init(suiteName:)"])
            #expect(modules["Core"]?.usesStandardDefaults == false)
        }
    }

    @Test("a source file without index data is a tool error naming the file")
    func unindexedSourceIsToolError() throws {
        try withTemporaryDirectory { directory in
            let sample = try Sample(in: directory)
            let built = try sample.source("Sources/Core/Built.swift", "func built() -> Int {", "    1", "}")
            let empty = try sample.source("Sources/Core/Empty.swift", "")
            let unbuilt = try sample.source("Sources/Core/Unbuilt.swift", "func unbuilt() -> Int {", "    2", "}")
            let log = try sample.source("Sources/Logger/Log.swift", "func log() {}")
            try sample.compile("Core", [built, empty])
            let targets = [sample.target("Core", [built, empty, unbuilt]), sample.target("Logger", [log])]

            let error = #expect(throws: ToolError.self) {
                try IndexScanner(store: sample.store).findings(targets: targets, rules: rules, root: sample.root)
            }

            let message = try #require(error?.message)
            #expect(message.contains("Sources/Core/Unbuilt.swift"))
            #expect(message.contains("Sources/Logger/Log.swift"))
            #expect(!message.contains("Sources/Core/Built.swift"))
            #expect(!message.contains("Sources/Core/Empty.swift"))
        }
    }

    @Test("index paths are the original repository paths", arguments: [false, true], [false, true])
    func indexPathsAreRepositoryPaths(sourcesThroughLink: Bool, rootThroughLink: Bool) throws {
        try withTemporaryDirectory { directory in
            let sample = try Sample(in: directory)
            let link = directory.appending(path: "link", directoryHint: .isDirectory)
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: sample.root)
            _ = try sample.source("Sources/Core/Uptime.swift", "import Foundation", "", "let uptime = ProcessInfo.processInfo.systemUptime")
            try sample.compile("Core", [link.appending(path: "Sources/Core/Uptime.swift")])
            let source = (sourcesThroughLink ? link : sample.root).appending(path: "Sources/Core/Uptime.swift")

            let modules = try IndexScanner(store: sample.store).findings(
                targets: [sample.target("Core", [source])],
                rules: rules,
                root: rootThroughLink ? link : sample.root
            )

            #expect(calls(modules["Core"]) == ["systemUptime Sources/Core/Uptime.swift:3 getter:systemUptime"])
        }
    }
}
