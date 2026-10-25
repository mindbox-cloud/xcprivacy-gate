import Foundation
import Testing
import XCPrivacyGate

private struct DescribedPackage: Encodable {
    var name = "Sample"
    var path: String
    var dependencies: [[String: String]] = []
    var targets: [DescribedTarget]
}

private struct DescribedTarget: Encodable {
    var name: String
    var path: String
    var type = "library"
    var sources: [String]
    var resources: [DescribedResource]?
}

private struct DescribedResource: Encodable {
    let path: String
    let rule: [String: [String: String]]
}

private let manifestTargets = ["Core", "Notifications", "Logger"]
private let emptyDump = Data(#"{"targets": []}"#.utf8)

private func fourTargetPackage(root: URL) -> DescribedPackage {
    func target(_ name: String, sources: [String], manifest: Bool) -> DescribedTarget {
        let resource = DescribedResource(path: root.appendingPathComponent("\(name)/PrivacyInfo.xcprivacy").path, rule: ["process": [:]])
        return DescribedTarget(name: name, path: name, sources: sources, resources: manifest ? [resource] : nil)
    }
    return DescribedPackage(path: root.path, targets: [
        target("SDKVersionProvider", sources: ["SDKVersionProvider.swift"], manifest: false),
        target("Notifications", sources: ["NotificationService.swift", "Models/ImageFormat.swift"], manifest: true),
        target("Logger", sources: ["Network/Enums/SDKLogsStatus.swift"], manifest: true),
        target("Core", sources: ["CoreController/CoreController.swift", "Core.swift"], manifest: true)
    ])
}

private func withSampleTree<Result>(_ body: (URL) throws -> Result) throws -> Result {
    try withTemporaryDirectory { root in
        for name in manifestTargets {
            let target = root.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            try Data("<plist/>".utf8).write(to: target.appendingPathComponent("PrivacyInfo.xcprivacy"))
        }
        return try body(root)
    }
}

private func readPackage(_ package: DescribedPackage, dump: Data = emptyDump) throws -> PackageDescription {
    try PackageReader.read(description: JSONEncoder().encode(package), dump: dump)
}

private func samplePackage(_ targets: String...) -> DescribedPackage {
    DescribedPackage(name: "Sample", path: "/sample", targets: targets.map { DescribedTarget(name: $0, path: $0, sources: ["\($0).swift"]) })
}

private func codes(_ violations: [Violation]) -> [String] {
    violations.map(\.code)
}

@Suite("Package reader")
struct PackageReaderTests {
    @Test("the sample package has four library targets")
    func samplePackageHasFourLibraryTargets() throws {
        try withSampleTree { root in
            let description = try readPackage(fourTargetPackage(root: root))

            #expect(description.name == "Sample")
            #expect(description.root.path == root.path)
            #expect(description.violations == [])
            let targets = Dictionary(uniqueKeysWithValues: description.targets.map { ($0.name, $0) })
            #expect(Set(targets.keys) == ["Core", "Notifications", "SDKVersionProvider", "Logger"])
            let core = try #require(targets["Core"])
            #expect(core.path.path == root.appendingPathComponent("Core").path)
            #expect(core.sources.map(\.path) == [
                root.appendingPathComponent("Core/CoreController/CoreController.swift").path,
                root.appendingPathComponent("Core/Core.swift").path
            ])
            #expect(core.manifest?.path == root.appendingPathComponent("Core/PrivacyInfo.xcprivacy").path)
            let provider = try #require(targets["SDKVersionProvider"])
            #expect(provider.manifest == nil)
        }
    }

    @Test("a manifest on disk that the target's resources do not list is MANIFEST_NOT_WIRED")
    func unwiredManifestIsReported() throws {
        try withSampleTree { root in
            var package = fourTargetPackage(root: root)
            package.targets[2].resources = nil

            let description = try readPackage(package)

            #expect(codes(description.violations) == ["MANIFEST_NOT_WIRED"])
            #expect(description.violations.first?.module == "Logger")
            #expect(description.violations.first?.file == root.appendingPathComponent("Logger/PrivacyInfo.xcprivacy").path)
            #expect(description.targets.first { $0.name == "Logger" }?.manifest == nil)
        }
    }

    @Test("a package dependency is PACKAGE_DEPENDENCY")
    func packageDependencyIsReported() throws {
        try withSampleTree { root in
            var package = fourTargetPackage(root: root)
            package.dependencies = [["identity": "swift-collections", "type": "sourceControl", "url": "https://github.com/apple/swift-collections.git"]]

            let violations = try readPackage(package).violations

            #expect(codes(violations) == ["PACKAGE_DEPENDENCY"])
            #expect(violations.first?.message.contains("'swift-collections'") == true)
        }
    }

    @Test("a binary target is PACKAGE_DEPENDENCY and not a scanned target")
    func binaryTargetIsReported() throws {
        try withSampleTree { root in
            var package = fourTargetPackage(root: root)
            package.targets.append(DescribedTarget(name: "Vendored", path: "Vendored.xcframework", type: "binary", sources: []))

            let description = try readPackage(package)

            #expect(codes(description.violations) == ["PACKAGE_DEPENDENCY"])
            #expect(description.violations.first?.module == "Vendored")
            #expect(!description.targets.contains { $0.name == "Vendored" })
        }
    }

    @Test(
        "a source that is not Swift is UNSCANNABLE_SOURCE and stays out of sources",
        arguments: ["Legacy.m", "Legacy.mm", "Legacy.c", "Legacy.cc", "Legacy.cpp", "Legacy.cxx", "Legacy.c++", "Legacy.s", "Legacy.S"]
    )
    func nonSwiftSourceIsUnscannable(file: String) throws {
        try withSampleTree { root in
            var package = fourTargetPackage(root: root)
            package.targets[2].sources.append("Native/\(file)")

            let description = try readPackage(package)

            #expect(codes(description.violations) == ["UNSCANNABLE_SOURCE"])
            let violation = try #require(description.violations.first)
            #expect(violation.module == "Logger")
            #expect(violation.message.contains("Native/\(file)"))
            #expect(violation.file == root.appendingPathComponent("Logger/Native/\(file)").path)
            let logger = try #require(description.targets.first { $0.name == "Logger" })
            #expect(logger.sources.map(\.lastPathComponent) == ["SDKLogsStatus.swift"])
        }
    }

    @Test("test, executable, plugin and macro targets are skipped", arguments: ["test", "executable", "plugin", "macro"])
    func nonLibraryTargetsAreSkipped(type: String) throws {
        try withSampleTree { root in
            var package = fourTargetPackage(root: root)
            package.targets.append(DescribedTarget(name: "CoreTests", path: "CoreTests", type: type, sources: ["Native.m"]))

            let description = try readPackage(package)

            #expect(!description.targets.contains { $0.name == "CoreTests" })
            #expect(description.violations == [])
        }
    }

    @Test("a target at the package root has paths without a dot component")
    func targetAtPackageRootHasCleanPaths() throws {
        try withSampleTree { root in
            var package = fourTargetPackage(root: root)
            package.targets = [DescribedTarget(name: "Root", path: ".", sources: ["Sub/A.swift"])]

            let target = try #require(readPackage(package).targets.first)

            #expect(target.path.path == root.path)
            #expect(target.sources.map(\.path) == [root.appendingPathComponent("Sub/A.swift").path])
        }
    }

    @Test("a package without library targets is a tool error")
    func noLibraryTargetsIsToolError() throws {
        try withSampleTree { root in
            var package = fourTargetPackage(root: root)
            package.targets = [DescribedTarget(name: "CoreTests", path: "CoreTests", type: "test", sources: ["Tests.swift"])]

            #expect(throws: ToolError.self) { try readPackage(package) }
        }
    }

    @Test("output that is not describe's JSON is a tool error", arguments: ["not json", #"{"name": "Sample"}"#, "[]"])
    func unexpectedOutputIsToolError(output: String) {
        let error = #expect(throws: ToolError.self) { try PackageReader.read(description: Data(output.utf8), dump: emptyDump) }

        #expect(error?.message.hasPrefix("swift package describe printed unexpected output: ") == true)
    }

    @Test("describe in a directory without Package.swift is a tool error")
    func describeWithoutPackageIsToolError() throws {
        try withTemporaryDirectory { directory in
            let error = #expect(throws: ToolError.self) { try PackageReader.describe(root: directory) }

            #expect(error?.message.hasPrefix("swift package --package-path \(directory.path) describe --type json failed") == true)
        }
    }

    @Test("SwiftPM's description of a Swift and an Objective-C target reads into canonical paths")
    func realPackageReadsIntoCanonicalPaths() throws {
        let targets = """
            .target(name: "Swifty", resources: [.process("PrivacyInfo.xcprivacy")]),
            .target(name: "Legacy", resources: [.copy("PrivacyInfo.xcprivacy")]),
            .testTarget(name: "SwiftyTests", dependencies: ["Swifty"])
            """
        let files = [
            "Sources/Swifty/A.swift", "Sources/Swifty/Sub/B.swift", "Sources/Swifty/PrivacyInfo.xcprivacy",
            "Sources/Legacy/Legacy.m", "Sources/Legacy/Helper.c", "Sources/Legacy/include/Legacy.h", "Sources/Legacy/PrivacyInfo.xcprivacy",
            "Tests/SwiftyTests/SwiftyTests.swift"
        ]
        try withTemporaryDirectory { directory in
            let description = try describeAndRead(targets: targets, files: files, in: directory)

            #expect(description.name == "Probe")
            #expect(!description.root.path.contains("/link"))
            #expect(description.targets.map(\.name).sorted() == ["Legacy", "Swifty"])
            let swifty = try #require(description.targets.first { $0.name == "Swifty" })
            #expect(swifty.path.path == description.root.appendingPathComponent("Sources/Swifty").path)
            #expect(swifty.sources.map(\.path).sorted() == [swifty.path.appendingPathComponent("A.swift").path, swifty.path.appendingPathComponent("Sub/B.swift").path])
            #expect(swifty.manifest?.path == swifty.path.appendingPathComponent("PrivacyInfo.xcprivacy").path)
            let legacy = try #require(description.targets.first { $0.name == "Legacy" })
            #expect(legacy.sources == [])
            #expect(legacy.manifest?.path == legacy.path.appendingPathComponent("PrivacyInfo.xcprivacy").path)
            #expect(codes(description.violations) == ["UNSCANNABLE_SOURCE", "UNSCANNABLE_SOURCE"])
            #expect(Set(description.violations.compactMap(\.module)) == ["Legacy"])
            #expect(Set(description.violations.compactMap(\.file)) == [legacy.path.appendingPathComponent("Legacy.m").path, legacy.path.appendingPathComponent("Helper.c").path])
        }
    }

    @Test("excluded sources are not in sources")
    func excludedSourcesAreNotInSources() throws {
        let targets = #".target(name: "Swifty", exclude: ["Excluded.swift", "Old"])"#
        try withTemporaryDirectory { directory in
            let description = try describeAndRead(
                targets: targets,
                files: ["Sources/Swifty/A.swift", "Sources/Swifty/Excluded.swift", "Sources/Swifty/Old/Legacy.m"],
                in: directory
            )

            #expect(description.targets.first?.sources.map(\.lastPathComponent) == ["A.swift"])
            #expect(description.violations == [])
        }
    }

    @Test("a declared manifest missing on disk leaves the target without a manifest")
    func missingDeclaredManifestLeavesNoManifest() throws {
        let targets = #".target(name: "Swifty", resources: [.process("PrivacyInfo.xcprivacy")])"#
        try withTemporaryDirectory { directory in
            let description = try describeAndRead(targets: targets, files: ["Sources/Swifty/A.swift"], in: directory)

            let swifty = try #require(description.targets.first)
            #expect(swifty.manifest == nil)
            #expect(description.violations == [])
        }
    }

    @Test(
        "a swift define of DEBUG marks the target only when a release build for a shipped platform gets it",
        arguments: [
            (#"{"tool": "swift", "kind": {"define": {"_0": "DEBUG"}}}"#, true),
            (#"{"tool": "swift", "kind": {"define": {"_0": "DEBUG"}}, "condition": {"config": "debug", "platformNames": []}}"#, false),
            (#"{"tool": "swift", "kind": {"define": {"_0": "DEBUG"}}, "condition": {"platformNames": ["macos"]}}"#, false),
            (#"{"tool": "swift", "kind": {"define": {"_0": "DEBUG"}}, "condition": {"platformNames": ["ios"]}}"#, true),
            (#"{"tool": "swift", "kind": {"define": {"_0": "DEBUG"}}, "condition": {"config": "release", "platformNames": ["macos", "watchos"]}}"#, true),
            (#"{"tool": "c", "kind": {"define": {"_0": "DEBUG"}}}"#, false),
            (#"{"tool": "swift", "kind": {"define": {"_0": "OTHER"}}}"#, false),
            (#"{"tool": "swift", "kind": {"enableUpcomingFeature": {"_0": "ExistentialAny"}}}"#, false)
        ]
    )
    func releaseDebugDefineMarksTarget(setting: String, marked: Bool) throws {
        let dump = #"{"targets": [{"name": "Core", "settings": [\#(setting)]}, {"name": "Logger", "settings": []}]}"#

        let targets = try readPackage(samplePackage("Core", "Logger"), dump: Data(dump.utf8)).targets

        #expect(targets.map(\.definesDebugInRelease) == [marked, false])
    }

    @Test("output that is not dump-package's JSON is a tool error")
    func unexpectedDumpIsToolError() {
        let error = #expect(throws: ToolError.self) { try readPackage(samplePackage("Core"), dump: Data("not json".utf8)) }

        #expect(error?.message.hasPrefix("swift package dump-package printed unexpected output: ") == true)
    }

    @Test("SwiftPM's dump of an unconditional DEBUG define marks only that target")
    func realDumpMarksReleaseDebugTarget() throws {
        let targets = """
            .target(name: "Core", swiftSettings: [.define("DEBUG")]),
            .target(name: "Logger", swiftSettings: [.define("DEBUG", .when(configuration: .debug))])
            """
        try withTemporaryDirectory { directory in
            let description = try describeAndRead(targets: targets, files: ["Sources/Core/Core.swift", "Sources/Logger/Logger.swift"], in: directory)

            let marked = Dictionary(uniqueKeysWithValues: description.targets.map { ($0.name, $0.definesDebugInRelease) })
            #expect(marked == ["Core": true, "Logger": false])
        }
    }

    private func describeAndRead(targets: String, files: [String], in directory: URL) throws -> PackageDescription {
        let package = directory.appendingPathComponent("package", isDirectory: true)
        let manifest = """
            // swift-tools-version:5.9
            import PackageDescription

            let package = Package(
                name: "Probe",
                platforms: [.iOS(.v15)],
                targets: [
                    \(targets)
                ]
            )

            """
        for (path, contents) in [("Package.swift", manifest)] + files.map({ ($0, "") }) {
            let file = package.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(contents.utf8).write(to: file)
        }
        let link = directory.appendingPathComponent("link", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: package)
        return try PackageReader.read(description: PackageReader.describe(root: link), dump: PackageReader.dump(root: link))
    }
}
