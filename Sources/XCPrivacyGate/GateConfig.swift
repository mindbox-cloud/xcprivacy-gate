import Foundation

public struct GateConfig: Equatable, Sendable {
    public let usage: URL
    public let packagePath: URL
    public let userDefaultsAppGroup: Bool
    public let trackingDisabled: Bool

    public static func load(_ url: URL) throws -> GateConfig {
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
        let data: Data
        do {
            data = try Data(contentsOf: file)
        } catch {
            throw ToolError(message: "cannot read the config: \(error.localizedDescription)")
        }
        do {
            self = try JSONDecoder().decode(RawConfig.self, from: data)
        } catch let error as DecodingError {
            throw ToolError(message: Self.describe(error))
        }
    }

    private static func describe(_ error: DecodingError) -> String {
        switch error {
        case .keyNotFound(let key, let context):
            "missing key \(quoted(context.codingPath + [key]))"
        case .typeMismatch(_, let context), .valueNotFound(_, let context):
            context.codingPath.isEmpty ? "the config must be a JSON object" : "wrong type for key \(quoted(context.codingPath))"
        case .dataCorrupted:
            "not valid JSON"
        @unknown default:
            "invalid config: \(error)"
        }
    }
}

private func quoted(_ path: [any CodingKey]) -> String {
    "\"\(path.map(\.stringValue).joined(separator: "."))\""
}

private struct AnyKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }

    init(_ stringValue: String) {
        self.stringValue = stringValue
    }

    init?(stringValue: String) {
        self.init(stringValue)
    }

    init?(intValue: Int) {
        return nil
    }
}

private extension Decoder {
    func rejectUnknownKeys<Keys: CodingKey & CaseIterable>(of keys: Keys.Type) throws {
        let known = Set(Keys.allCases.map(\.stringValue))
        let container = try container(keyedBy: AnyKey.self)
        let unknown = container.allKeys.map(\.stringValue).filter { !known.contains($0) }.sorted()
        if let first = unknown.first {
            throw ToolError(message: "unknown key \(quoted(codingPath + [AnyKey(first)]))")
        }
    }
}
