import Foundation

package struct ApiRule: Codable, Equatable, Sendable {
    package var api: String
    package var docc: String?
    package var categories: [String]
    package var strings: [String]
    package var usrPrefixes: [String]
    package var fixtures: [String]
    package var usrs: [String]
    package var symbols: [String]
    package var selectors: [String]
    package var swiftSymbols: [String]

    package init(
        api: String,
        docc: String?,
        categories: [String],
        strings: [String] = [],
        usrPrefixes: [String] = [],
        fixtures: [String] = [],
        usrs: [String] = [],
        symbols: [String] = [],
        selectors: [String] = [],
        swiftSymbols: [String] = []
    ) {
        self.api = api
        self.docc = docc
        self.categories = categories
        self.strings = strings
        self.usrPrefixes = usrPrefixes
        self.fixtures = fixtures
        self.usrs = usrs
        self.symbols = symbols
        self.selectors = selectors
        self.swiftSymbols = swiftSymbols
    }

    fileprivate enum CodingKeys: String, CodingKey, CaseIterable {
        case api
        case docc
        case categories
        case strings
        case usrPrefixes
        case fixtures
        case usrs
        case symbols
        case selectors
        case swiftSymbols
    }

    package init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let api = try container.decode(String.self, forKey: .api)
        do {
            try decoder.rejectUnknownKeys(of: CodingKeys.self)
            self.init(
                api: api,
                docc: try container.decode(String?.self, forKey: .docc),
                categories: try container.decode([String].self, forKey: .categories),
                strings: try container.decode([String].self, forKey: .strings),
                usrPrefixes: try container.decode([String].self, forKey: .usrPrefixes),
                fixtures: try container.decode([String].self, forKey: .fixtures),
                usrs: try container.decode([String].self, forKey: .usrs),
                symbols: try container.decode([String].self, forKey: .symbols),
                selectors: try container.decode([String].self, forKey: .selectors),
                swiftSymbols: try container.decode([String].self, forKey: .swiftSymbols)
            )
        } catch {
            throw ToolError(message: "\(api): \(StrictJSON.message(error, document: "the API entry", below: decoder.codingPath))")
        }
    }

    package func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(api, forKey: .api)
        try container.encode(docc, forKey: .docc)
        for (key, values) in lists {
            try container.encode(values, forKey: key)
        }
    }

    fileprivate var lists: [(key: CodingKeys, values: [String])] {
        [
            (.categories, categories),
            (.strings, strings),
            (.usrPrefixes, usrPrefixes),
            (.fixtures, fixtures),
            (.usrs, usrs),
            (.symbols, symbols),
            (.selectors, selectors),
            (.swiftSymbols, swiftSymbols)
        ]
    }
}

package struct CategoryReasons: Codable, Equatable, Sendable {
    package var reasons: [String: String]

    package init(reasons: [String: String]) {
        self.reasons = reasons
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case reasons
    }

    package init(from decoder: Decoder) throws {
        try decoder.rejectUnknownKeys(of: CodingKeys.self)
        reasons = try decoder.container(keyedBy: CodingKeys.self).decode([String: String].self, forKey: .reasons)
    }
}

package struct RulesFile: Codable, Equatable, Sendable {
    package var categories: [String: CategoryReasons]
    package var apis: [ApiRule]
    package var collectedDataTypes: [String]
    package var purposes: [String]

    package init(categories: [String: CategoryReasons], apis: [ApiRule], collectedDataTypes: [String], purposes: [String]) {
        self.categories = categories
        self.apis = apis
        self.collectedDataTypes = collectedDataTypes
        self.purposes = purposes
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case categories
        case apis
        case collectedDataTypes
        case purposes
    }

    package init(from decoder: Decoder) throws {
        try decoder.rejectUnknownKeys(of: CodingKeys.self)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        categories = try container.decode([String: CategoryReasons].self, forKey: .categories)
        apis = try container.decode([ApiRule].self, forKey: .apis)
        collectedDataTypes = try container.decode([String].self, forKey: .collectedDataTypes)
        purposes = try container.decode([String].self, forKey: .purposes)
    }
}

extension RulesFile {
    package static let fileName = "rules.json"

    static func load(_ url: URL) throws -> (file: RulesFile, rules: Rules) {
        try ToolError.inFile(url) { path in
            let file = try StrictJSON.decode(RulesFile.self, contentsOf: path, document: "the rules")
            return (file, try Rules(file))
        }
    }
}

package struct Rules: Sendable {
    package let categories: [String: [String: String]]
    package let apis: [String: ApiRule]
    package let dataTypes: Set<String>
    package let purposes: Set<String>

    var sortedApis: [ApiRule] {
        apis.values.sorted { $0.api < $1.api }
    }

    package static func load(_ url: URL) throws -> Rules {
        try RulesFile.load(url).rules
    }

    package init(_ file: RulesFile) throws {
        let categories = file.categories.mapValues(\.reasons)
        var apis: [String: ApiRule] = [:]
        for rule in file.apis {
            try Self.validate(rule, categories: categories)
            guard apis.updateValue(rule, forKey: rule.api) == nil else {
                throw ToolError(message: "\(rule.api): listed twice in the rules")
            }
        }
        self.categories = categories
        self.apis = apis
        dataTypes = Set(file.collectedDataTypes)
        purposes = Set(file.purposes)
    }

    private static func validate(_ rule: ApiRule, categories: [String: [String: String]]) throws {
        guard !rule.categories.isEmpty else {
            throw ToolError(message: "\(rule.api): lists no categories")
        }
        let unknown = rule.categories.filter { categories[$0] == nil }
        guard unknown.isEmpty else {
            throw ToolError(message: "\(rule.api): unknown categories \(unknown)")
        }
        if let list = rule.lists.first(where: { $0.values.contains("") }) {
            throw ToolError(message: "\(rule.api): \(list.key.rawValue) holds an empty string")
        }
    }
}
