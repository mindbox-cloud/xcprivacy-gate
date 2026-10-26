import Foundation
import os
import Testing
import XCPrivacyGate
import XCPrivacyGateRules

private let systemBootTime = "NSPrivacyAccessedAPICategorySystemBootTime"
private let activeKeyboards = "NSPrivacyAccessedAPICategoryActiveKeyboards"
private let userDefaults = "NSPrivacyAccessedAPICategoryUserDefaults"

private struct StubbedPage: Sendable {
    let status: Int
    let body: Data
}

private struct StubbedSite: Sendable {
    var pages: [String: StubbedPage] = [:]
    var requests: [URLRequest] = []
}

private final class StubbedApple: URLProtocol, @unchecked Sendable {
    static let siteHeader = "X-Stubbed-Site"
    static let sites = OSAllocatedUnfairLock<[String: StubbedSite]>(initialState: [:])

    override static func canInit(with request: URLRequest) -> Bool {
        true
    }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let request = request
        let page = Self.sites.withLock { sites -> StubbedPage? in
            let site = request.value(forHTTPHeaderField: Self.siteHeader) ?? ""
            sites[site, default: StubbedSite()].requests.append(request)
            return sites[site]?.pages[request.url?.absoluteString ?? ""]
        }
        guard let url = request.url, let page, let response = HTTPURLResponse(url: url, statusCode: page.status, httpVersion: "HTTP/1.1", headerFields: nil) else {
            client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: page.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private struct AppleSite {
    private let token = UUID().uuidString

    var session: URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubbedApple.self]
        configuration.httpAdditionalHeaders = [StubbedApple.siteHeader: token]
        return URLSession(configuration: configuration)
    }

    var requests: [URLRequest] {
        StubbedApple.sites.withLock { [token] in $0[token]?.requests ?? [] }
    }

    func serve(_ address: String, status: Int = 200, body: Data) {
        StubbedApple.sites.withLock { [token] in $0[token, default: StubbedSite()].pages[address] = StubbedPage(status: status, body: body) }
    }
}

private struct SavedPages {
    var bodies: [ApplePage: Data]

    init() throws {
        bodies = [
            .requiredReasons: try Data(contentsOf: testData("nsprivacyaccessedapitype-2026-10-25.json")),
            .dataTypes: try Data(contentsOf: testData("nsprivacycollecteddatatype-2026-10-25.json")),
            .purposes: try Data(contentsOf: testData("nsprivacycollecteddatatypepurposes-2026-10-25.json")),
            .tn3181: try Data(contentsOf: testData("apple/tn3181-2026-10-25.json")),
            .sdkList: try Data(contentsOf: testData("apple/third-party-sdks-2026-10-25.html"))
        ]
    }

