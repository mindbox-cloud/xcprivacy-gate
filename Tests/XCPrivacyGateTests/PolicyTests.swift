import Foundation
import Testing
import XCPrivacyGate

private let userDefaults = "NSPrivacyAccessedAPICategoryUserDefaults"
private let diskSpace = "NSPrivacyAccessedAPICategoryDiskSpace"
private let bootTime = "NSPrivacyAccessedAPICategorySystemBootTime"
private let fileTimestamp = "NSPrivacyAccessedAPICategoryFileTimestamp"
private let loader = "Core/Storage/StorageLoader/StorageLoader.swift"
private let webViewSuite = "com.example.sdk.localState"
private let evidenceURL = "https://example.invalid/itms-91053"

private func moment(_ text: String) throws -> Date {
    try Date(text, strategy: .iso8601)
}

private func day(_ text: String) throws -> Date {
    try moment("\(text)T00:00:00Z")
}

private func target(_ name: String, manifest: Bool = true) -> PackageTarget {
    PackageTarget(
        name: name,
        path: URL(fileURLWithPath: "/package/\(name)", isDirectory: true),
        sources: [],
        manifest: manifest ? URL(fileURLWithPath: "/package/\(name)/PrivacyInfo.xcprivacy") : nil,
        definesDebugInRelease: false
    )
}

private func manifest(_ apiTypes: [String: [String]]) -> Manifest {
    Manifest(path: URL(fileURLWithPath: "/package/Core/PrivacyInfo.xcprivacy"), tracking: false, domains: [], apiTypes: apiTypes)
}

private func finding(_ api: String, _ categories: Set<String>, file: String = "Core/Foo.swift", line: Int = 1) -> Finding {
    Finding(api: api, categories: categories, file: file, line: line, evidence: api)
}

private func compiled(_ api: String, _ categories: Set<String>, evidence: String? = nil) -> Finding {
    Finding(api: api, categories: categories, file: nil, line: nil, evidence: evidence ?? "\(api) in Core.o")
}

private func uses(_ findings: Finding..., standard: Bool = false, suites: Set<String> = []) -> ModuleFindings {
    ModuleFindings(findings: findings, usesStandardDefaults: standard, privateSuites: suites)
}

private func registry(_ entries: UsageEntry..., overrides: [Override] = [], suites: [String] = [webViewSuite]) -> Usage {
    Usage(entries: entries, overrides: overrides, privateSuites: suites)
}

private func entry(_ api: String, _ reason: String, file: String = "Core/Foo.swift", module: String = "Core") -> UsageEntry {
    UsageEntry(module: module, file: file, api: api, reason: reason)
}

private func codes(_ violations: [Violation]) -> [String] {
    violations.map(\.code).sorted()
}

@Suite("Gate policy")
struct PolicyTests {
    private let rules: Rules
    private let today: Date

    init() throws {
        rules = try appleRules()
        today = try day("2026-10-25")
    }

    @Test("a used category the manifest does not declare is MISSING_CATEGORY with the registered reasons")
    func missingCategoryIsReported() throws {
        let violations = evaluate(uses(finding("mach_absolute_time", [bootTime])), declares: [:], registry: registry(entry("mach_absolute_time", "35F9.1")))

        #expect(codes(violations) == ["MISSING_CATEGORY"])
        let message = try #require(violations.first).message
        #expect(message.contains(bootTime))
        #expect(message.contains("35F9.1"))
    }

    @Test("a declared category no code uses is EXTRA_CATEGORY")
    func extraCategoryIsReported() {
        #expect(codes(evaluate(uses(), declares: [bootTime: ["35F9.1"]])) == ["EXTRA_CATEGORY"])
    }

    @Test("an unregistered call points at its line and lists Apple's reasons with their texts")
    func unregisteredCallListsReasons() throws {
        let violations = evaluate(uses(finding("mach_absolute_time", [bootTime], line: 12)), declares: [bootTime: ["35F9.1"]])

        #expect(codes(violations) == ["UNREGISTERED_CALL"])
        let violation = try #require(violations.first)
        #expect(violation.file == "Core/Foo.swift")
        #expect(violation.line == 12)
        #expect(violation.message.contains("35F9.1"))
        #expect(violation.message.contains("measure the amount of time"))
    }

    @Test("an entry without its call is STALE_ENTRY")
    func staleEntryIsReported() {
        #expect(codes(evaluate(uses(), declares: [:], registry: registry(entry("mach_absolute_time", "35F9.1")))) == ["STALE_ENTRY"])
    }

