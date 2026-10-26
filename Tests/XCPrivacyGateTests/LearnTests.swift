import Foundation
import Testing
import XCPrivacyGate
import XCPrivacyGateRules

private let uptimeFixture = RulesBundle.directory.appending(path: "fixtures/SystemBootTime/systemUptime.swift")
private let freeSizeFixture = RulesBundle.directory.appending(path: "fixtures/DiskSpace/systemFreeSize.swift")
private let statFixture = RulesBundle.directory.appending(path: "fixtures/FileTimestamp/stat.swift")
private let userDefaultsFixture = RulesBundle.directory.appending(path: "fixtures/UserDefaults/UserDefaults.swift")

private struct LearnedFixtures: SuiteTrait, TestScoping {
    @TaskLocal static var current: [URL: LearnedNames]?

    func provideScope(for test: Test, testCase: Test.Case?, performing function: @Sendable () async throws -> Void) async throws {
        let learned = try Learn.learn(fixtures: [uptimeFixture, freeSizeFixture, statFixture, userDefaultsFixture])
        try await Self.$current.withValue(learned) {
            try await function()
        }
    }
}

extension Trait where Self == LearnedFixtures {
    fileprivate static var learnedFixtures: Self { Self() }
}

private func learned(_ fixture: URL) throws -> LearnedNames {
    try #require(LearnedFixtures.current?[fixture])
}

@Suite("Learn", .learnedFixtures)
struct LearnTests {
    @Test("learn finds the systemUptime selector")
    func learnFindsSystemUptimeSelector() throws {
        #expect(try learned(uptimeFixture).selectors.contains("systemUptime"))
    }

    @Test("learn drops the names an empty baseline has")
    func learnDropsBaselineNames() throws {
        let symbols = try learned(uptimeFixture).symbols

        #expect(symbols.contains("_OBJC_CLASS_$_NSProcessInfo"))
        #expect(!symbols.contains { $0.hasPrefix("__swift_FORCE_LOAD_") }, "\(symbols)")
    }

    @Test("learn finds the systemFreeSize symbol")
    func learnFindsSystemFreeSizeSymbol() throws {
        #expect(try learned(freeSizeFixture).symbols.contains("_NSFileSystemFreeSize"))
    }

    @Test("learn finds c:objc(cs)NSProcessInfo(im)systemUptime and not processInfo")
    func learnFindsSystemUptimeUsrAndNotProcessInfo() throws {
        let names = try learned(uptimeFixture)

        let usrs = names.selected(for: "systemUptime").usrs

        #expect(names.usrs.contains { $0.contains("processInfo") })
        #expect(usrs.contains("c:objc(cs)NSProcessInfo(im)systemUptime"))
        #expect(!usrs.contains { $0.contains("processInfo") }, "\(usrs)")
    }

    @Test("learn finds c:@F@stat and not c:@S@stat")
    func learnFindsStatFunctionAndNotStruct() throws {
        let names = try learned(statFixture)

        let usrs = names.selected(for: "stat").usrs

        #expect(names.usrs.contains("c:@S@stat"))
        #expect(usrs == ["c:@F@stat"])
    }

    @Test("learn finds the UserDefaults initializer and not the UserDefaults class")
    func learnFindsUserDefaultsInitializerAndNotClass() throws {
        let names = try learned(userDefaultsFixture)

        let usrs = names.selected(for: "UserDefaults").usrs

        #expect(names.usrs.contains("c:objc(cs)NSUserDefaults"))
        #expect(usrs == ["c:objc(cs)NSUserDefaults(im)initWithSuiteName:"])
    }

    @Test("learning into rules keeps only the names of the API and writes the formatted file")
    func learnIntoRulesKeepsOnlyNamesOfTheApi() throws {
        try withTemporaryDirectory { directory in
            let fixture = directory.appending(path: "fixtures/SystemBootTime/systemUptime.swift")
            try FileManager.default.createDirectory(at: fixture.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: uptimeFixture, to: fixture)
            var file = try JSONDecoder().decode(RulesFile.self, from: Data(contentsOf: RulesBundle.directory.appending(path: "rules.json")))
            file.apis = [ApiRule(
                api: "systemUptime",
                docc: nil,
                categories: ["NSPrivacyAccessedAPICategorySystemBootTime"],
                strings: ["systemUptime"],
                fixtures: ["fixtures/SystemBootTime/systemUptime.swift"]
            )]
            let rulesFile = directory.appending(path: "rules.json")
            try JSONFormat.data(file).write(to: rulesFile)

            try Learn.update(rulesFile: rulesFile, api: "systemUptime")

            let data = try Data(contentsOf: rulesFile)
            let api = try #require(try JSONDecoder().decode(RulesFile.self, from: data).apis.first)
            #expect(api.usrs == ["c:objc(cs)NSProcessInfo(im)systemUptime", "c:objc(cs)NSProcessInfo(py)systemUptime"])
            #expect(api.symbols == [])
            #expect(api.selectors == ["systemUptime"])
            #expect(api.swiftSymbols == [])
            #expect(api.strings == ["systemUptime"])
            #expect(try JSONFormat.data(JSONDecoder().decode(RulesFile.self, from: data)) == data)
        }
    }

    @Test("learning an API the rules do not list is a tool error naming it")
    func learnUnknownApiIsToolError() throws {
        try withTemporaryDirectory { directory in
            let rulesFile = directory.appending(path: "rules.json")
            try FileManager.default.copyItem(at: RulesBundle.directory.appending(path: "rules.json"), to: rulesFile)

            let error = #expect(throws: ToolError.self) { try Learn.update(rulesFile: rulesFile, api: "uptime") }

            #expect(error?.message.contains("uptime") == true)
        }
    }
}