    mutating func editJSON(_ page: ApplePage, _ change: (NSMutableDictionary) throws -> Void) throws {
        let object = try JSONSerialization.jsonObject(with: #require(bodies[page]), options: .mutableContainers)
        let document = try #require(object as? NSMutableDictionary)
        try change(document)
        bodies[page] = try JSONSerialization.data(withJSONObject: document)
    }

    mutating func editHTML(_ page: ApplePage, replacing old: String, with new: String) throws {
        let body = try #require(bodies[page])
        let html = try #require(String(bytes: body, encoding: .utf8))
        #expect(html.contains(old))
        bodies[page] = Data(html.replacingOccurrences(of: old, with: new).utf8)
    }

    func site() -> AppleSite {
        let site = AppleSite()
        for (page, body) in bodies {
            site.serve(page.address, body: body)
        }
        return site
    }

    func rulesDirectory() throws -> URL {
        let directory = try makeTemporaryDirectory()
        try FileManager.default.createDirectory(at: directory.appending(path: "apple"), withIntermediateDirectories: true)
        for file in ["rules.json", "apple/tn3181.txt"] {
            try FileManager.default.copyItem(at: RulesBundle.directory.appending(path: file), to: directory.appending(path: file))
        }
        let names = try SDKList.names(page: #require(bodies[.sdkList]))
        try Data(names.map { "\($0)\n" }.joined().utf8).write(to: directory.appending(path: SDKList.fileName))
        return directory
    }
}

private func refresh(_ pages: SavedPages, in directory: URL) async throws -> RefreshResult {
    try await Refresh.run(rulesDirectory: directory, session: pages.site().session)
}

private func refreshError(_ pages: SavedPages, in directory: URL) async throws -> String {
    let error = await #expect(throws: ToolError.self) { try await refresh(pages, in: directory) }
    return try #require(error).message
}

private func snapshot(_ directory: URL) throws -> [String: Data] {
    try Dictionary(uniqueKeysWithValues: relativeFiles(under: directory).map { ($0, try Data(contentsOf: directory.appending(path: $0))) })
}

private func rules(in directory: URL) throws -> RulesFile {
    try JSONDecoder().decode(RulesFile.self, from: Data(contentsOf: directory.appending(path: "rules.json")))
}

private func possibleValues(_ document: NSDictionary) throws -> NSMutableArray {
    let sections = try #require(document["primaryContentSections"] as? NSArray)
    let section = try #require(sections.lazy.compactMap { $0 as? NSDictionary }.first { $0["kind"] as? String == "possibleValues" })
    return try #require(section["values"] as? NSMutableArray)
}

private func category(_ document: NSDictionary, _ name: String) throws -> NSMutableDictionary {
    try #require(possibleValues(document).lazy.compactMap { $0 as? NSMutableDictionary }.first { $0["name"] as? String == name })
}

private func block(_ category: NSDictionary, type: String) throws -> NSMutableDictionary {
    let content = try #require(category["content"] as? NSArray)
    return try #require(content.lazy.compactMap { $0 as? NSMutableDictionary }.first { $0["type"] as? String == type })
}

private func reasonItems(_ document: NSDictionary, _ categoryName: String) throws -> NSMutableArray {
    try #require(block(category(document, categoryName), type: "termList")["items"] as? NSMutableArray)
}

private func appendToCondition(_ document: NSDictionary, _ categoryName: String, _ code: String, text: String) throws {
    let item = try #require(reasonItems(document, categoryName).lazy.compactMap { $0 as? NSDictionary }.first { item in
        let term = (item["term"] as? NSDictionary)?["inlineContent"] as? NSArray
        return (term?.firstObject as? NSDictionary)?["code"] as? String == code
    })
    let paragraphs = try #require((item["definition"] as? NSDictionary)?["content"] as? NSArray)
    try #require((paragraphs.lastObject as? NSDictionary)?["inlineContent"] as? NSMutableArray).add(["type": "text", "text": text])
}

private func appendToTN3181(_ document: NSDictionary, _ block: [String: Any]) throws {
    let section = try #require((document["primaryContentSections"] as? NSArray)?.firstObject as? NSDictionary)
    try #require(section["content"] as? NSMutableArray).add(block)
}

private func jsonText(_ object: [String: Any]) throws -> String {
    try #require(String(bytes: JSONSerialization.data(withJSONObject: object, options: .sortedKeys), encoding: .utf8))
}

private func makeSampleRepository(usage calls: [[String: String]], appleSdkList: [String: Any]?) throws -> URL {
    let root = try makeTemporaryDirectory()
    try FileManager.default.createDirectory(at: root.appending(path: ".git", directoryHint: .isDirectory), withIntermediateDirectories: true)
    var config: [String: Any] = ["usage": "usage.json", "policy": ["userDefaultsAppGroup": true, "trackingDisabled": true]]
    config["appleSdkList"] = appleSdkList
    let usage: [String: Any] = ["calls": calls, "privateUserDefaultsSuites": [String](), "overrides": [String]()]
    try writeFiles([
        "Package.swift": packageManifest("""
            Package(
                name: "Sample",
                platforms: [.iOS(.v15)],
                targets: [
                    .target(name: "Core", path: "Core", resources: [.process("PrivacyInfo.xcprivacy")]),
                    .target(name: "Logger", path: "Logger", resources: [.process("PrivacyInfo.xcprivacy")])
                ]
            )
            """),
        "Core/Core.swift": "public let core = 1\n",
        "Core/PrivacyInfo.xcprivacy": String(contentsOf: testData("manifests/Core.xcprivacy"), encoding: .utf8),
        "Logger/Logger.swift": "public let logger = 1\n",
        "Logger/PrivacyInfo.xcprivacy": String(contentsOf: testData("manifests/Logger.xcprivacy"), encoding: .utf8),
        ".github/privacy-manifest/config.json": jsonText(config),
        ".github/privacy-manifest/usage.json": jsonText(usage)
    ], to: root)
    return root
}

