import Foundation

package struct GateConfig: Equatable, Sendable {
    package let usage: URL
    package let packagePath: URL
    package let userDefaultsAppGroup: Bool
    package let trackingDisabled: Bool

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
        usage = Self.resolve(raw.usage, against: directory, isDirectory: false)
        packagePath = try raw.packagePath.map { Self.resolve($0, against: directory, isDirectory: true) }
            ?? Self.repositoryRoot(above: directory)
        userDefaultsAppGroup = raw.policy.userDefaultsAppGroup
        trackingDisabled = raw.policy.trackingDisabled
    }

    private static func resolve(_ path: String, against directory: URL, isDirectory: Bool) -> URL {
        URL(fileURLWithPath: path, isDirectory: isDirectory, relativeTo: directory).standardizedFileURL
    }

    private static func repositoryRoot(above directory: URL) throws -> URL {
        let components = directory.pathComponents
        guard let index = components.lastIndex(of: ".github") else {
            throw ToolError(message: "key \"packagePath\" is absent and the config is not under a .github directory")
        }
        return URL(fileURLWithPath: NSString.path(withComponents: Array(components[..<index])), isDirectory: true)
    }
}

private struct RawConfig: Decodable {
    let usage: String
    let packagePath: String?
    let policy: Policy

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
    }

    init(from decoder: Decoder) throws {
        try decoder.rejectUnknownKeys(of: CodingKeys.self)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        usage = try container.decode(String.self, forKey: .usage)
        packagePath = try container.contains(.packagePath) ? container.decode(String.self, forKey: .packagePath) : nil
        policy = try container.decode(Policy.self, forKey: .policy)
    }

    init(contentsOf file: URL) throws {
        self = try StrictJSON.decode(RawConfig.self, contentsOf: file, document: "the config")
    }
}
