import Foundation

package struct PackageTarget: Sendable {
    package let name: String
    package let sources: [URL]
    package let manifest: URL?
    package let definesDebugInRelease: Bool

    package init(name: String, sources: [URL], manifest: URL?, definesDebugInRelease: Bool) {
        self.name = name
        self.sources = sources
        self.manifest = manifest
        self.definesDebugInRelease = definesDebugInRelease
    }

    func shipping(_ manifest: URL?) -> PackageTarget {
        PackageTarget(name: name, sources: sources, manifest: manifest, definesDebugInRelease: definesDebugInRelease)
    }
}

package struct UnlistedManifests: Sendable {
    package let files: [URL]
    package let atTargetRoot: URL?
}

package struct PackageDescription: Sendable {
    package let name: String
    package let root: URL
    package let targets: [PackageTarget]
    package let unlistedManifests: [String: UnlistedManifests]
    package let violations: [Violation]
}

package enum PackageReader {
    package static func describe(root: URL) throws -> Data {
        try Data(Toolchain.run(["swift", "package", "--package-path", root.path, "describe", "--type", "json"]).utf8)
    }

    package static func dump(root: URL) throws -> Data {
        try Data(Toolchain.run(["swift", "package", "--package-path", root.path, "dump-package"]).utf8)
    }

    static func read(root: URL) throws -> PackageDescription {
        try read(description: describe(root: root), dump: dump(root: root))
    }

    package static func read(description: Data, dump: Data) throws -> PackageDescription {
        let package = try decode(DescribedPackage.self, from: description, printedBy: "describe")
        let dumped = try decode(DumpedPackage.self, from: dump, printedBy: "dump-package")
        let releaseDebugTargets = Set(dumped.targets.filter(\.definesDebugInRelease).map(\.name))
        let root = URL(fileURLWithPath: package.path, isDirectory: true)
        var violations = package.dependencies.map { dependency in
            Violation(
                code: "PACKAGE_DEPENDENCY",
                module: nil,
                message: "package dependency \(dependency.identity.quoted): its code is invisible to the source scan"
            )
        }
        var targets: [PackageTarget] = []
        var unlistedManifests: [String: UnlistedManifests] = [:]
        for target in package.targets {
            switch target.type {
            case "library":
                let read = target.packageTarget(in: root, definesDebugInRelease: releaseDebugTargets.contains(target.name), violations: &violations)
                targets.append(read.target)
                unlistedManifests[target.name] = read.unlistedManifests
            case "binary":
                violations.append(Violation(
                    code: "PACKAGE_DEPENDENCY",
                    module: target.name,
                    message: "binary target \(target.name.quoted): its code is invisible to the source scan"
                ))
            default:
                break
            }
        }
        guard !targets.isEmpty else {
            throw ToolError(message: "Package.swift has no library targets: a wrong root or a broken describe")
        }
        return PackageDescription(
            name: package.name,
            root: root,
            targets: targets,
            unlistedManifests: unlistedManifests,
            violations: violations
        )
    }

    private static func decode<Output: Decodable>(_ type: Output.Type, from output: Data, printedBy command: String) throws -> Output {
        do {
            return try JSONDecoder().decode(type, from: output)
        } catch {
            throw ToolError(message: "swift package \(command) printed unexpected output: \(StrictJSON.message(error, document: "the output"))")
        }
    }
}

private struct DescribedPackage: Decodable {
    let name: String
    let path: String
    let dependencies: [Dependency]
    let targets: [Target]

    struct Dependency: Decodable {
        let identity: String
    }

    struct Target: Decodable {
        let name: String
        let path: String
        let type: String
        let sources: [String]
        let resources: [Resource]?
    }

    struct Resource: Decodable {
        let path: String
    }
}

private struct DumpedPackage: Decodable {
    let targets: [Target]

    struct Target: Decodable {
        let name: String
        let settings: [Setting]

        var definesDebugInRelease: Bool {
            settings.contains(where: \.definesDebugInRelease)
        }
    }

    struct Setting: Decodable {
        let tool: String
        let kind: Kind
        let condition: Condition?

        private static let shippedPlatforms: Set = ["ios", "tvos", "watchos", "visionos"]

        var definesDebugInRelease: Bool {
            guard tool == "swift", kind.define?.name == "DEBUG" else {
                return false
            }
            guard let condition else {
                return true
            }
            return condition.config != "debug" && (condition.platformNames.isEmpty || !Self.shippedPlatforms.isDisjoint(with: condition.platformNames))
        }
    }

    struct Kind: Decodable {
        let define: Define?
    }

    struct Define: Decodable {
        let name: String

        enum CodingKeys: String, CodingKey {
            case name = "_0"
        }
    }

    struct Condition: Decodable {
        let config: String?
        let platformNames: [String]
    }
}

private extension DescribedPackage.Target {
    func packageTarget(in root: URL, definesDebugInRelease: Bool, violations: inout [Violation]) -> (target: PackageTarget, unlistedManifests: UnlistedManifests?) {
        let directory = root.appendingPathComponent(path, isDirectory: true).standardized
        let declared = resources?.map { URL(fileURLWithPath: $0.path, isDirectory: false) }.first { ManifestValidator.isNamedLikeManifest($0.lastPathComponent) }
        let files = sources.map { directory.appendingPathComponent($0, isDirectory: false) }
        for (source, file) in zip(sources, files) where file.pathExtension != "swift" {
            violations.append(Violation(
                code: "UNSCANNABLE_SOURCE",
                module: name,
                message: "\(name): \(source) is not Swift; the source scan cannot read it",
                file: file.path
            ))
        }
        let target = PackageTarget(
            name: name,
            sources: files.filter { $0.pathExtension == "swift" },
            manifest: declared,
            definesDebugInRelease: definesDebugInRelease
        )
        let unlisted = declared == nil ? manifests(in: directory) : []
        guard !unlisted.isEmpty else {
            return (target, nil)
        }
        return (target, UnlistedManifests(files: unlisted, atTargetRoot: unlisted.first { $0.deletingLastPathComponent().path == directory.path }))
    }

    private func manifests(in directory: URL) -> [URL] {
        var manifests: [URL] = []
        var visited: Set<String> = []
        var pending = [directory]
        while let next = pending.popLast() {
            guard visited.insert(next.canonicalPath).inserted, let names = try? FileManager.default.contentsOfDirectory(atPath: next.path) else {
                continue
            }
            for name in names where !name.hasPrefix(".") {
                let entry = next.appendingPathComponent(name)
                var isDirectory: ObjCBool = false
                if ManifestValidator.isNamedLikeManifest(name) {
                    manifests.append(entry)
                } else if FileManager.default.fileExists(atPath: entry.path, isDirectory: &isDirectory), isDirectory.boolValue {
                    pending.append(entry)
                }
            }
        }
        return manifests.sorted { $0.path < $1.path }
    }
}