private func refreshCheck(_ pages: SavedPages, repository: URL, rulesDirectory: URL) async throws -> (title: String, violations: [Violation]) {
    let config = try GateConfig.load(repository.appending(path: ".github/privacy-manifest/config.json"))
    return try await Refresh.check(config: config, rulesDirectory: rulesDirectory, session: pages.site().session)
}

@Suite("Refresh")
struct RefreshTests {
    @Test("a refresh against unchanged pages reports no change, writes nothing and fetches every page once with the tool's user agent")
    func unchangedPagesReportNoChange() async throws {
        let pages = try SavedPages()
        let directory = try pages.rulesDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let before = try snapshot(directory)
        let site = pages.site()

        let result = try await Refresh.run(rulesDirectory: directory, session: site.session)

        #expect(!result.changed)
        #expect(result.body.isEmpty)
        #expect(try snapshot(directory) == before)
        let fetched: [ApplePage] = [.requiredReasons, .dataTypes, .purposes, .tn3181, .sdkList]
        #expect(site.requests.compactMap(\.url?.absoluteString).sorted() == fetched.map(\.address).sorted())
        #expect(site.requests.allSatisfy { $0.value(forHTTPHeaderField: "User-Agent") == "xcprivacy-gate/\(ToolVersion.current)" })
    }

    @Test("a new API lands at the end of the rules with empty human and learned fields")
    func newApiLandsWithEmptyFields() async throws {
        var pages = try SavedPages()
        try pages.editJSON(.requiredReasons) { document in
            try #require(block(category(document, activeKeyboards), type: "unorderedList")["items"] as? NSMutableArray)
                .add(["content": [["type": "paragraph", "inlineContent": [["type": "codeVoice", "code": "keyboardLayouts()"]]]]])
        }
        let directory = try pages.rulesDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let result = try await refresh(pages, in: directory)

        #expect(result.changed)
        #expect(result.body.contains("New API `keyboardLayouts`"))
        #expect(result.body.contains("xcprivacy-gate learn keyboardLayouts --rules-directory Rules"))
        #expect(try rules(in: directory).apis.last == ApiRule(api: "keyboardLayouts", docc: nil, categories: [activeKeyboards]))
    }

    @Test("a changed reason condition keeps every API's human and learned fields")
    func changedConditionKeepsApiFields() async throws {
        var pages = try SavedPages()
        try pages.editJSON(.requiredReasons) { try appendToCondition($0, activeKeyboards, "3EC4.1", text: " Updated.") }
        let directory = try pages.rulesDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let before = try rules(in: directory).apis

        let result = try await refresh(pages, in: directory)

        let after = try rules(in: directory)
        #expect(after.apis == before)
        #expect(after.categories[activeKeyboards]?.reasons["3EC4.1"]?.hasSuffix(" Updated.") == true)
        #expect(result.body.contains("`3EC4.1` (`\(activeKeyboards)`): was"))
    }

    @Test("a category gone from Apple's page is a tool error that writes nothing")
    func lostCategoryIsAnError() async throws {
        var pages = try SavedPages()
        try pages.editJSON(.requiredReasons) { document in
            try possibleValues(document).remove(category(document, activeKeyboards))
        }
        let directory = try pages.rulesDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let before = try snapshot(directory)

        let message = try await refreshError(pages, in: directory)

        #expect(message.contains(activeKeyboards))
        #expect(message.contains("check the parser before trusting a shrink"))
        #expect(try snapshot(directory) == before)
    }