    @Test("a call that moved to another file is reported once as LIKELY_MOVE")
    func movedCallIsLikelyMove() throws {
        let violations = evaluate(
            uses(finding("mach_absolute_time", [bootTime], file: "Core/New.swift")),
            declares: [bootTime: ["35F9.1"]],
            registry: registry(entry("mach_absolute_time", "35F9.1", file: "Core/Old.swift"))
        )

        #expect(codes(violations) == ["LIKELY_MOVE"])
        let message = try #require(violations.first).message
        #expect(message.contains("Core/Old.swift"))
        #expect(message.contains("Core/New.swift"))
    }

    @Test("declared reasons must equal the registered reasons")
    func reasonsMustEqualRegistry() {
        let found = uses(finding("mach_absolute_time", [bootTime]))
        let registered = registry(entry("mach_absolute_time", "35F9.1"))

        #expect(codes(evaluate(found, declares: [bootTime: ["35F9.1", "8FFB.1"]], registry: registered)) == ["REASONS_MISMATCH"])
        #expect(codes(evaluate(found, declares: [bootTime: ["8FFB.1"]], registry: registered)) == ["REASONS_MISMATCH"])
        #expect(evaluate(found, declares: [bootTime: ["35F9.1"]], registry: registered) == [])
    }

    @Test("an entry with a reason of another category is REGISTRY_UNKNOWN_REASON")
    func registryUnknownReason() {
        let violations = evaluate(
            uses(finding("mach_absolute_time", [bootTime])),
            declares: [bootTime: ["35F9.1"]],
            registry: registry(entry("mach_absolute_time", "35F9.1"), entry("mach_absolute_time", "CA92.1"))
        )

        #expect(codes(violations).contains("REGISTRY_UNKNOWN_REASON"))
    }

    @Test("an API in two categories needs an entry for each")
    func sharedApiNeedsEntryPerCategory() throws {
        let violations = evaluate(
            uses(finding("getattrlist", [fileTimestamp, diskSpace])),
            declares: [fileTimestamp: ["C617.1"], diskSpace: ["E174.1"]],
            registry: registry(entry("getattrlist", "C617.1"))
        )

        let unregistered = violations.filter { $0.code == "UNREGISTERED_CALL" }
        #expect(unregistered.count == 1)
        #expect(try #require(unregistered.first).message.contains(diskSpace))
    }

    @Test("a binary finding with a registry entry in another file is explained")
    func binaryFindingWithEntryElsewhereIsExplained() {
        let found = uses(compiled("mach_absolute_time", [bootTime]))
        let registered = registry(entry("mach_absolute_time", "35F9.1"))

        #expect(evaluate(uses(), binary: found, declares: [bootTime: ["35F9.1"]], registry: registered) == [])
        #expect(codes(evaluate(uses(), binary: found, declares: [bootTime: ["8FFB.1"]], registry: registered)) == ["REASONS_MISMATCH"])
    }

    @Test("a binary-only API without an entry is BINARY_ONLY_API")
    func binaryOnlyApiWithoutEntryIsReported() throws {
        let violations = evaluate(uses(), binary: uses(compiled("systemUptime", [bootTime])), declares: [bootTime: ["35F9.1"]])

        #expect(codes(violations) == ["BINARY_ONLY_API"])
        let violation = try #require(violations.first)
        #expect(violation.module == "Core")
        #expect(violation.message.contains("systemUptime"))
        #expect(violation.message.contains("systemUptime in Core.o"))
    }

    @Test("a binary-only API covered by a live override passes")
    func binaryOnlyApiCoveredByOverridePasses() throws {
        let override = Override(module: "Core", category: bootTime, reasons: ["35F9.1"], evidence: evidenceURL, expires: try day("2026-12-31"))

        let violations = evaluate(
            uses(),
            binary: uses(compiled("systemUptime", [bootTime])),
            declares: [bootTime: ["35F9.1"]],
            registry: registry(overrides: [override])
        )

        #expect(violations == [])
    }

    @Test("two binary findings of one API report one BINARY_ONLY_API")
    func binaryOnlyApiIsReportedOncePerApi() {
        let binary = uses(
            compiled("systemUptime", [bootTime], evidence: "systemUptime in Core.o"),
            compiled("systemUptime", [bootTime], evidence: "systemUptime in a string")
        )

        #expect(codes(evaluate(uses(), binary: binary, declares: [bootTime: ["35F9.1"]])) == ["BINARY_ONLY_API"])
    }

