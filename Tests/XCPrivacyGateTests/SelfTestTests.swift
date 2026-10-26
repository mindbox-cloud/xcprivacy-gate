import Foundation
import Testing
import XCPrivacyGate
import XCPrivacyGateRules

private let bootTime = "NSPrivacyAccessedAPICategorySystemBootTime"
private let diskSpace = "NSPrivacyAccessedAPICategoryDiskSpace"
private let fileTimestamp = "NSPrivacyAccessedAPICategoryFileTimestamp"
private let uptimeFixture = "fixtures/SystemBootTime/systemUptime.swift"
private let freeSizeFixture = "fixtures/DiskSpace/systemFreeSize.swift"
private let uptimeUsr = "c:objc(cs)NSProcessInfo(im)systemUptime"
private let freeSizeUsr = "c:@NSFileSystemFreeSize"

private func committedRules() throws -> Rules {
    try Rules.load(RulesBundle.directory.appending(path: "rules.json"))
}

private func codes(_ violations: [Violation]) -> [String] {
    Set(violations.map(\.code)).sorted()
}

private struct CompiledFixtures: SuiteTrait, TestScoping {
    @TaskLocal static var current: FixtureBuild?

    func provideScope(for test: Test, testCase: Test.Case?, performing function: @Sendable () async throws -> Void) async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let files = try SelfTest.fixtureFiles(rules: committedRules(), rulesDirectory: RulesBundle.directory)
        let build = try SelfTest.build(files, rulesDirectory: RulesBundle.directory, work: directory)
        try await Self.$current.withValue(build) {
            try await function()
        }
    }
}

extension Trait where Self == CompiledFixtures {
    fileprivate static var compiledFixtures: Self { Self() }
}

@Suite("Self-test")
struct SelfTestTests {
    @Test("every API in the committed rules has usrs, binary names and its Swift fixtures")
    func everyApiHasFixtureAndNames() throws {
        #expect(try SelfTest.incomplete(rules: committedRules(), rulesDirectory: RulesBundle.directory).isEmpty)
    }

    @Test("the committed rules pass the self-test")
    func committedRulesPassSelfTest() throws {
        #expect(try SelfTest.run(rules: committedRules(), rulesDirectory: RulesBundle.directory).isEmpty)
    }

    @Test("a rule without binary names is incomplete")
    func ruleWithoutBinaryNamesIsIncomplete() throws {
        let rules = try rules(with: ApiRule(api: "systemUptime", docc: nil, categories: [bootTime], fixtures: [uptimeFixture], usrs: [uptimeUsr]))

        let violations = SelfTest.incomplete(rules: rules, rulesDirectory: RulesBundle.directory)

        #expect(codes(violations) == ["RULE_INCOMPLETE"])
        #expect(violations.first?.message.contains("binary names") == true)
        #expect(violations.first?.message.contains("usrs") == false)
    }

    @Test("a rule without usrs is incomplete")
    func ruleWithoutUsrsIsIncomplete() throws {
        let rules = try rules(with: ApiRule(api: "systemUptime", docc: nil, categories: [bootTime], fixtures: [uptimeFixture], selectors: ["systemUptime"]))

        let violations = SelfTest.incomplete(rules: rules, rulesDirectory: RulesBundle.directory)

        #expect(codes(violations) == ["RULE_INCOMPLETE"])
        #expect(violations.first?.message.contains("usrs") == true)
        #expect(violations.first?.message.contains("binary names") == false)
    }

    @Test("a rule whose fixture file is missing is incomplete")
    func ruleWithMissingFixtureIsIncomplete() throws {
        let rules = try rules(with: ApiRule(
            api: "systemUptime",
            docc: nil,
            categories: [bootTime],
            fixtures: ["fixtures/none.swift"],
            usrs: [uptimeUsr],
            selectors: ["systemUptime"]
        ))

        let violations = SelfTest.incomplete(rules: rules, rulesDirectory: RulesBundle.directory)

        #expect(codes(violations) == ["RULE_INCOMPLETE"])
        #expect(violations.first?.message.contains("fixtures/none.swift") == true)
    }