    @Test("a reason gone from Apple's page is a tool error naming it")
    func lostReasonIsAnError() async throws {
        var pages = try SavedPages()
        try pages.editJSON(.requiredReasons) { document in
            let items = try reasonItems(document, activeKeyboards)
            items.removeObjects(in: NSRange(location: 1, length: items.count - 1))
        }
        let directory = try pages.rulesDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        #expect(try await refreshError(pages, in: directory).contains("54BD.1"))
    }

    @Test("HTML instead of JSON is a tool error")
    func htmlInsteadOfJsonIsAnError() async throws {
        var pages = try SavedPages()
        pages.bodies[.tn3181] = Data("<!DOCTYPE html><html><body>Moved</body></html>".utf8)
        let directory = try pages.rulesDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        #expect(try await refreshError(pages, in: directory).contains("\(ApplePage.tn3181.address) is not JSON"))
    }

    @Test("an unknown DocC block is a tool error naming it")
    func unknownDocCBlockIsAnError() async throws {
        var pages = try SavedPages()
        try pages.editJSON(.tn3181) { try appendToTN3181($0, ["type": "video", "identifier": "x"]) }
        let directory = try pages.rulesDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        #expect(try await refreshError(pages, in: directory).contains("\"video\""))
    }

    @Test("a TN3181 change lands in tn3181.txt and the body shows the diff")
    func tn3181ChangeIsSavedAndShown() async throws {
        var pages = try SavedPages()
        try pages.editJSON(.tn3181) { try appendToTN3181($0, ["type": "paragraph", "inlineContent": [["type": "text", "text": "A new failure mode."]]]) }
        let directory = try pages.rulesDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let rulesBefore = try Data(contentsOf: directory.appending(path: "rules.json"))

        let result = try await refresh(pages, in: directory)

        #expect(result.changed)
        #expect(result.body.contains("TN3181"))
        #expect(result.body.contains("\n+A new failure mode.\n"))
        #expect(try String(contentsOf: directory.appending(path: "apple/tn3181.txt"), encoding: .utf8).hasSuffix("\nA new failure mode.\n"))
        #expect(try Data(contentsOf: directory.appending(path: "rules.json")) == rulesBefore)
    }

    @Test("an SDK added to or removed from Apple's list lands in third-party-sdks.txt and the body")
    func sdkListChangeIsSavedAndShown() async throws {
        var pages = try SavedPages()
        let directory = try pages.rulesDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let before = try SDKList.read(directory.appending(path: SDKList.fileName))
        try pages.editHTML(.sdkList, replacing: "<li>Abseil</li>", with: "<li>Abseil</li>\n<li>Sample</li>")
        try pages.editHTML(.sdkList, replacing: "<li>Alamofire</li>", with: "")

        let result = try await refresh(pages, in: directory)

        let after = try SDKList.read(directory.appending(path: SDKList.fileName))
        #expect(after == [before[0], "Sample"] + before.dropFirst().filter { $0 != "Alamofire" })
        #expect(result.changed)
        #expect(result.body.contains("Apple's SDK list adds `Sample`"))
        #expect(result.body.contains("Apple's SDK list no longer names `Alamofire`"))
        #expect(result.body.contains(ApplePage.sdkList.address))
    }

    @Test(
        "refresh with options of neither form, or of both, exits 2 and names both forms",
        arguments: [["refresh"], ["refresh", "--rules-directory", "Rules"], ["refresh", "--check", "--config", "config.json", "--rules-directory", "Rules"]]
    )
    func refreshWithoutOneFormExitsTwo(arguments: [String]) async throws {
        let result = try await #require(processExitsWith: .exitCode(2), observing: [\.standardErrorContent]) { [arguments] in
            await runCommand(arguments, stepSummary: nil)
        }