    @Test("binary-only UserDefaults follows the App Group policy, not the registry")
    func binaryOnlyUserDefaultsFollowsAppGroupPolicy() {
        #expect(evaluate(uses(), binary: uses(compiled("UserDefaults", [userDefaults])), declares: [userDefaults: ["1C8F.1"]]) == [])
    }

    @Test("the same API in source and binary reports once")
    func sameApiInSourceAndBinaryReportsOnce() throws {
        let source = uses(finding("mach_absolute_time", [bootTime]))
        let binary = uses(compiled("mach_absolute_time", [bootTime]))

        let undeclared = evaluate(source, binary: binary, declares: [:])

        #expect(codes(evaluate(source, binary: binary, declares: [bootTime: ["35F9.1"]])) == ["UNREGISTERED_CALL"])
        #expect(codes(undeclared) == ["MISSING_CATEGORY", "UNREGISTERED_CALL"])
        let missing = try #require(undeclared.first { $0.code == "MISSING_CATEGORY" })
        #expect(missing.message.contains("(mach_absolute_time at Core/Foo.swift:1)"))
    }

    @Test("UserDefaults requires the App Group reason")
    func userDefaultsRequiresAppGroupReason() throws {
        let violations = evaluate(uses(finding("UserDefaults", [userDefaults])), declares: [userDefaults: ["CA92.1"]])

        #expect(codes(violations).contains("UD_APP_GROUP_REQUIRED"))
        let message = try #require(violations.first { $0.code == "UD_APP_GROUP_REQUIRED" }).message
        #expect(message.contains("userDefaultsAppGroup policy"))
    }

    @Test("standard defaults require CA92.1")
    func standardDefaultsRequireCA92() {
        let violations = evaluate(uses(finding("UserDefaults", [userDefaults]), standard: true), declares: [userDefaults: ["1C8F.1"]])

        #expect(codes(violations) == ["UD_STANDARD_REQUIRED"])
    }

    @Test("implicit standard defaults from either side require CA92.1", arguments: [true, false])
    func standardDefaultsFromEitherSideRequireCA92(fromSource: Bool) {
        let source = uses(finding("UserDefaults", [userDefaults]), standard: fromSource)
        let binary = uses(compiled("UserDefaults", [userDefaults]), standard: !fromSource)

        #expect(codes(evaluate(source, binary: binary, declares: [userDefaults: ["1C8F.1"]])) == ["UD_STANDARD_REQUIRED"])
    }

    @Test("a private suite from either side requires CA92.1", arguments: [true, false])
    func privateSuiteFromEitherSideRequiresCA92(fromSource: Bool) {
        let source = uses(finding("UserDefaults", [userDefaults]), suites: fromSource ? [webViewSuite] : [])
        let binary = uses(compiled("UserDefaults", [userDefaults]), suites: fromSource ? [] : [webViewSuite])

        #expect(codes(evaluate(source, binary: binary, declares: [userDefaults: ["1C8F.1"]])) == ["UD_STANDARD_REQUIRED"])
    }

    @Test("a private suite requires CA92.1")
    func privateSuiteRequiresCA92() {
        let violations = evaluate(uses(finding("UserDefaults", [userDefaults]), suites: [webViewSuite]), declares: [userDefaults: ["1C8F.1"]])

        #expect(codes(violations) == ["UD_STANDARD_REQUIRED"])
    }

    @Test("UserDefaults in the App Group suite with 1C8F.1 is clean")
    func appGroupOnlyIsClean() {
        #expect(evaluate(uses(finding("UserDefaults", [userDefaults])), declares: [userDefaults: ["1C8F.1"]]) == [])
    }

    @Test("CA92.1 without standard defaults or a private suite is UD_CA92_UNUSED")
    func unusedCA92IsReported() {
        let violations = evaluate(uses(finding("UserDefaults", [userDefaults])), declares: [userDefaults: ["1C8F.1", "CA92.1"]])

        #expect(codes(violations) == ["UD_CA92_UNUSED"])
    }

    @Test("another UserDefaults reason is REASONS_MISMATCH")
    func otherUserDefaultsReasonIsReported() {
        let violations = evaluate(uses(finding("UserDefaults", [userDefaults])), declares: [userDefaults: ["1C8F.1", "C56D.1"]])

        #expect(codes(violations) == ["REASONS_MISMATCH"])
    }

