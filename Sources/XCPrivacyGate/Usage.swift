import Foundation

package struct UsageEntry: Sendable {
    package let module: String
    package let file: String
    package let api: String
    package let reason: String

    package init(module: String, file: String, api: String, reason: String) {
        self.module = module
        self.file = file
        self.api = api
        self.reason = reason
    }
}

package struct Override: Sendable {
    package let module: String
    package let category: String
    package let reasons: [String]
    package let evidence: String
    package let expires: Date

    package init(module: String, category: String, reasons: [String], evidence: String, expires: Date) {
        self.module = module
        self.category = category
        self.reasons = reasons
        self.evidence = evidence
        self.expires = expires
    }

    static let dayFormat = Date.ISO8601FormatStyle().year().month().day()
}

package struct Usage: Sendable {
    package let entries: [UsageEntry]
    package let overrides: [Override]
    package let privateSuites: [String]

    package init(entries: [UsageEntry], overrides: [Override], privateSuites: [String]) {
        self.entries = entries
        self.overrides = overrides
        self.privateSuites = privateSuites
    }

    package static func load(_ url: URL, rules: Rules, userDefaultsAppGroup: Bool) throws -> Usage {
        try ToolError.inFile(url) { file in
            try Usage(StrictJSON.decode(RawUsage.self, contentsOf: file, document: "usage.json"), rules: rules, userDefaultsAppGroup: userDefaultsAppGroup)
        }
    }

    private init(_ raw: RawUsage, rules: Rules, userDefaultsAppGroup: Bool) throws {
        for call in raw.calls {
            guard let api = rules.apis[call.entry.api] else {
                throw ToolError(message: "\(call.label): unknown API \(call.entry.api.quoted)")
            }
            if userDefaultsAppGroup, api.categories.contains(UserDefaultsPolicy.category) {
                throw ToolError(message: "\(call.label): UserDefaults follows the userDefaultsAppGroup policy, not call entries")
            }
        }
        for item in raw.overrides {
            guard rules.categories[item.override.category] != nil else {
                throw ToolError(message: "\(item.label): unknown category")
            }
            if userDefaultsAppGroup, item.override.category == UserDefaultsPolicy.category {
                throw ToolError(message: "\(item.label): UserDefaults follows the userDefaultsAppGroup policy, not overrides")
            }
        }
        self.init(entries: raw.calls.map(\.entry), overrides: raw.overrides.map(\.override), privateSuites: raw.privateUserDefaultsSuites)
    }
}

private struct RawUsage: Decodable {
    let calls: [RawCall]
    let privateUserDefaultsSuites: [String]
    let overrides: [RawOverride]

    enum CodingKeys: String, CodingKey, CaseIterable {
        case calls
        case privateUserDefaultsSuites
        case overrides
    }

    init(from decoder: Decoder) throws {
        try decoder.rejectUnknownKeys(of: CodingKeys.self)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        calls = try container.decode([RawCall].self, forKey: .calls)
        privateUserDefaultsSuites = try container.decode([String].self, forKey: .privateUserDefaultsSuites)
        overrides = try container.decode([RawOverride].self, forKey: .overrides)
        if privateUserDefaultsSuites.contains(where: \.isEmpty) {
            throw ToolError(message: "privateUserDefaultsSuites must be a list of non-empty strings")
        }
    }
}

private struct RawCall: Decodable {
    let label: String
    let entry: UsageEntry

    enum CodingKeys: String, CodingKey, CaseIterable {
        case module
        case file
        case api
        case reason
        case purpose
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        label = container.label("call", naming: [.module, .file, .api])
        do {
            try decoder.rejectUnknownKeys(of: CodingKeys.self)
            entry = UsageEntry(
                module: try container.nonEmptyString(forKey: .module),
                file: try container.nonEmptyString(forKey: .file),
                api: try container.nonEmptyString(forKey: .api),
                reason: try container.nonEmptyString(forKey: .reason)
            )
            _ = try container.nonEmptyString(forKey: .purpose)
        } catch {
            throw ToolError(message: "\(label): \(StrictJSON.message(error, document: "the call", below: decoder.codingPath))")
        }
    }
}

private struct RawOverride: Decodable {
    let label: String
    let override: Override

    enum CodingKeys: String, CodingKey, CaseIterable {
        case module
        case category
        case reasons
        case evidence
        case expires
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        label = container.label("override", naming: [.module, .category])
        do {
            try decoder.rejectUnknownKeys(of: CodingKeys.self)
            let reasons = try container.decode([String].self, forKey: .reasons)
            if reasons.isEmpty || reasons.contains(where: \.isEmpty) {
                throw ToolError(message: "reasons must be a non-empty list of strings")
            }
            override = Override(
                module: try container.nonEmptyString(forKey: .module),
                category: try container.nonEmptyString(forKey: .category),
                reasons: reasons,
                evidence: try container.nonEmptyString(forKey: .evidence),
                expires: try Self.day(container.nonEmptyString(forKey: .expires))
            )
        } catch {
            throw ToolError(message: "\(label): \(StrictJSON.message(error, document: "the override", below: decoder.codingPath))")
        }
    }

    private static func day(_ text: String) throws -> Date {
        guard let date = try? Date(text, strategy: Override.dayFormat), date.formatted(Override.dayFormat) == text else {
            throw ToolError(message: "expires must be a calendar date written as YYYY-MM-DD, found \(text.quoted)")
        }
        return date
    }
}

private extension KeyedDecodingContainer {
    func nonEmptyString(forKey key: Key) throws -> String {
        let value = try decode(String.self, forKey: key)
        if value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw ToolError(message: "\(key.stringValue) must be a non-empty string")
        }
        return value
    }

    func label(_ kind: String, naming keys: [Key]) -> String {
        ([kind] + keys.compactMap { try? decode(String.self, forKey: $0) }).joined(separator: " ")
    }
}