        let errors = try #require(String(bytes: result.standardErrorContent, encoding: .utf8))
        #expect(errors.contains("refresh --rules-directory <path> --out-pr-body <path>, or refresh --check --config <path>"))
    }

    @Test("fetch returns the body of a 200 answer and sends the tool's user agent with a 60 second timeout")
    func fetchReturnsBody() async throws {
        let site = AppleSite()
        let url = try #require(URL(string: "https://example.com/page.json"))
        site.serve(url.absoluteString, body: Data("{}".utf8))

        let data = try await Refresh.fetch(url, session: site.session)

        #expect(data == Data("{}".utf8))
        let request = try #require(site.requests.first)
        #expect(request.value(forHTTPHeaderField: "User-Agent") == "xcprivacy-gate/\(ToolVersion.current)")
        #expect(request.timeoutInterval == 60)
    }

    @Test("fetch of an answer other than 200 is a tool error naming the status")
    func fetchNon200IsAnError() async throws {
        let site = AppleSite()
        let url = try #require(URL(string: "https://example.com/moved.json"))
        site.serve(url.absoluteString, status: 404, body: Data("{}".utf8))

        let error = await #expect(throws: ToolError.self) { try await Refresh.fetch(url, session: site.session) }

        #expect(try #require(error).message == "\(url.absoluteString) answered 404")
    }

    @Test("refresh --check reports changed conditions only for reasons the SDK declares, and writes nothing")
    func checkReportsChangedConditionsOfDeclaredReasons() async throws {
        var pages = try SavedPages()
        try pages.editJSON(.requiredReasons) { document in
            try appendToCondition(document, userDefaults, "CA92.1", text: " Updated.")
            try appendToCondition(document, systemBootTime, "35F9.1", text: " Updated.")
            try appendToCondition(document, activeKeyboards, "3EC4.1", text: " Updated.")
        }
        let call = ["module": "Core", "file": "Core/Core.swift", "api": "systemUptime", "reason": "35F9.1", "purpose": "Measure elapsed time"]
        let repository = try makeSampleRepository(usage: [call], appleSdkList: nil)
        let directory = try pages.rulesDirectory()
        defer {
            try? FileManager.default.removeItem(at: repository)
            try? FileManager.default.removeItem(at: directory)
        }
        let before = try snapshot(directory)

        let (title, violations) = try await refreshCheck(pages, repository: repository, rulesDirectory: directory)

        #expect(title == "refresh check of Sample")
        #expect(violations.map(\.code) == ["DECLARED_REASON_CHANGED", "DECLARED_REASON_CHANGED"])
        let bootTime = try #require(violations.first).message
        #expect(bootTime.contains("35F9.1"))
        #expect(bootTime.contains("usage.json Core systemUptime"))
        let defaults = try #require(violations.last).message
        #expect(defaults.contains("CA92.1"))
        #expect(defaults.contains("Core manifest, Logger manifest"))
        #expect(defaults.hasSuffix(" Updated.\" (https://developer.apple.com/documentation/bundleresources/app-privacy-configuration/nsprivacyaccessedapitypes/nsprivacyaccessedapitype)"))
        #expect(!violations.contains { $0.message.contains("3EC4.1") })
        #expect(try snapshot(directory) == before)
    }

    @Test(
        "refresh --check gives Apple's live verdict on the configured SDK",
        arguments: [("Alamofire", ["SDK_ON_APPLE_LIST"]), ("Sample", [])] as [(String, [String])]
    )
    func checkGivesLiveSdkListVerdict(name: String, codes: [String]) async throws {
        let pages = try SavedPages()
        let repository = try makeSampleRepository(usage: [], appleSdkList: ["name": name, "listed": false])
        let directory = try pages.rulesDirectory()
        defer {
            try? FileManager.default.removeItem(at: repository)
            try? FileManager.default.removeItem(at: directory)
        }
        try Data().write(to: directory.appending(path: SDKList.fileName))

        let violations = try await refreshCheck(pages, repository: repository, rulesDirectory: directory).violations

        #expect(violations.map(\.code) == codes)
    }
}
