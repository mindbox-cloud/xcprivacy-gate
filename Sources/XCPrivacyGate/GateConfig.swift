import Foundation

package struct GateConfig: Sendable {
    package let usage: URL
    package let packagePath: URL
    package let repositoryRoot: URL
    package let userDefaultsAppGroup: Bool
    package let trackingDisabled: Bool
    package let appleSdkList: AppleSDKListing?

    package static func load(_ url: URL) throws -> GateConfig {
        let file = url.standardizedFileURL
        do {
            return try GateConfig(file: file)
        } catch let error as ToolError {
            throw ToolError(message: "\(file.path): \(error.message)")
        }
    }

    private init(file: URL) throws {
        let raw = try RawConfig(contentsOf: file)
        let directory = file.deletingLastPathComponent()
        repositoryRoot = try Self.checkout(containing: directory)
        usage = Self.resolve(raw.usage, against: directory, isDirectory: false)
        packagePath = raw.packagePath.map { Self.resolve($0, against: directory, isDirectory: true) } ?? repositoryRoot
        if let path = raw.packagePath {
            try Self.requirePackage(path, from: directory, inside: repositoryRoot)
        }
        userDefaultsAppGroup = raw.policy.userDefaultsAppGroup
        trackingDisabled = raw.policy.trackingDisabled
        appleSdkList = raw.appleSdkList
    }

    private static func resolve(_ path: String, against directory: URL, isDirectory: Bool) -> URL {
        URL(fileURLWithPath: path, isDirectory: isDirectory, relativeTo: directory).standardizedFileURL
    }

    private static func requirePackage(_ packagePath: String, from directory: URL, inside checkout: URL) throws {
        let resolved = resolve(packagePath, against: URL(fileURLWithPath: directory.canonicalPath, isDirectory: true), isDirectory: true).canonicalPath
        guard URL(fileURLWithPath: resolved).pathComponents.starts(with: checkout.pathComponents) else {
            throw ToolError(message: "\"packagePath\" resolves to \(resolved), outside the git checkout \(checkout.path) that holds the config")
        }
    }

    private static func checkout(containing directory: URL) throws -> URL {
        let components = URL(fileURLWithPath: directory.canonicalPath, isDirectory: true).pathComponents
        let ancestors = components.indices.reversed().map { NSString.path(withComponents: Array(components[...$0])) }
        guard let root = ancestors.first(where: { FileManager.default.fileExists(atPath: NSString.path(withComponents: [$0, ".git"])) }) else {
            throw ToolError(message: "the config must live inside a git checkout, but no directory above it holds a .git entry")
        }
        return URL(fileURLWithPath: root, isDirectory: true)
    }
}

private struct RawConfig: Decodable {
    let usage: String
    let packagePath: String?
    let policy: Policy
    let appleSdkList: AppleSDKListing?

    struct Policy: Decodable {
        let userDefaultsAppGroup: Bool
        let trackingDisabled: Bool

        enum CodingKeys: String, CodingKey, CaseIterable {
            case userDefaultsAppGroup
            case trackingDisabled
        }

        init(from decoder: Decoder) throws {
            try decoder.rejectUnknownKeys(of: CodingKeys.self)
            let container = try decoder.container(keyedBy: CodingKeys.self)
            userDefaultsAppGroup = try container.decode(Bool.self, forKey: .userDefaultsAppGroup)
            trackingDisabled = try container.decode(Bool.self, forKey: .trackingDisabled)
        }
    }

    enum CodingKeys: String, CodingKey, CaseIterable {
        case usage
        case packagePath
        case policy
        case appleSdkList
    }

    init(from decoder: Decoder) throws {
        try decoder.rejectUnknownKeys(of: CodingKeys.self)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        usage = try container.decode(String.self, forKey: .usage)
        packagePath = try container.contains(.packagePath) ? container.decode(String.self, forKey: .packagePath) : nil
        policy = try container.decode(Policy.self, forKey: .policy)
        appleSdkList = try container.contains(.appleSdkList) ? container.decode(AppleSDKListing.self, forKey: .appleSdkList) : nil
    }

    init(contentsOf file: URL) throws {
        self = try StrictJSON.decode(RawConfig.self, contentsOf: file, document: "the config")
    }
}