    @Test("without userDefaultsAppGroup, UserDefaults codes follow the registry")
    func userDefaultsFollowRegistryWithoutAppGroupPolicy() {
        let found = uses(finding("UserDefaults", [userDefaults]))
        let registered = registry(entry("UserDefaults", "CA92.1"))

        #expect(evaluate(found, declares: [userDefaults: ["CA92.1"]], registry: registered, userDefaultsAppGroup: false) == [])
        #expect(codes(evaluate(found, declares: [userDefaults: ["1C8F.1"]], registry: registered, userDefaultsAppGroup: false)) == ["REASONS_MISMATCH"])
        #expect(codes(evaluate(found, declares: [userDefaults: ["CA92.1"]], userDefaultsAppGroup: false)) == ["UNREGISTERED_CALL"])
    }

    @Test("a target without a manifest that uses an API is reported")
    func targetWithoutManifestUsingApiIsReported() {
        let violations = policy(registry()).evaluate(
            targets: [target("SDKVersionProvider", manifest: false)],
            source: [:],
            binary: ["SDKVersionProvider": uses(compiled("mach_absolute_time", [bootTime]))],
            manifests: [:]
        )

        #expect(codes(violations) == ["TARGET_WITHOUT_MANIFEST_USES_API"])
    }

    @Test("a live override allows a category without a call")
    func liveOverrideAllowsCategoryWithoutCall() throws {
        let override = Override(module: "Core", category: bootTime, reasons: ["35F9.1"], evidence: evidenceURL, expires: try day("2026-12-31"))

        #expect(evaluate(uses(), declares: [bootTime: ["35F9.1"]], registry: registry(overrides: [override])) == [])
    }

    @Test("an override stays live until its expiry day ends")
    func overrideExpiringTodayIsLive() throws {
        let override = Override(module: "Core", category: bootTime, reasons: ["35F9.1"], evidence: evidenceURL, expires: try day("2026-10-25"))

        let violations = policy(registry(overrides: [override]), today: try moment("2026-10-25T15:00:00Z")).evaluate(
            targets: [target("Core")],
            source: ["Core": uses()],
            binary: [:],
            manifests: ["Core": manifest([bootTime: ["35F9.1"]])]
        )

        #expect(violations == [])
    }

    @Test("an expired override is reported and no longer allows the category")
    func expiredOverrideIsReported() throws {
        let override = Override(module: "Core", category: bootTime, reasons: ["35F9.1"], evidence: evidenceURL, expires: try day("2026-10-01"))

        let violations = evaluate(uses(), declares: [bootTime: ["35F9.1"]], registry: registry(overrides: [override]))

        #expect(codes(violations) == ["EXTRA_CATEGORY", "OVERRIDE_EXPIRED"])
        #expect(try #require(violations.first { $0.code == "OVERRIDE_EXPIRED" }).message.contains("expired on 2026-10-01"))
    }

