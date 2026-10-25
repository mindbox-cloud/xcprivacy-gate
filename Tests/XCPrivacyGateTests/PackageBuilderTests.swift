import Foundation
import Testing
import XCPrivacyGate

private func manifest(_ package: String) -> String {
    "// swift-tools-version:5.9\nimport PackageDescription\n\nlet package = \(package)\n"
}

private let sampleFiles = [
    "Package.swift": manifest("""
        Package(
            name: "Sample",
            platforms: [.iOS(.v15)],
            products: [.library(name: "Sample", targets: ["Core"])],
            targets: [
                .target(name: "Core", dependencies: ["Logger"], resources: [.process("PrivacyInfo.xcprivacy")]),
                .target(name: "Logger")
            ]
        )
        """),
    "Sources/Core/Clock.swift": """
        import Foundation
        import Logger

        public func uptime() -> TimeInterval {
            log("uptime")
            return ProcessInfo.processInfo.systemUptime
        }

        """,
    "Sources/Core/PrivacyInfo.xcprivacy": """
        <?xml version="1.0" encoding="UTF-8"?>
        <plist version="1.0"><dict/></plist>

        """,
    "Sources/Logger/Log.swift": """
        import Foundation

        public func log(_ message: String) {
            UserDefaults(suiteName: "com.example.sdk.localState")?.set(message, forKey: "last")
        }

        """,
    "Sample.xcodeproj/project.pbxproj": "not a project\n"
]

