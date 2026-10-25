import Foundation
import Testing
import XCPrivacyGate

private let uptimeCall = #"{"module": "Mindbox", "file": "a.swift", "api": "systemUptime", "reason": "35F9.1", "purpose": "x"}"#
private let bootTimeOverride = #"{"module": "Mindbox", "category": "NSPrivacyAccessedAPICategorySystemBootTime", "reasons": ["35F9.1"], "evidence": "x", "expires": "2026-12-31"}"#

private func document(calls: String = "[]", suites: String = "[]", overrides: String = "[]") -> String {
    #"{"calls": \#(calls), "privateUserDefaultsSuites": \#(suites), "overrides": \#(overrides)}"#
}

@Suite("Usage registry")
struct UsageTests {
    private let rules: Rules

    init() throws {
        rules = try appleRules()
    }

    @Test("ios-sdk's registry loads")
    func repositoryRegistryLoads() throws {
        let usage = try Usage.load(testData("usage/ios-sdk.json"), rules: rules, userDefaultsAppGroup: true)

        #expect(usage.entries.first?.api == "systemFreeSize")
        #expect(usage.privateSuites == ["cloud.Mindbox.webview.localState"])
        #expect(usage.overrides.isEmpty)
    }

    @Test("an unknown API is a tool error naming it")
    func unknownApiIsAnError() throws {
        let call = #"{"module": "Mindbox", "file": "a.swift", "api": "uptime", "reason": "35F9.1", "purpose": "x"}"#

        #expect(try loadErrorMessage(document(calls: "[\(call)]")).contains("'uptime'"))
    }

    @Test("a UserDefaults entry is a tool error under the App Group policy")
    func userDefaultsEntryIsAnError() throws {
        let call = #"{"module": "Mindbox", "file": "a.swift", "api": "UserDefaults", "reason": "CA92.1", "purpose": "x"}"#

        #expect(try loadErrorMessage(document(calls: "[\(call)]")).contains("UserDefaults follows the userDefaultsAppGroup policy"))
    }

    @Test("a UserDefaults override is a tool error under the App Group policy")
    func userDefaultsOverrideIsAnError() throws {
        let override = #"{"module": "Mindbox", "category": "NSPrivacyAccessedAPICategoryUserDefaults", "reasons": ["CA92.1"], "evidence": "x", "expires": "2026-12-31"}"#

        #expect(try loadErrorMessage(document(overrides: "[\(override)]")).contains("UserDefaults follows the userDefaultsAppGroup policy"))
    }

    @Test("without userDefaultsAppGroup, UserDefaults entries and overrides load")
    func userDefaultsEntriesLoadWithoutAppGroupPolicy() throws {
        let call = #"{"module": "Mindbox", "file": "a.swift", "api": "UserDefaults", "reason": "CA92.1", "purpose": "x"}"#
        let override = #"{"module": "Mindbox", "category": "NSPrivacyAccessedAPICategoryUserDefaults", "reasons": ["CA92.1"], "evidence": "x", "expires": "2026-12-31"}"#

        let usage = try load(document(calls: "[\(call)]", overrides: "[\(override)]"), userDefaultsAppGroup: false)

        #expect(usage.entries.map(\.api) == ["UserDefaults"])
        #expect(usage.overrides.map(\.category) == ["NSPrivacyAccessedAPICategoryUserDefaults"])
    }

    @Test("an empty purpose is a tool error naming it")
    func emptyPurposeIsAnError() throws {
        let call = #"{"module": "Mindbox", "file": "a.swift", "api": "systemUptime", "reason": "35F9.1", "purpose": " "}"#

        #expect(try loadErrorMessage(document(calls: "[\(call)]")).contains("purpose"))
    }

    @Test("an expiry that is not a calendar date is a tool error naming the override", arguments: ["2026-02-30", "2026-10-25x", "25.10.2026"])
    func invalidExpiryIsAnError(expires: String) throws {
        let override = bootTimeOverride.replacingOccurrences(of: "2026-12-31", with: expires)

        let message = try loadErrorMessage(document(overrides: "[\(override)]"))

        #expect(message.contains("override Mindbox NSPrivacyAccessedAPICategorySystemBootTime"))
        #expect(message.contains("expires"))
    }

    @Test(
        "a malformed registry is a tool error naming the file and what is wrong",
        arguments: [
            (#"{"privateUserDefaultsSuites": [], "overrides": []}"#, #""calls""#),
            (#"{"calls": [], "privateUserDefaultsSuites": [], "overrides": [], "extra": 1}"#, #""extra""#),
            (document(calls: "[\(uptimeCall.replacingOccurrences(of: "}", with: #", "note": "x"}"#))]"), #""note""#),
            (document(calls: "[\(uptimeCall.replacingOccurrences(of: #", "purpose": "x""#, with: ""))]"), #""purpose""#),
            (document(suites: #""x""#), #""privateUserDefaultsSuites""#),
            (document(suites: #"[""]"#), "privateUserDefaultsSuites must be a list of non-empty strings"),
            (document(overrides: "[\(bootTimeOverride.replacingOccurrences(of: "SystemBootTime", with: "Uptime"))]"), "unknown category"),
            (document(overrides: "[\(bootTimeOverride.replacingOccurrences(of: #"["35F9.1"]"#, with: "[]"))]"), "reasons must be a non-empty list of strings"),
            (document(overrides: "[\(bootTimeOverride.replacingOccurrences(of: #", "expires": "2026-12-31""#, with: ""))]"), #""expires""#)
        ]
    )
    func malformedRegistryIsAnError(text: String, expected: String) throws {
        let message = try loadErrorMessage(text)

        #expect(message.contains("usage.json: "))
        #expect(message.contains(expected))
    }

    private func load(_ text: String, userDefaultsAppGroup: Bool = true) throws -> Usage {
        try withTemporaryDirectory { directory in
            let url = directory.appendingPathComponent("usage.json")
            try Data(text.utf8).write(to: url)
            return try Usage.load(url, rules: rules, userDefaultsAppGroup: userDefaultsAppGroup)
        }
    }

    private func loadErrorMessage(_ text: String) throws -> String {
        let error = #expect(throws: ToolError.self) { try load(text) }
        return try #require(error).message
    }
}