    @Test("a rule without binary names makes the self-test run report it incomplete")
    func runReportsIncompleteRule() throws {
        let rules = try rules(with: ApiRule(api: "systemUptime", docc: nil, categories: [bootTime], fixtures: [uptimeFixture], usrs: [uptimeUsr]))

        let incomplete = try SelfTest.run(rules: rules, rulesDirectory: RulesBundle.directory).filter { $0.code == "RULE_INCOMPLETE" }

        #expect(incomplete.count == 1)
        #expect(incomplete.first?.message.contains("binary names") == true)
    }

    @Test("self-test exits 0 and writes its summary to a new step summary file")
    func selfTestCommandWritesStepSummary() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let summary = directory.appending(path: "step-summary.md")

        let result = try await #require(processExitsWith: .success, observing: [\.standardOutputContent]) { [summary = summary.path as String?] in
            await runCommand(["self-test"], stepSummary: summary)
        }

        #expect(String(bytes: result.standardOutputContent, encoding: .utf8) == "Privacy manifest gate, self-test: 0 violations\n")
        #expect(try String(contentsOf: summary, encoding: .utf8) == "### Privacy manifest gate, self-test: 0 violations\n\n\n")
    }

    @Suite("on the compiled fixtures", .compiledFixtures)
    struct CompiledFixtureTests {
        @Test("a fixture the rule no longer finds is missed in the source lane, every object and every linked library")
        func fixtureWithoutHitIsMissed() throws {
            let build = try #require(CompiledFixtures.current)
            let rules = try rules(with: ApiRule(
                api: "systemUptime",
                docc: nil,
                categories: [bootTime],
                fixtures: [uptimeFixture],
                usrs: ["c:objc(cs)NSProcessInfo(im)nothingMatches"],
                selectors: ["nothingMatches"]
            ))

            let violations = try SelfTest.compare(rules: rules, build: build)

            #expect(codes(violations) == ["FIXTURE_MISSED"])
            #expect(violations.count == 7)
            #expect(Set(violations.compactMap(\.file)) == ["Rules/fixtures/SystemBootTime/systemUptime.swift"])
        }

        @Test("a rule that also matches another fixture is crosstalk in the source lane and every object")
        func fixtureCrosstalkFails() throws {
            let build = try #require(CompiledFixtures.current)
            let rules = try rules(with: 
                ApiRule(api: "systemFreeSize", docc: nil, categories: [diskSpace], fixtures: [freeSizeFixture], usrs: [freeSizeUsr], symbols: ["_NSFileSystemFreeSize"]),
                ApiRule(
                    api: "creationDate",
                    docc: nil,
                    categories: [fileTimestamp],
                    fixtures: ["fixtures/FileTimestamp/creationDate.swift"],
                    usrs: [freeSizeUsr],
                    symbols: ["_NSFileSystemFreeSize"]
                )
            )

            let violations = try SelfTest.compare(rules: rules, build: build)

            let crosstalk = violations.filter { $0.code == "FIXTURE_CROSSTALK" }
            #expect(crosstalk.count == 4)
            #expect(crosstalk.allSatisfy { $0.message.contains("creationDate") })
            #expect(Set(crosstalk.compactMap(\.file)) == ["Rules/fixtures/DiskSpace/systemFreeSize.swift"])
        }

        @Test("a rule that matches a negative fixture is a negative hit")
        func negativeHitFails() throws {
            let build = try #require(CompiledFixtures.current)
            let rules = try rules(with: ApiRule(
                api: "systemUptime",
                docc: nil,
                categories: [bootTime],
                fixtures: [uptimeFixture],
                usrs: [uptimeUsr, "c:@F@CACurrentMediaTime"],
                symbols: ["_CACurrentMediaTime"],
                selectors: ["systemUptime"]
            ))

            let violations = try SelfTest.compare(rules: rules, build: build)

            #expect(codes(violations) == ["NEGATIVE_HIT"])
            #expect(violations.count == 4)
            #expect(violations.allSatisfy { $0.message.contains("mediaTime.swift") })
            #expect(Set(violations.compactMap(\.file)) == ["Rules/fixtures/negative/mediaTime.swift"])
        }
    }
}