private func oneTargetFiles(_ source: String) -> [String: String] {
    [
        "Package.swift": manifest(#"Package(name: "Sample", platforms: [.iOS(.v15)], targets: [.target(name: "Core")])"#),
        "Sources/Core/Core.swift": source
    ]
}

private func write(_ files: [String: String], to root: URL) throws {
    for (path, contents) in files {
        let file = root.appending(path: path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: file)
    }
}

private func taggedDependency(at root: URL) throws -> URL {
    try write([
        "Package.swift": manifest(#"Package(name: "Dep", products: [.library(name: "Dep", targets: ["Dep"])], targets: [.target(name: "Dep")])"#),
        "Sources/Dep/Dep.swift": "public let dep = 1\n"
    ], to: root)
    let git = ["git", "-C", root.path, "-c", "user.name=Sample", "-c", "user.email=sample@example.com", "-c", "commit.gpgSign=false", "-c", "tag.gpgSign=false"]
    for command in [["init", "-q"], ["add", "."], ["commit", "-q", "-m", "Dep"], ["tag", "1.0.0"]] {
        _ = try Toolchain.run(git + command)
    }
    return root
}

private func dependentFiles(on dependency: URL) -> [String: String] {
    [
        "Package.swift": manifest("""
            Package(
                name: "Sample",
                platforms: [.iOS(.v15)],
                dependencies: [.package(url: "file://\(dependency.path)", from: "1.0.0")],
                targets: [.target(name: "Core", dependencies: [.product(name: "Dep", package: "dep")])]
            )
            """),
        "Sources/Core/Core.swift": "import Dep\n\npublic let answer = dep\n"
    ]
}

private struct SamplePackage: Sendable {
    let root: URL
    let targets: [PackageTarget]

    init(at root: URL, files: [String: String]) throws {
        try write(files, to: root)
        self.root = root
        targets = Set(files.keys.filter { $0.hasPrefix("Sources/") && $0.hasSuffix(".swift") }.map { $0.split(separator: "/")[1] })
            .sorted()
            .map { name in
                let path = root.appending(path: "Sources/\(name)", directoryHint: .isDirectory)
                let sources = files.keys.filter { $0.hasPrefix("Sources/\(name)/") && $0.hasSuffix(".swift") }.sorted().map { root.appending(path: $0) }
                return PackageTarget(name: String(name), path: path, sources: sources, manifest: nil, definesDebugInRelease: false)
            }
    }

    func contents() throws -> [String: Data?] {
        let paths = try FileManager.default.subpathsOfDirectory(atPath: root.path)
        return Dictionary(uniqueKeysWithValues: paths.map { ($0, FileManager.default.contents(atPath: root.appending(path: $0).path)) })
    }
}

private struct BuiltSample: Sendable {
    let package: SamplePackage
    let work: URL
    let build: SDKBuild
    let contentsBeforeBuild: [String: Data?]
}

private struct SampleBuild: SuiteTrait, TestScoping {
    @TaskLocal static var current: BuiltSample?

    func provideScope(for test: Test, testCase: Test.Case?, performing function: @Sendable () async throws -> Void) async throws {
        let directory = try canonicalTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let package = try SamplePackage(at: directory.appending(path: "Sample", directoryHint: .isDirectory), files: sampleFiles)
        let contents = try package.contents()
        let work = directory.appending(path: "work", directoryHint: .isDirectory)
        let build = try PackageBuilder.build(root: package.root, targets: package.targets, work: work)
        try await Self.$current.withValue(BuiltSample(package: package, work: work, build: build, contentsBeforeBuild: contents)) {
            try await function()
        }
    }
}

extension Trait where Self == SampleBuild {
    fileprivate static var sampleBuild: Self { Self() }
}

private func canonicalTemporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    guard let canonical = try directory.resourceValues(forKeys: [.canonicalPathKey]).canonicalPath else {
        throw ToolError(message: "\(directory.path) has no canonical path")
    }
    return URL(fileURLWithPath: canonical, isDirectory: true)
}

private func withCanonicalTemporaryDirectory<Result>(_ body: (URL) throws -> Result) throws -> Result {
    let directory = try canonicalTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    return try body(directory)
}

private func objects(in products: URL) throws -> [String] {
    try FileManager.default.contentsOfDirectory(atPath: products.path).filter { $0.hasSuffix(".o") }.sorted()
}

@Suite("Package builder", .sampleBuild)
struct PackageBuilderTests {
    @Test("build of a two-target fixture package gives one .o per target and an index store")
    func buildGivesObjectPerTargetAndIndexStore() throws {
        let sample = try #require(SampleBuild.current)

        #expect(sample.build.products.path == sample.work.appending(path: "build/out/Products/Release-iphoneos").path)
        #expect(sample.build.indexStore.path == sample.work.appending(path: "index").path)
        for target in sample.package.targets {
            #expect(FileManager.default.fileExists(atPath: sample.build.products.appending(path: "\(target.name).o").path))
        }
        let modules = try IndexScanner(store: sample.build.indexStore).findings(targets: sample.package.targets, rules: appleRules(), root: sample.package.root)
        #expect(modules.keys.sorted() == ["Core", "Logger"])
    }

    @Test("the build leaves the package directory untouched (no .build, no .swiftpm)")
    func buildLeavesPackageUntouched() throws {
        let sample = try #require(SampleBuild.current)

        #expect(try sample.package.contents() == sample.contentsBeforeBuild)
    }

    @Test("an .xcodeproj next to Package.swift does not change what is built")
    func xcodeProjectDoesNotChangeWhatIsBuilt() throws {
        let sample = try #require(SampleBuild.current)

        #expect(sample.contentsBeforeBuild["Sample.xcodeproj/project.pbxproj"] != nil)
        #expect(try objects(in: sample.build.products) == ["Core.o", "Logger.o"])
    }

    @Test("a missing product is a tool error naming the target")
    func missingProductIsToolError() throws {
        try withCanonicalTemporaryDirectory { directory in
            let package = try SamplePackage(at: directory.appending(path: "Sample"), files: oneTargetFiles("public let answer = 42\n"))
            let missing = PackageTarget(
                name: "Notifications",
                path: package.root.appending(path: "Sources/Notifications"),
                sources: [],
                manifest: nil,
                definesDebugInRelease: false
            )

            let error = #expect(throws: ToolError.self) {
                try PackageBuilder.build(root: package.root, targets: package.targets + [missing], work: directory.appending(path: "work"))
            }

            #expect(error?.message.contains("Notifications") == true)
            #expect(error?.message.contains("Core") == false)
        }
    }

    @Test("a failing build is a tool error with the compiler's error lines")
    func failingBuildIsToolErrorWithErrorLines() throws {
        try withCanonicalTemporaryDirectory { directory in
            let package = try SamplePackage(at: directory.appending(path: "Sample"), files: oneTargetFiles("public func broken() -> Int { return \"text\" }\n"))

            let error = #expect(throws: ToolError.self) {
                try PackageBuilder.build(root: package.root, targets: package.targets, work: directory.appending(path: "work"))
            }

            #expect(error?.message.contains("Core.swift:1:38: error: cannot convert return expression of type 'String' to return type 'Int'") == true)
            #expect(error?.message.contains("Failed frontend command") == false)
        }
    }

    @Test("a package with a dependency and no Package.resolved is a tool error and gets no Package.resolved")
    func dependencyWithoutResolvedFileIsToolError() throws {
        try withCanonicalTemporaryDirectory { directory in
            let dependency = try taggedDependency(at: directory.appending(path: "dep"))
            let package = try SamplePackage(at: directory.appending(path: "Sample"), files: dependentFiles(on: dependency))
            let contents = try package.contents()

            let error = #expect(throws: ToolError.self) {
                try PackageBuilder.build(root: package.root, targets: package.targets, work: directory.appending(path: "work"))
            }

            #expect(error?.message.contains("Package.resolved") == true)
            #expect(try package.contents() == contents)
        }
    }
}
