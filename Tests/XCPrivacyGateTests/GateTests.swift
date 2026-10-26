import Foundation
import Testing
import XCPrivacyGate
import XCPrivacyGateRules

private let bootTime = "NSPrivacyAccessedAPICategorySystemBootTime"
private let userDefaults = "NSPrivacyAccessedAPICategoryUserDefaults"
private let clock = "import Darwin\n\npublic func now() -> UInt64 { mach_absolute_time() }\n"
private let libPackage = packageManifest(
    #"Package(name: "Sample", platforms: [.iOS(.v15)], targets: [.target(name: "Lib", path: "Lib", resources: [.process("PrivacyInfo.xcprivacy")])])"#
)

private func privacyManifest(_ reasons: [String: String]) -> String {
    let entries = reasons.sorted { $0.key < $1.key }.map { category, reason in
        "<dict><key>NSPrivacyAccessedAPIType</key><string>\(category)</string>"
            + "<key>NSPrivacyAccessedAPITypeReasons</key><array><string>\(reason)</string></array></dict>"
    }
    return #"<?xml version="1.0" encoding="UTF-8"?>"# + "\n"
        + "<plist version=\"1.0\"><dict><key>NSPrivacyTracking</key><false/><key>NSPrivacyAccessedAPITypes</key><array>\(entries.joined())</array></dict></plist>\n"
}

private let trackingManifest = #"<?xml version="1.0" encoding="UTF-8"?>"# + "\n"
    + "<plist version=\"1.0\"><dict><key>NSPrivacyTracking</key><true/>"
    + "<key>NSPrivacyTrackingDomains</key><array><string>tracker.example.com</string></array></dict></plist>\n"

private func bootTimeCall(_ api: String, in file: String) -> [String: String] {
    ["module": "Lib", "file": file, "api": api, "reason": "35F9.1", "purpose": "Measure elapsed time"]
}

private func check(_ configFile: URL) throws -> (config: GateConfig, title: String, violations: [Violation]) {
    let config = try GateConfig.load(configFile)
    let result = try Gate.check(
        config: config,
        rules: Rules.load(RulesBundle.directory.appending(path: "rules.json")),
        appleSdks: SDKList.read(RulesBundle.directory.appending(path: SDKList.fileName)),
        today: Date()
    )
    return (config, result.title, result.violations)
}

private func text(_ bytes: [UInt8]) throws -> String {
    try #require(String(bytes: bytes, encoding: .utf8))
}

@Suite("Check")
struct GateTests {
    @Test("check exits 1 with one annotation per violation, a summary and a step summary appended to the file")
    func violationsExitOne() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let config = try makeGateRepository(at: root, try gateFiles().merging([
            "Package.swift": libPackage,
            "Lib/Clock.swift": clock,
            "Lib/PrivacyInfo.xcprivacy": String(contentsOf: testData("manifests/Logger.xcprivacy"), encoding: .utf8)
        ]) { $1 })
        let summary = root.appending(path: "step-summary.md")
        try Data("previous step\n".utf8).write(to: summary)
        let arguments = ["check", "--config", config.path]

