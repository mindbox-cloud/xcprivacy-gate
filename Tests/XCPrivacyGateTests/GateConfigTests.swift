import Foundation
import Testing
import XCPrivacyGate
import XCPrivacyGateRules

@Suite("Gate config")
struct GateConfigTests {
    private let validConfig = #"{"usage": "usage.json", "packagePath": ".", "policy": {"userDefaultsAppGroup": true, "trackingDisabled": true}}"#

    @Test("config resolves usage and package paths against its directory")
    func resolvesPathsAgainstItsDirectory() throws {
        try withTemporaryDirectory { root in
            let url = try writeConfig(
                #"{"usage": "data/usage.json", "packagePath": "../pkg", "policy": {"userDefaultsAppGroup": true, "trackingDisabled": false}}"#,
                at: "sub/config.json",
                in: root
            )

            let config = try GateConfig.load(url)

            #expect(config.usage.path == root.appendingPathComponent("sub/data/usage.json").standardizedFileURL.path)
            #expect(config.packagePath.path == root.appendingPathComponent("pkg").standardizedFileURL.path)
            #expect(config.userDefaultsAppGroup)
            #expect(!config.trackingDisabled)
        }
    }

    @Test("packagePath defaults to the directory that holds .github")
    func packagePathDefaultsToRepositoryRoot() throws {
        try withTemporaryDirectory { root in
            let url = try writeConfig(
                #"{"usage": "usage.json", "policy": {"userDefaultsAppGroup": false, "trackingDisabled": true}}"#,
                at: ".github/privacy-manifest/config.json",
                in: root
            )

            let config = try GateConfig.load(url)

            #expect(config.packagePath.path == root.standardizedFileURL.path)
            #expect(config.usage.path == root.appendingPathComponent(".github/privacy-manifest/usage.json").standardizedFileURL.path)
            #expect(!config.userDefaultsAppGroup)
            #expect(config.trackingDisabled)
        }
    }

    @Test("the nearest .github ancestor decides the default package path")
    func nearestGithubAncestorDecidesDefault() throws {
        try withTemporaryDirectory { root in
            let url = try writeConfig(
                #"{"usage": "usage.json", "policy": {"userDefaultsAppGroup": true, "trackingDisabled": true}}"#,
                at: ".github/tools/.github/config.json",
                in: root
            )

            let config = try GateConfig.load(url)

            #expect(config.packagePath.path == root.appendingPathComponent(".github/tools").standardizedFileURL.path)
        }
    }

    @Test("an absent packagePath outside a .github directory is a tool error naming it")
    func absentPackagePathOutsideGithubIsAnError() throws {
        try withTemporaryDirectory { root in
            let url = try writeConfig(
                try configText(setting: "packagePath", to: nil),
                at: "config/config.json",
                in: root
            )

            #expect(try loadErrorMessage(url).contains("\"packagePath\""))
        }
    }

    @Test("a missing policy key is a tool error naming it", arguments: ["policy.userDefaultsAppGroup", "policy.trackingDisabled"])
    func missingPolicyKeyIsAnError(key: String) throws {
        try withTemporaryDirectory { root in
            let url = try writeConfig(try configText(setting: key, to: nil), at: "config.json", in: root)

            #expect(try loadErrorMessage(url).contains("\"\(key)\""))
        }
    }

    @Test("a missing usage or policy section is a tool error naming it", arguments: ["usage", "policy"])
    func missingSectionIsAnError(key: String) throws {
        try withTemporaryDirectory { root in
            let url = try writeConfig(try configText(setting: key, to: nil), at: "config.json", in: root)

            #expect(try loadErrorMessage(url).contains("\"\(key)\""))
        }
    }

    @Test("an unknown key is a tool error", arguments: ["extra", "policy.extra"])
    func unknownKeyIsAnError(key: String) throws {
        try withTemporaryDirectory { root in
            let url = try writeConfig(try configText(setting: key, to: "true"), at: "config.json", in: root)

            #expect(try loadErrorMessage(url).contains("\"\(key)\""))
        }
    }

    @Test(
        "a value of the wrong type is a tool error naming the key",
        arguments: [
            ("usage", "5"),
            ("packagePath", "true"),
            ("packagePath", "null"),
            ("policy", "\"yes\""),
            ("policy.userDefaultsAppGroup", "1"),
            ("policy.trackingDisabled", "\"true\""),
            ("policy.trackingDisabled", "null")
        ]
    )
    func wrongTypeIsAnError(key: String, value: String) throws {
        try withTemporaryDirectory { root in
            let url = try writeConfig(try configText(setting: key, to: value), at: ".github/config.json", in: root)

            #expect(try loadErrorMessage(url).contains("\"\(key)\""))
        }
    }

    @Test("a file that is not JSON is a tool error")
    func nonJSONFileIsAnError() throws {
        try withTemporaryDirectory { root in
            let url = try writeConfig("usage = usage.json", at: "config.json", in: root)

            #expect(try loadErrorMessage(url).contains("not valid JSON"))
        }
    }

    @Test("a missing config file is a tool error")
    func missingFileIsAnError() throws {
        try withTemporaryDirectory { root in
            let message = try loadErrorMessage(root.appendingPathComponent("absent.json"))

            #expect(message.contains("absent.json"))
        }
    }

    @Test("the rules bundle holds rules.json, every fixture and tn3181.txt")
    func rulesBundleHoldsRulesFixturesAndTechnote() throws {
        let directory = RulesBundle.directory
        let sourceRules = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Rules", isDirectory: true)

        let expectedFixtures = try relativeFiles(under: sourceRules.appendingPathComponent("fixtures"))
        let bundledFixtures = try relativeFiles(under: directory.appendingPathComponent("fixtures"))

        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("rules.json").path))
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("apple/tn3181.txt").path))
        #expect(!expectedFixtures.isEmpty)
        #expect(bundledFixtures == expectedFixtures)
    }

    private func configText(setting keyPath: String, to rawValue: String?) throws -> String {
        let object = try #require(JSONSerialization.jsonObject(with: Data(validConfig.utf8)) as? [String: Any])
        let value = try rawValue.map { try JSONSerialization.jsonObject(with: Data($0.utf8), options: .fragmentsAllowed) }
        let changed = setting(value, at: ArraySlice(keyPath.split(separator: ".").map(String.init)), in: object)
        let data = try JSONSerialization.data(withJSONObject: changed, options: .sortedKeys)
        return try #require(String(bytes: data, encoding: .utf8))
    }

    private func setting(_ value: Any?, at keys: ArraySlice<String>, in object: [String: Any]) -> [String: Any] {
        guard let key = keys.first else { return object }
        var result = object
        if keys.count == 1 {
            result[key] = value
        } else if let nested = object[key] as? [String: Any] {
            result[key] = setting(value, at: keys.dropFirst(), in: nested)
        }
        return result
    }

    private func loadErrorMessage(_ url: URL) throws -> String {
        let error = #expect(throws: ToolError.self) { try GateConfig.load(url) }
        return try #require(error).message
    }

    private func withTemporaryDirectory<Result>(_ body: (URL) throws -> Result) throws -> Result {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        return try body(directory)
    }

    private func writeConfig(_ text: String, at path: String, in root: URL) throws -> URL {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        return url
    }

    private func relativeFiles(under directory: URL) throws -> Set<String> {
        let enumerator = try #require(
            FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])
        )
        let prefix = directory.standardizedFileURL.path + "/"
        var files: Set<String> = []
        for case let url as URL in enumerator where try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
            files.insert(String(url.standardizedFileURL.path.dropFirst(prefix.count)))
        }
        return files
    }
}