    @Test("the sample SDK reports exactly the four known violations")
    func sampleSDKReportsFourKnownViolations() throws {
        let names = ["Core", "Notifications", "Logger"]
        var manifests: [String: Manifest] = [:]
        for name in names {
            let (parsed, violations) = ManifestValidator.parse(
                try testData("manifests/\(name).xcprivacy"),
                module: name,
                rules: rules,
                trackingDisabled: true
            )
            #expect(violations == [])
            let manifest = try #require(parsed)
            manifests[name] = manifest
        }
        let source = [
            "Core": uses(
                finding("systemFreeSize", [diskSpace], file: loader, line: 28),
                finding("UserDefaults", [userDefaults], file: "Core/DI/Injections/InjectReplaceable.swift", line: 42),
                standard: true,
                suites: [webViewSuite]
            ),
            "Notifications": uses(),
            "Logger": uses(),
            "SDKVersionProvider": uses()
        ]
        let usage = try Usage.load(testData("usage/registry.json"), rules: rules, userDefaultsAppGroup: true)

        let violations = policy(usage).evaluate(
            targets: names.map { target($0) } + [target("SDKVersionProvider", manifest: false)],
            source: source,
            binary: [:],
            manifests: manifests
        )

        #expect(violations.map { "\($0.code) \($0.module ?? "")" } == [
            "MISSING_CATEGORY Core",
            "UD_APP_GROUP_REQUIRED Core",
            "EXTRA_CATEGORY Logger",
            "EXTRA_CATEGORY Notifications"
        ])
        let missing = try #require(violations.first { $0.code == "MISSING_CATEGORY" }).message
        #expect(missing.contains(diskSpace))
        #expect(missing.contains("E174.1"))
    }

    @Test("an entry for a module that is not a target is REGISTRY_UNKNOWN_MODULE")
    func registryEntryForUnknownModuleIsReported() {
        let violations = evaluate(uses(), declares: [:], registry: registry(entry("mach_absolute_time", "35F9.1", module: "Ghost")))

        #expect(codes(violations) == ["REGISTRY_UNKNOWN_MODULE"])
    }

    @Test("every message is English")
    func messagesAreEnglish() throws {
        let expired = Override(module: "Core", category: fileTimestamp, reasons: ["C617.1"], evidence: evidenceURL, expires: try day("2026-01-01"))
        let first = policy(registry(
            entry("systemUptime", "35F9.1", file: "Core/Old.swift"),
            entry("systemUptime", "35F9.1", module: "Ghost"),
            entry("mach_absolute_time", "CA92.1"),
            overrides: [expired]
        )).evaluate(
            targets: [target("Core"), target("Helper", manifest: false)],
            source: [
                "Core": uses(finding("mach_absolute_time", [bootTime]), finding("UserDefaults", [userDefaults]), standard: true),
                "Helper": uses(finding("systemUptime", [bootTime], file: "Helper/Clock.swift"))
            ],
            binary: [:],
            manifests: ["Core": manifest([userDefaults: ["AC6B.1"], diskSpace: ["E174.1"]])]
        )
        let second = evaluate(
            uses(finding("mach_absolute_time", [bootTime], file: "Core/New.swift"), finding("UserDefaults", [userDefaults])),
            declares: [bootTime: ["8FFB.1"], userDefaults: ["1C8F.1", "CA92.1"]],
            registry: registry(entry("mach_absolute_time", "35F9.1", file: "Core/Old.swift"))
        )
        let third = evaluate(
            uses(finding("mach_absolute_time", [bootTime])),
            declares: [bootTime: ["8FFB.1"]],
            registry: registry(entry("mach_absolute_time", "35F9.1"))
        )
        let fourth = evaluate(uses(), binary: uses(compiled("systemUptime", [bootTime])), declares: [bootTime: ["35F9.1"]])
        let violations = first + second + third + fourth

        #expect(Set(violations.map(\.code)) == [
            "BINARY_ONLY_API", "EXTRA_CATEGORY", "LIKELY_MOVE", "MISSING_CATEGORY", "OVERRIDE_EXPIRED", "REASONS_MISMATCH",
            "REGISTRY_UNKNOWN_MODULE", "REGISTRY_UNKNOWN_REASON", "STALE_ENTRY", "TARGET_WITHOUT_MANIFEST_USES_API",
            "UD_APP_GROUP_REQUIRED", "UD_CA92_UNUSED", "UD_STANDARD_REQUIRED", "UNREGISTERED_CALL"
        ])
        for violation in violations {
            #expect(!violation.message.unicodeScalars.contains { $0.properties.isAlphabetic && !$0.isASCII }, "\(violation.message)")
        }
    }

    @Test("violations come sorted by module, code, file and line")
    func violationsAreSorted() {
        let violations = policy(registry(entry("mach_absolute_time", "35F9.1", module: "Ghost"))).evaluate(
            targets: [target("Core"), target("Helper", manifest: false)],
            source: [
                "Core": uses(finding("mach_absolute_time", [bootTime], file: "Core/B.swift"), finding("systemUptime", [bootTime], file: "Core/A.swift", line: 9)),
                "Helper": uses(finding("systemUptime", [bootTime], file: "Helper/Clock.swift"))
            ],
            binary: [:],
            manifests: ["Core": manifest([bootTime: ["35F9.1"]])]
        )

        #expect(violations.map { "\($0.module ?? "") \($0.code) \($0.file ?? "")" } == [
            "Core UNREGISTERED_CALL Core/A.swift",
            "Core UNREGISTERED_CALL Core/B.swift",
            "Ghost REGISTRY_UNKNOWN_MODULE ",
            "Helper TARGET_WITHOUT_MANIFEST_USES_API "
        ])
    }

    private func policy(_ usage: Usage, userDefaultsAppGroup: Bool = true, today: Date? = nil) -> Policy {
        Policy(usage: usage, rules: rules, userDefaultsAppGroup: userDefaultsAppGroup, today: today ?? self.today)
    }

    private func evaluate(
        _ source: ModuleFindings,
        binary: ModuleFindings? = nil,
        declares apiTypes: [String: [String]],
        registry usage: Usage = registry(),
        userDefaultsAppGroup: Bool = true
    ) -> [Violation] {
        policy(usage, userDefaultsAppGroup: userDefaultsAppGroup).evaluate(
            targets: [target("Core")],
            source: ["Core": source],
            binary: binary.map { ["Core": $0] } ?? [:],
            manifests: ["Core": manifest(apiTypes)]
        )
    }
}