        let result = try await #require(processExitsWith: .exitCode(1), observing: [\.standardOutputContent]) { [arguments = arguments as [String], summary = summary.path as String?] in
            await runCommand(arguments, stepSummary: summary)
        }

        let output = try text(result.standardOutputContent)
        let annotations = output.split(separator: "\n").filter { $0.hasPrefix("::error ") }.map { $0.components(separatedBy: "::")[1] }
        #expect(annotations == [
            "error file=Lib/PrivacyInfo.xcprivacy,title=EXTRA_CATEGORY",
            "error file=Lib/PrivacyInfo.xcprivacy,title=MISSING_CATEGORY",
            "error file=Lib/Clock.swift,line=3,title=UNREGISTERED_CALL"
        ])
        let report = try #require(output.range(of: "Privacy manifest gate").map { output[$0.lowerBound...] })
        #expect(report.hasPrefix("Privacy manifest gate, check of Sample: 3 violations\n"))
        #expect(report.contains("MISSING_CATEGORY Lib: "))
        #expect(report.contains(bootTime))
        let step = try String(contentsOf: summary, encoding: .utf8)
        #expect(step.hasPrefix("previous step\n### Privacy manifest gate, check of Sample: 3 violations\n\n- `EXTRA_CATEGORY` Lib: "))
        #expect(step.split(separator: "\n").filter { $0.hasPrefix("- `") }.count == 3)
        #expect(step.hasSuffix(".\n\n"))
    }

    @Test("check exits 0 with only the summary when the manifest and usage.json match the code")
    func matchingManifestExitsZero() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let config = try makeGateRepository(at: root, try gateFiles(calls: [bootTimeCall("mach_absolute_time", in: "Lib/Clock.swift")]).merging([
            "Package.swift": libPackage,
            "Lib/Clock.swift": clock,
            "Lib/PrivacyInfo.xcprivacy": privacyManifest([bootTime: "35F9.1"])
        ]) { $1 })
        let arguments = ["check", "--config", config.path]

        let result = try await #require(processExitsWith: .success, observing: [\.standardOutputContent]) { [arguments = arguments as [String]] in
            await runCommand(arguments, stepSummary: nil)
        }

        #expect(try text(result.standardOutputContent) == "Privacy manifest gate, check of Sample: 0 violations\n")
    }

    @Test("a broken usage.json is a tool error naming the file, on stderr and as an annotation")
    func brokenUsageIsToolError() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        var files = try gateFiles().merging(["Package.swift": libPackage, "Lib/Clock.swift": clock]) { $1 }
        files[".github/privacy-manifest/usage.json"] = "{"
        let arguments = ["check", "--config", try makeGateRepository(at: root, files).path]

        let result = try await #require(processExitsWith: .exitCode(2), observing: [\.standardOutputContent, \.standardErrorContent]) { [arguments = arguments as [String]] in
            await runCommand(arguments, stepSummary: nil)
        }

        #expect(try text(result.standardErrorContent).contains("usage.json: not valid JSON"))
        let annotation = try text(result.standardOutputContent)
        #expect(annotation.hasPrefix("::error title=privacy manifest tool error::/"))
        #expect(annotation.hasSuffix("/.github/privacy-manifest/usage.json: not valid JSON\n"))
    }

    @Test("an unknown argument exits 2")
    func unknownArgumentExitsTwo() async throws {
        let result = try await #require(processExitsWith: .exitCode(2), observing: [\.standardOutputContent, \.standardErrorContent]) {
            await runCommand(["check", "--config", "config.json", "--lanes", "source"], stepSummary: nil)
        }

        #expect(try text(result.standardErrorContent).contains("Unknown option '--lanes'"))
        #expect(try text(result.standardOutputContent) == "::error title=privacy manifest tool error::Unknown option '--lanes'\n")
    }

    @Test("the bare command without a subcommand exits 2 and says a subcommand is required")
    func bareCommandExitsTwo() async throws {
        let result = try await #require(processExitsWith: .exitCode(2), observing: [\.standardErrorContent]) {
            await runCommand([], stepSummary: nil)
        }

        #expect(try text(result.standardErrorContent).hasPrefix("Error: a subcommand is required\n"))
    }

    @Test("--help exits 0 with the overview")
    func helpExitsZero() async throws {
        let result = try await #require(processExitsWith: .success, observing: [\.standardOutputContent]) {
            await runCommand(["--help"], stepSummary: nil)
        }

        #expect(try text(result.standardOutputContent).hasPrefix("OVERVIEW: "))
    }

    @Test("--version exits 0 and prints the tool version")
    func versionExitsZero() async throws {
        let result = try await #require(processExitsWith: .success, observing: [\.standardOutputContent]) {
            await runCommand(["--version"], stepSummary: nil)
        }

        #expect(try text(result.standardOutputContent) == "\(ToolVersion.current)\n")
    }

    @Test("a package with an Objective-C target fails with UNSCANNABLE_SOURCE, and package and manifest violations come before the policy ones")
    func objectiveCTargetIsUnscannable() throws {
        try withTemporaryDirectory { root in
            let configFile = try makeGateRepository(at: root, try gateFiles().merging([
                "Package.swift": packageManifest("""
                    Package(
                        name: "Sample",
                        platforms: [.iOS(.v15)],
                        targets: [
                            .target(name: "Core", path: "Core", resources: [.process("PrivacyInfo.xcprivacy")]),
                            .target(name: "Lib", path: "Lib")
                        ]
                    )
                    """),
                "Core/Clock.swift": clock,
                "Core/PrivacyInfo.xcprivacy": privacyManifest([bootTime: "35F9.1", "NSPrivacyAccessedAPICategoryUnknown": "35F9.1"]),
                "Lib/Legacy.m": "#import \"Legacy.h\"\n\nint legacyAnswer(void) { return 42; }\n",
                "Lib/include/Legacy.h": "int legacyAnswer(void);\n"
            ]) { $1 })

            let (config, title, violations) = try check(configFile)

            #expect(title == "check of Sample")
            #expect(violations.map(\.code) == ["UNSCANNABLE_SOURCE", "MANIFEST_UNKNOWN_CATEGORY", "UNREGISTERED_CALL"])
            #expect(violations.first.map { Report.annotation($0, root: config.repositoryRoot) }
                == "::error file=Lib/Legacy.m,title=UNSCANNABLE_SOURCE::Lib: Legacy.m is not Swift; the source scan cannot read it")
            #expect(violations.last?.file == "Core/Clock.swift")
            #expect(violations.last?.line == 3)
        }
    }

    @Test("check puts SDK_ON_APPLE_LIST first when the bundled Apple list names the SDK that the config marks as not listed")
    func bundledAppleListNamesConfiguredSdk() throws {
        let listed = try #require(SDKList.read(RulesBundle.directory.appending(path: SDKList.fileName)).first)
        try withTemporaryDirectory { root in
            let configFile = try makeGateRepository(at: root, try gateFiles(appleSdkList: ["name": listed, "listed": false]).merging([
                "Package.swift": libPackage,
                "Lib/Clock.swift": clock,
                "Lib/PrivacyInfo.xcprivacy": privacyManifest([bootTime: "35F9.1"])
            ]) { $1 })

            let violations = try check(configFile).violations

            #expect(violations.map(\.code) == ["SDK_ON_APPLE_LIST", "UNREGISTERED_CALL"])
            #expect(violations.first?.message.contains("names \(listed)") == true)
        }
    }

    @Test(
        "check validates a manifest whatever the case of its file name and reports a name other than PrivacyInfo.xcprivacy",
        arguments: [
            ("PrivacyInfo.xcprivacy", "PrivacyInfo.xcprivacy", ["TRACKING_ENABLED"]),
            ("privacyinfo.xcprivacy", "privacyinfo.xcprivacy", ["MANIFEST_FILE_NAME", "TRACKING_ENABLED"]),
            ("Resources", "Resources/privacyinfo.xcprivacy", ["MANIFEST_FILE_NAME", "TRACKING_ENABLED"])
        ] as [(String, String, [String])]
    )
    func manifestOfAnyNameCaseIsValidated(resource: String, file: String, codes: [String]) throws {
        try withTemporaryDirectory { root in
            let configFile = try makeGateRepository(at: root, try gateFiles().merging([
                "Package.swift": packageManifest(
                    #"Package(name: "Sample", platforms: [.iOS(.v15)], targets: [.target(name: "Lib", path: "Lib", resources: [.process("\#(resource)")])])"#
                ),
                "Lib/Answer.swift": "public let answer = 42\n",
                "Lib/\(file)": trackingManifest
            ]) { $1 })

            #expect(try check(configFile).violations.map(\.code) == codes)
        }
    }

    @Test("a source in a symlinked target directory has one repository path in the index and string scans")
    func symlinkedSourceHasOnePath() throws {
        try withTemporaryDirectory { root in
            let call = ["module": "Core", "file": "Pod/Classes/Clock.swift", "api": "systemUptime", "reason": "35F9.1", "purpose": "Measure elapsed time"]
            let configFile = try makeGateRepository(at: root, try gateFiles(calls: [call]).merging([
                "Package.swift": packageManifest(
                    #"Package(name: "Sample", platforms: [.iOS(.v15)], targets: [.target(name: "Core", path: "Sources/Core", resources: [.process("PrivacyInfo.xcprivacy")])])"#
                ),
                "Pod/Classes/Clock.swift": "import Foundation\n\n"
                    + #"public func uptime() -> (TimeInterval, Any?) { (ProcessInfo.processInfo.systemUptime, ProcessInfo.processInfo.value(forKey: "systemUptime")) }"#
                    + "\n",
                "Pod/Classes/PrivacyInfo.xcprivacy": privacyManifest([bootTime: "35F9.1"])
            ]) { $1 })
            try FileManager.default.createDirectory(at: root.appending(path: "Sources"), withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(atPath: root.appending(path: "Sources/Core").path, withDestinationPath: "../Pod/Classes")

            let violations = try check(configFile).violations

            #expect(violations.isEmpty)
        }
    }

    @Test("a package below a repository root reached through a symlink keeps findings, usage.json entries and annotations repository-relative")
    func packageBelowRepositoryRoot() throws {
        try withTemporaryDirectory { directory in
            let repository = directory.appending(path: "repository", directoryHint: .isDirectory)
            let root = directory.appending(path: "link", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(at: root, withDestinationURL: repository)
            let source = clock + "\npublic let uptimeKey = \"systemUptime\"\n"
            let configFile = try makeGateRepository(at: root, try gateFiles(
                packagePath: "../../SDK",
                calls: [bootTimeCall("mach_absolute_time", in: "SDK/Lib/Clock.swift"), bootTimeCall("systemUptime", in: "SDK/Lib/Clock.swift")]
            ).merging([
                "SDK/Package.swift": libPackage,
                "SDK/Lib/Clock.swift": source,
                "SDK/Lib/PrivacyInfo.xcprivacy": privacyManifest([bootTime: "35F9.1", userDefaults: "CA92.1"])
            ]) { $1 })

            let (config, _, violations) = try check(configFile)

            #expect(violations.map { Report.annotation($0, root: config.repositoryRoot) } == [
                "::error file=SDK/Lib/PrivacyInfo.xcprivacy,title=EXTRA_CATEGORY::Lib: the manifest declares \(userDefaults), but no code in the module uses it. "
                    + "Remove the entry, or add an override with evidence to usage.json if Apple requires it"
            ])
        }
    }
}
