import Foundation
import Testing
import XCPrivacyGate

private struct DescribedPackage: Encodable {
    var name = "Mindbox"
    var platforms = [DescribedPlatform(name: "ios", version: "12.0")]
    var dependencies: [[String: String]] = []
    var targets: [DescribedTarget]
}

private struct DescribedPlatform: Encodable {
    let name: String
    let version: String
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

private let manifestTargets = ["Mindbox", "MindboxNotifications", "MindboxLogger"]

private func developPackage(root: URL) -> DescribedPackage {
    func target(_ name: String, sources: [String], manifest: Bool) -> DescribedTarget {
        let resource = DescribedResource(path: root.appendingPathComponent("\(name)/PrivacyInfo.xcprivacy").path, rule: ["process": [:]])
        return DescribedTarget(name: name, path: name, sources: sources, resources: manifest ? [resource] : nil)
    }
    return DescribedPackage(targets: [
        target("SDKVersionProvider", sources: ["SDKVersionProvider.swift"], manifest: false),
        target("MindboxNotifications", sources: ["MindboxNotificationService.swift", "Models/ImageFormat.swift"], manifest: true),
        target("MindboxLogger", sources: ["Network/Enums/SDKLogsStatus.swift"], manifest: true),
        target("Mindbox", sources: ["CoreController/CoreController.swift", "Mindbox.swift"], manifest: true)
    ])
}

private func realPath(_ url: URL) throws -> URL {
    let resolved = try #require(realpath(url.path, nil))
    defer { free(resolved) }
    return URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
}

private func withDevelopTree<Result>(_ body: (URL) throws -> Result) throws -> Result {
    try withTemporaryDirectory { directory in
        let root = try realPath(directory)
        for name in manifestTargets {
            let target = root.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            try Data("<plist/>".utf8).write(to: target.appendingPathComponent("PrivacyInfo.xcprivacy"))
        }
        return try body(root)
    }
}

private func readPackage(_ package: DescribedPackage, root: URL) throws -> PackageDescription {
    try PackageReader.read(description: JSONEncoder().encode(package), root: root)
}

private func codes(_ violations: [Violation]) -> [String] {
    violations.map(\.code)
}

@Suite("Package reader")
struct PackageReaderTests {
    @Test("the develop package has four library targets")
    func developHasFourLibraryTargets() throws {
        try withDevelopTree { root in
            let description = try readPackage(developPackage(root: root), root: root)

            #expect(description.name == "Mindbox")
            #expect(description.iosDeploymentTarget == "12.0")
            #expect(description.root.path == root.path)
            #expect(description.violations == [])
            let targets = Dictionary(uniqueKeysWithValues: description.targets.map { ($0.name, $0) })
            #expect(Set(targets.keys) == ["Mindbox", "MindboxNotifications", "SDKVersionProvider", "MindboxLogger"])
            let mindbox = try #require(targets["Mindbox"])
            #expect(mindbox.path.path == root.appendingPathComponent("Mindbox").path)
            #expect(mindbox.sources.map(\.path) == [
                root.appendingPathComponent("Mindbox/CoreController/CoreController.swift").path,
                root.appendingPathComponent("Mindbox/Mindbox.swift").path
            ])
            #expect(mindbox.manifest?.path == root.appendingPathComponent("Mindbox/PrivacyInfo.xcprivacy").path)
            #expect(mindbox.resourceRule == "process")
            let provider = try #require(targets["SDKVersionProvider"])
            #expect(provider.manifest == nil)
            #expect(provider.resourceRule == nil)
        }
    }

    @Test("a manifest on disk that the target's resources do not list is MANIFEST_NOT_WIRED")
    func unwiredManifestIsReported() throws {
        try withDevelopTree { root in
            var package = developPackage(root: root)
            package.targets[2].resources = nil

            let description = try readPackage(package, root: root)

            #expect(codes(description.violations) == ["MANIFEST_NOT_WIRED"])
            #expect(description.violations.first?.module == "MindboxLogger")
            #expect(description.violations.first?.file == root.appendingPathComponent("MindboxLogger/PrivacyInfo.xcprivacy").path)
            #expect(description.targets.first { $0.name == "MindboxLogger" }?.manifest == nil)
        }
    }

    @Test("a package dependency is PACKAGE_DEPENDENCY")
    func packageDependencyIsReported() throws {
        try withDevelopTree { root in
            var package = developPackage(root: root)
            package.dependencies = [["identity": "swift-collections", "type": "sourceControl", "url": "https://github.com/apple/swift-collections.git"]]

            let violations = try readPackage(package, root: root).violations

            #expect(codes(violations) == ["PACKAGE_DEPENDENCY"])
            #expect(violations.first?.message.contains("'swift-collections'") == true)
        }
    }

    @Test("a binary target is PACKAGE_DEPENDENCY and not a scanned target")
    func binaryTargetIsReported() throws {
        try withDevelopTree { root in
            var package = developPackage(root: root)
            package.targets.append(DescribedTarget(name: "Vendored", path: "Vendored.xcframework", type: "binary", sources: []))

            let description = try readPackage(package, root: root)

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
        try withDevelopTree { root in
            var package = developPackage(root: root)
            package.targets[2].sources.append("Native/\(file)")

            let description = try readPackage(package, root: root)

            #expect(codes(description.violations) == ["UNSCANNABLE_SOURCE"])
            let violation = try #require(description.violations.first)
            #expect(violation.module == "MindboxLogger")
            #expect(violation.message.contains("Native/\(file)"))
            #expect(violation.file == root.appendingPathComponent("MindboxLogger/Native/\(file)").path)
            let logger = try #require(description.targets.first { $0.name == "MindboxLogger" })
            #expect(logger.sources.map(\.lastPathComponent) == ["SDKLogsStatus.swift"])
        }
    }

    @Test("test, executable, plugin and macro targets are skipped", arguments: ["test", "executable", "plugin", "macro"])
    func nonLibraryTargetsAreSkipped(type: String) throws {
        try withDevelopTree { root in
            var package = developPackage(root: root)
            package.targets.append(DescribedTarget(name: "MindboxTests", path: "MindboxTests", type: type, sources: ["Native.m"]))

            let description = try readPackage(package, root: root)

            #expect(!description.targets.contains { $0.name == "MindboxTests" })
            #expect(description.violations == [])
        }
    }

    @Test("a target at the package root has paths without a dot component")
    func targetAtPackageRootHasCleanPaths() throws {
        try withDevelopTree { root in
            var package = developPackage(root: root)
            package.targets = [DescribedTarget(name: "Root", path: ".", sources: ["Sub/A.swift"])]

            let target = try #require(readPackage(package, root: root).targets.first)

            #expect(target.path.path == root.path)
            #expect(target.sources.map(\.path) == [root.appendingPathComponent("Sub/A.swift").path])
        }
    }

    @Test("a package without library targets is a tool error")
    func noLibraryTargetsIsToolError() throws {
        try withDevelopTree { root in
            var package = developPackage(root: root)
            package.targets = [DescribedTarget(name: "MindboxTests", path: "MindboxTests", type: "test", sources: ["Tests.swift"])]

            #expect(throws: ToolError.self) { try readPackage(package, root: root) }
        }
    }

    @Test("a package without an iOS platform has no deployment target")
    func noIOSPlatformMeansNoDeploymentTarget() throws {
        try withDevelopTree { root in
            var package = developPackage(root: root)
            package.platforms = [DescribedPlatform(name: "macos", version: "14.0")]

            let description = try readPackage(package, root: root)

            #expect(description.iosDeploymentTarget == nil)
        }
    }

    @Test("output that is not describe's JSON is a tool error", arguments: ["not json", #"{"name": "Mindbox"}"#, "[]"])
    func unexpectedOutputIsToolError(output: String) throws {
        try withDevelopTree { root in
            let error = #expect(throws: ToolError.self) { try PackageReader.read(description: Data(output.utf8), root: root) }

            #expect(error?.message.hasPrefix("swift package describe printed unexpected output: ") == true)
        }
    }

    @Test("a root that does not exist is a tool error")
    func missingRootIsToolError() throws {
        try withDevelopTree { root in
            let missing = root.appendingPathComponent("missing", isDirectory: true)

            let error = #expect(throws: ToolError.self) { try readPackage(developPackage(root: missing), root: missing) }

            #expect(error?.message.contains(missing.path) == true)
        }
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
            #expect(description.iosDeploymentTarget == "15.0")
            #expect(!description.root.path.contains("/link"))
            #expect(description.targets.map(\.name).sorted() == ["Legacy", "Swifty"])
            let swifty = try #require(description.targets.first { $0.name == "Swifty" })
            #expect(swifty.path.path == description.root.appendingPathComponent("Sources/Swifty").path)
            #expect(swifty.sources.map(\.path).sorted() == [swifty.path.appendingPathComponent("A.swift").path, swifty.path.appendingPathComponent("Sub/B.swift").path])
            #expect(swifty.manifest?.path == swifty.path.appendingPathComponent("PrivacyInfo.xcprivacy").path)
            #expect(swifty.resourceRule == "process")
            let legacy = try #require(description.targets.first { $0.name == "Legacy" })
            #expect(legacy.sources == [])
            #expect(legacy.manifest?.path == legacy.path.appendingPathComponent("PrivacyInfo.xcprivacy").path)
            #expect(legacy.resourceRule == "copy")
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
            #expect(swifty.resourceRule == nil)
            #expect(description.violations == [])
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
        return try PackageReader.read(description: PackageReader.describe(root: link), root: link)
    }
}
