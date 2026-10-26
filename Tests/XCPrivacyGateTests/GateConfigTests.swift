import Foundation
import Testing
import XCPrivacyGate
import XCPrivacyGateRules

@Suite("Gate config")
struct GateConfigTests {
    private let validConfig = #"""
        {"usage": "usage.json", "packagePath": ".", "policy": {"userDefaultsAppGroup": true, "trackingDisabled": true}, "appleSdkList": {"name": "Sample", "listed": false}}
        """#

    @Test("config resolves usage and package paths against its directory")
    func resolvesPathsAgainstItsDirectory() throws {
        try withTemporaryDirectory { root in
            try makeGitDirectory(in: root)
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

    @Test("packagePath defaults to the repository root")
    func packagePathDefaultsToRepositoryRoot() throws {
        try withTemporaryDirectory { root in
            try makeGitDirectory(in: root)
            let url = try writeConfig(
                #"{"usage": "usage.json", "policy": {"userDefaultsAppGroup": false, "trackingDisabled": true}}"#,
                at: ".github/privacy-manifest/config.json",
                in: root
            )

            let config = try GateConfig.load(url)

            #expect(try config.packagePath.path == canonical(root).path)
            #expect(config.usage.path == root.appendingPathComponent(".github/privacy-manifest/usage.json").standardizedFileURL.path)
            #expect(!config.userDefaultsAppGroup)
            #expect(config.trackingDisabled)
        }
    }

    @Test("the repository root is the canonical checkout, also when packagePath points below it")
    func repositoryRootIsCheckout() throws {
        try withTemporaryDirectory { root in
            try makeGitDirectory(in: root)
            let url = try writeConfig(
                #"{"usage": "usage.json", "packagePath": "../../SDK", "policy": {"userDefaultsAppGroup": true, "trackingDisabled": true}}"#,
                at: ".github/privacy-manifest/config.json",
                in: root
            )

            let config = try GateConfig.load(url)

            #expect(try config.repositoryRoot.path == canonical(root).path)
            #expect(config.packagePath.path == root.appendingPathComponent("SDK").standardizedFileURL.path)
        }
    }

    @Test("a config outside .github, in a subdirectory of a checkout, has the checkout as repository root and package")
    func configInCheckoutSubdirectory() throws {
        try withTemporaryDirectory { temporary in
            let checkout = try canonical(temporary).appendingPathComponent("checkout", isDirectory: true)
            try makeGitDirectory(in: checkout)
            let url = try writeConfig(configText(setting: "packagePath", to: nil), at: "ci/privacy/config.json", in: checkout)

            let config = try GateConfig.load(url)

            #expect(config.repositoryRoot.path == checkout.path)
            #expect(config.packagePath.path == checkout.path)
        }
    }

    @Test("a .git file, as in a worktree or submodule, marks the nearest checkout")
    func gitFileMarksCheckout() throws {
        try withTemporaryDirectory { temporary in
            let outer = try canonical(temporary).appendingPathComponent("outer", isDirectory: true)
            let inner = outer.appendingPathComponent("inner", isDirectory: true)
            try makeGitDirectory(in: outer)
            try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true)
            try Data("gitdir: ../.git/modules/inner\n".utf8).write(to: inner.appendingPathComponent(".git"))
            let url = try writeConfig(configText(setting: "packagePath", to: nil), at: "tools/.github/config.json", in: inner)

            let config = try GateConfig.load(url)

            #expect(config.repositoryRoot.path == inner.path)
            #expect(config.packagePath.path == inner.path)
        }
    }

    @Test("a config outside any git checkout is a tool error naming it")
    func configOutsideCheckoutIsAnError() throws {
        try withTemporaryDirectory { temporary in
            let url = try writeConfig(validConfig, at: "repository/.github/config.json", in: canonical(temporary))

            let message = try loadErrorMessage(url)

            #expect(message.contains("/repository/.github/config.json: "))
            #expect(message.contains("must live inside a git checkout"))
        }
    }

    @Test("a missing policy key is a tool error naming it", arguments: ["policy.userDefaultsAppGroup", "policy.trackingDisabled"])
    func missingPolicyKeyIsAnError(key: String) throws {
        try withTemporaryDirectory { root in
            let url = try writeConfig(try configText(setting: key, to: nil), at: "config.json", in: root)

            #expect(try loadErrorMessage(url).contains("\"\(key)\""))
        }
    }

    @Test("appleSdkList is read when the config has it and absent when it does not")
    func readsAppleSdkList() throws {
        try withTemporaryDirectory { root in
            try makeGitDirectory(in: root)
            let listed = try GateConfig.load(writeConfig(validConfig, at: "listed.json", in: root))
            let unlisted = try GateConfig.load(writeConfig(configText(setting: "appleSdkList", to: nil), at: "unlisted.json", in: root))

            #expect(listed.appleSdkList?.name == "Sample")
            #expect(listed.appleSdkList?.listed == false)
            #expect(unlisted.appleSdkList == nil)
        }
    }

    @Test("a missing appleSdkList key is a tool error naming it", arguments: ["appleSdkList.name", "appleSdkList.listed"])
    func missingAppleSdkListKeyIsAnError(key: String) throws {
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

    @Test("an unknown key is a tool error", arguments: ["extra", "policy.extra", "appleSdkList.extra"])
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
            ("policy.trackingDisabled", "null"),
            ("appleSdkList", "true"),
            ("appleSdkList", "null"),
            ("appleSdkList.name", "1"),
            ("appleSdkList.listed", "\"false\"")
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
            #expect(message.contains("cannot read the config"))
        }
    }

    @Test("the rules bundle holds rules.json, every fixture, tn3181.txt and Apple's SDK list")
    func rulesBundleHoldsRulesFixturesAndTechnote() throws {
        let directory = RulesBundle.directory
        let sourceRules = repositoryRoot.appendingPathComponent("Rules", isDirectory: true)

        let expectedFixtures = try relativeFiles(under: sourceRules.appendingPathComponent("fixtures"))
        let bundledFixtures = try relativeFiles(under: directory.appendingPathComponent("fixtures"))

        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("rules.json").path))
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("apple/tn3181.txt").path))
        #expect(try !SDKList.read(directory.appendingPathComponent(SDKList.fileName)).isEmpty)
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

    private func makeGitDirectory(in directory: URL) throws {
        try FileManager.default.createDirectory(at: directory.appendingPathComponent(".git", isDirectory: true), withIntermediateDirectories: true)
    }

    private func writeConfig(_ text: String, at path: String, in root: URL) throws -> URL {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        return url
    }
}
