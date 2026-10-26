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

private func bootTimeCall(_ api: String, in file: String) -> [String: String] {
    ["module": "Lib", "file": file, "api": api, "reason": "35F9.1", "purpose": "Measure elapsed time"]
}

private func gateFiles(packagePath: String? = nil, calls: [[String: String]] = []) throws -> [String: String] {
    var config: [String: Any] = ["usage": "usage.json", "policy": ["userDefaultsAppGroup": false, "trackingDisabled": true]]
    if let packagePath {
        config["packagePath"] = packagePath
    }
    let usage: [String: Any] = ["calls": calls, "privateUserDefaultsSuites": [String](), "overrides": [String]()]
    return [
        ".github/privacy-manifest/config.json": try json(config),
        ".github/privacy-manifest/usage.json": try json(usage)
    ]
}

private func json(_ object: [String: Any]) throws -> String {
    try #require(String(bytes: JSONSerialization.data(withJSONObject: object, options: .sortedKeys), encoding: .utf8))
}

private func makeRepository(at root: URL, _ files: [String: String]) throws -> URL {
    try writeFiles(files, to: root)
    return root.appending(path: ".github/privacy-manifest/config.json")
}

private func check(_ configFile: URL) throws -> (config: GateConfig, title: String, violations: [Violation]) {
    let config = try GateConfig.load(configFile)
    let result = try Gate.check(config: config, rules: Rules.load(RulesBundle.directory.appending(path: "rules.json")), today: Date())
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
        let config = try makeRepository(at: root, try gateFiles().merging([
            "Package.swift": libPackage,
            "Lib/Clock.swift": clock,
            "Lib/PrivacyInfo.xcprivacy": String(contentsOf: testData("manifests/Logger.xcprivacy"), encoding: .utf8)
        ]) { $1 })
        let summary = root.appending(path: "step-summary.md")
        try Data("previous step\n".utf8).write(to: summary)
        let arguments = ["check", "--config", config.path]

        let result = try await #require(processExitsWith: .exitCode(1), observing: [\.standardOutputContent]) { [arguments = arguments as [String], summary = summary.path as String?] in
            runCommand(arguments, stepSummary: summary)
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
        let config = try makeRepository(at: root, try gateFiles(calls: [bootTimeCall("mach_absolute_time", in: "Lib/Clock.swift")]).merging([
            "Package.swift": libPackage,
            "Lib/Clock.swift": clock,
            "Lib/PrivacyInfo.xcprivacy": privacyManifest([bootTime: "35F9.1"])
        ]) { $1 })
        let arguments = ["check", "--config", config.path]

        let result = try await #require(processExitsWith: .success, observing: [\.standardOutputContent]) { [arguments = arguments as [String]] in
            runCommand(arguments, stepSummary: nil)
        }

        #expect(try text(result.standardOutputContent) == "Privacy manifest gate, check of Sample: 0 violations\n")
    }

    @Test("a broken usage.json is a tool error naming the file, on stderr and as an annotation")
    func brokenUsageIsToolError() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        var files = try gateFiles().merging(["Package.swift": libPackage, "Lib/Clock.swift": clock]) { $1 }
        files[".github/privacy-manifest/usage.json"] = "{"
        let arguments = ["check", "--config", try makeRepository(at: root, files).path]

        let result = try await #require(processExitsWith: .exitCode(2), observing: [\.standardOutputContent, \.standardErrorContent]) { [arguments = arguments as [String]] in
            runCommand(arguments, stepSummary: nil)
        }

        #expect(try text(result.standardErrorContent).contains("usage.json: not valid JSON"))
        let annotation = try text(result.standardOutputContent)
        #expect(annotation.hasPrefix("::error title=privacy manifest tool error::/"))
        #expect(annotation.hasSuffix("/.github/privacy-manifest/usage.json: not valid JSON\n"))
    }

    @Test("an unknown argument exits 2")
    func unknownArgumentExitsTwo() async throws {
        let result = try await #require(processExitsWith: .exitCode(2), observing: [\.standardOutputContent, \.standardErrorContent]) {
            runCommand(["check", "--config", "config.json", "--lanes", "source"], stepSummary: nil)
        }

        #expect(try text(result.standardErrorContent).contains("Unknown option '--lanes'"))
        #expect(try text(result.standardOutputContent) == "::error title=privacy manifest tool error::Unknown option '--lanes'\n")
    }

    @Test("a package with an Objective-C target fails with UNSCANNABLE_SOURCE, and package and manifest violations come before the policy ones")
    func objectiveCTargetIsUnscannable() throws {
        try withTemporaryDirectory { root in
            let configFile = try makeRepository(at: root, try gateFiles().merging([
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

    @Test("a package below a repository root reached through a symlink keeps findings, usage.json entries and annotations repository-relative")
    func packageBelowRepositoryRoot() throws {
        try withTemporaryDirectory { directory in
            let repository = directory.appending(path: "repository", directoryHint: .isDirectory)
            let root = directory.appending(path: "link", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(at: root, withDestinationURL: repository)
            let source = clock + "\npublic let uptimeKey = \"systemUptime\"\n"
            let configFile = try makeRepository(at: root, try gateFiles(
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
