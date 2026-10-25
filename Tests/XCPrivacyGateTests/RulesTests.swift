import Foundation
import Testing
import XCPrivacyGate
import XCPrivacyGateRules

@Suite("Rules")
struct RulesTests {
    private static let systemBootTime = "NSPrivacyAccessedAPICategorySystemBootTime"

    @Test("rules load an API with its categories and names")
    func loadsApiWithItsCategoriesAndNames() throws {
        let rules = try load(rulesDocument())

        let api = try #require(rules.apis["systemUptime"])
        #expect(api.categories == [Self.systemBootTime])
        #expect(api.selectors == ["systemUptime"])
        #expect(api.usrs == ["c:objc(cs)NSProcessInfo(im)systemUptime"])
        #expect(api.fixtures == ["fixtures/SystemBootTime/systemUptime.swift"])
        #expect(rules.categories[Self.systemBootTime] == ["35F9.1": "Declare this reason to measure elapsed time."])
        #expect(rules.dataTypes.contains("NSPrivacyCollectedDataTypeDeviceID"))
    }

    @Test("rules load an API whose human and learned fields are empty")
    func loadsApiWithEmptyHumanFields() throws {
        let rules = try load(rulesDocument(api: ["strings": [], "usrPrefixes": [], "fixtures": [], "usrs": [], "selectors": []]))

        #expect(rules.apis["systemUptime"]?.fixtures == [])
    }

    @Test("an API without the fixtures key is a tool error naming the API and the key")
    func apiWithoutFixturesKeyIsAnError() throws {
        let message = try loadErrorMessage(rulesDocument(removing: "fixtures"))

        #expect(message.contains("systemUptime"))
        #expect(message.contains("\"fixtures\""))
    }

    @Test("an API with an unknown category is a tool error naming the API")
    func apiWithUnknownCategoryIsAnError() throws {
        let message = try loadErrorMessage(rulesDocument(api: ["categories": ["NSPrivacyAccessedAPICategoryMicrophone"]]))

        #expect(message.contains("systemUptime"))
        #expect(message.contains("NSPrivacyAccessedAPICategoryMicrophone"))
    }

    @Test("an unknown top-level key is a tool error naming it")
    func unknownTopLevelKeyIsAnError() throws {
        let message = try loadErrorMessage(rulesDocument(topLevel: ["appleSdkListIncludesMindbox": false]))

        #expect(message.contains("\"appleSdkListIncludesMindbox\""))
    }

    @Test("an unknown key in an API is a tool error naming the API and the key")
    func unknownApiKeyIsAnError() throws {
        let message = try loadErrorMessage(rulesDocument(api: ["fixture": "fixtures/SystemBootTime/systemUptime.swift"]))

        #expect(message.contains("systemUptime"))
        #expect(message.contains("\"fixture\""))
    }

    @Test("every JSON file in the tool equals JSONFormat output")
    func everyJSONFileEqualsJSONFormatOutput() throws {
        let files = try ["Rules", "Tests/XCPrivacyGateTests/Data"].flatMap { directory in
            try relativeFiles(under: repositoryRoot.appendingPathComponent(directory)).map { "\(directory)/\($0)" }
        }.filter { $0.hasSuffix(".json") }.sorted()

        #expect(files.contains("Rules/rules.json"))
        #expect(files.contains("Tests/XCPrivacyGateTests/Data/nsprivacyaccessedapitype-2026-10-25.json"))
        for file in files {
            let data = try Data(contentsOf: repositoryRoot.appendingPathComponent(file))
            let formatted = try JSONFormat.data(JSONDecoder().decode(JSONValue.self, from: data))
            #expect(formatted == data, "\(file) differs from JSONFormat output")
        }
    }

    @Test("rules.json lists exactly Apple's categories, APIs, data types and purposes from the saved pages")
    func rulesListExactlyApplesPages() throws {
        let rules = try Rules.load(RulesBundle.directory.appending(path: "rules.json"))
        let required = try AppleDocs.requiredReasons(applePage("nsprivacyaccessedapitype-2026-10-25.json"))
        var appleCategories: [String: Set<String>] = [:]
        for (category, body) in required {
            for entry in body.apis {
                appleCategories[entry.api, default: []].insert(category)
            }
        }

        #expect(rules.categories == required.mapValues { $0.reasons })
        #expect(rules.apis.mapValues { Set($0.categories) } == appleCategories)
        #expect(rules.dataTypes == Set(try AppleDocs.possibleValueNames(applePage("nsprivacycollecteddatatype-2026-10-25.json"))))
        #expect(rules.purposes == Set(try AppleDocs.possibleValueNames(applePage("nsprivacycollecteddatatypepurposes-2026-10-25.json"))))
    }

    private func rulesDocument(api overrides: [String: Any] = [:], removing removed: String? = nil, topLevel: [String: Any] = [:]) -> [String: Any] {
        var api: [String: Any] = [
            "api": "systemUptime",
            "docc": "doc://com.apple.documentation/documentation/Foundation/ProcessInfo/systemUptime",
            "categories": [Self.systemBootTime],
            "strings": ["systemUptime"],
            "usrPrefixes": [],
            "fixtures": ["fixtures/SystemBootTime/systemUptime.swift"],
            "usrs": ["c:objc(cs)NSProcessInfo(im)systemUptime"],
            "symbols": [],
            "selectors": ["systemUptime"],
            "swiftSymbols": []
        ]
        api.merge(overrides) { _, override in override }
        if let removed {
            api[removed] = nil
        }
        let document: [String: Any] = [
            "categories": [Self.systemBootTime: ["reasons": ["35F9.1": "Declare this reason to measure elapsed time."]]],
            "apis": [api],
            "collectedDataTypes": ["NSPrivacyCollectedDataTypeDeviceID"],
            "purposes": ["NSPrivacyCollectedDataTypePurposeAnalytics"]
        ]
        return document.merging(topLevel) { _, override in override }
    }

    private func load(_ document: [String: Any]) throws -> Rules {
        try withTemporaryDirectory { root in
            let url = root.appendingPathComponent("rules.json")
            try JSONSerialization.data(withJSONObject: document).write(to: url)
            return try Rules.load(url)
        }
    }

    private func loadErrorMessage(_ document: [String: Any]) throws -> String {
        let error = #expect(throws: ToolError.self) { try load(document) }
        return try #require(error).message
    }
}

private enum JSONValue: Codable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .double(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}
