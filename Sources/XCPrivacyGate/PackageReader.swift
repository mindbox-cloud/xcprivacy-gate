import Foundation

package struct PackageTarget: Equatable, Sendable {
    package let name: String
    package let path: URL
    package let sources: [URL]
    package let manifest: URL?
    package let resourceRule: String?
}

package struct PackageDescription: Sendable {
    package let name: String
    package let root: URL
    package let iosDeploymentTarget: String?
    package let targets: [PackageTarget]
    package let violations: [Violation]
}

package enum PackageReader {
    package static func describe(root: URL) throws -> Data {
        try Data(Toolchain.run(["swift", "package", "--package-path", root.path, "describe", "--type", "json"], in: nil).utf8)
    }

    package static func read(description: Data, root: URL) throws -> PackageDescription {
        let package = try decode(description)
        let base = try canonical(root)
        var violations = package.dependencies.map { dependency in
            Violation(
                code: "PACKAGE_DEPENDENCY",
                module: nil,
                message: "package dependency \(dependency.identity.pythonRepr): its code is invisible to the source scan"
            )
        }
        var targets: [PackageTarget] = []
        for target in package.targets {
            switch target.type {
            case "library":
                targets.append(target.packageTarget(in: base, violations: &violations))
            case "binary":
                violations.append(Violation(
                    code: "PACKAGE_DEPENDENCY",
                    module: target.name,
                    message: "binary target \(target.name.pythonRepr): its code is invisible to the source scan"
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
            root: base,
            iosDeploymentTarget: package.platforms.first(where: { $0.name == "ios" })?.version,
            targets: targets,
            violations: violations
        )
    }

    private static func decode(_ description: Data) throws -> DescribedPackage {
        do {
            return try JSONDecoder().decode(DescribedPackage.self, from: description)
        } catch {
            throw ToolError(message: "swift package describe printed unexpected output: \(StrictJSON.message(error, document: "the output"))")
        }
    }

    private static func canonical(_ root: URL) throws -> URL {
        guard let resolved = realpath(root.path, nil) else {
            throw ToolError(message: "cannot resolve the package root \(root.path): \(String(cString: strerror(errno)))")
        }
        defer { free(resolved) }
        return URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
    }
}

private struct DescribedPackage: Decodable {
    let name: String
    let platforms: [Platform]
    let dependencies: [Dependency]
    let targets: [Target]

    struct Platform: Decodable {
        let name: String
        let version: String
    }

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
        let rule: [String: [String: String]]
    }
}

private extension DescribedPackage.Target {
    func packageTarget(in root: URL, violations: inout [Violation]) -> PackageTarget {
        let directory = root.appendingPathComponent(path, isDirectory: true).standardized
        let declared = resources?.first { URL(fileURLWithPath: $0.path, isDirectory: false).lastPathComponent == ManifestValidator.fileName }
        let unwired = directory.appendingPathComponent(ManifestValidator.fileName)
        if declared == nil, FileManager.default.fileExists(atPath: unwired.path) {
            violations.append(Violation(
                code: "MANIFEST_NOT_WIRED",
                module: name,
                message: "\(name): \(ManifestValidator.fileName) exists but Package.swift does not list it in resources",
                file: unwired.path
            ))
        }
        let files = sources.map { directory.appendingPathComponent($0, isDirectory: false) }
        for (source, file) in zip(sources, files) where file.pathExtension != "swift" {
            violations.append(Violation(
                code: "UNSCANNABLE_SOURCE",
                module: name,
                message: "\(name): \(source) is not Swift; the source scan cannot read it",
                file: file.path
            ))
        }
        return PackageTarget(
            name: name,
            path: directory,
            sources: files.filter { $0.pathExtension == "swift" },
            manifest: declared.map { URL(fileURLWithPath: $0.path, isDirectory: false) },
            resourceRule: declared?.rule.keys.first
        )
    }
}
