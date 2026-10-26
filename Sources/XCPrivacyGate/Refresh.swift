import Foundation

package struct RefreshResult: Sendable {
    package let changed: Bool
    package let body: String
}

package enum ApplePage: Sendable {
    case requiredReasons
    case dataTypes
    case purposes
    case tn3181
    case sdkList

    private static let documentData = "https://developer.apple.com/tutorials/data/documentation"
    private static let documentation = "https://developer.apple.com/documentation"
    private static let sdkRequirements = "https://developer.apple.com/support/third-party-SDK-requirements/"

    package var address: String {
        documentPath.map { "\(Self.documentData)/\($0).json" } ?? Self.sdkRequirements
    }

    var link: String {
        documentPath.map { "\(Self.documentation)/\($0)" } ?? Self.sdkRequirements
    }

    private var documentPath: String? {
        switch self {
        case .requiredReasons:
            "bundleresources/app-privacy-configuration/nsprivacyaccessedapitypes/nsprivacyaccessedapitype"
        case .dataTypes:
            "bundleresources/app-privacy-configuration/nsprivacycollecteddatatypes/nsprivacycollecteddatatype"
        case .purposes:
            "bundleresources/app-privacy-configuration/nsprivacycollecteddatatypes/nsprivacycollecteddatatypepurposes"
        case .tn3181:
            "technotes/tn3181-debugging-invalid-privacy-manifest"
        case .sdkList:
            nil
        }
    }
}

package enum Refresh {
    package static func run(rulesDirectory: URL, session: URLSession) async throws -> RefreshResult {
        let saved = try RulesFile.load(rulesDirectory.appending(path: RulesFile.fileName)).file
        let comparison = try await RulesComparison(saved: saved, rulesDirectory: rulesDirectory, pages: ApplePages.fetch(session: session))
        guard !comparison.changes.isEmpty else {
            return RefreshResult(changed: false, body: "")
        }
        try comparison.write(to: rulesDirectory)
        return RefreshResult(changed: true, body: comparison.pullRequestBody)
    }

    package static func check(config: GateConfig, rulesDirectory: URL, session: URLSession) async throws -> (title: String, violations: [Violation]) {
        let rules = try Rules.load(rulesDirectory.appending(path: RulesFile.fileName))
        let usage = try Usage.load(config.usage, rules: rules, userDefaultsAppGroup: config.userDefaultsAppGroup)
        let package = try PackageReader.read(root: config.packagePath)
        let targets = package.targets.map { $0.manifest == nil ? $0.shipping(package.unlistedManifests[$0.name]?.files.first) : $0 }
        let declared = declaredReasons(manifests: Gate.manifests(of: targets, rules: rules, trackingDisabled: config.trackingDisabled).manifests, usage: usage)
        let changed = try await RulesComparison.conditions(saved: rules.categories, apple: ApplePages.categories(session: session))
        var violations: [Violation] = []
        if let listing = config.appleSdkList, let verdict = SDKList.violation(names: try await ApplePages.sdks(session: session), expected: listing) {
            violations.append(verdict)
        }
        violations += changed.compactMap { condition in
            declared[condition.code].map { Violation(code: "DECLARED_REASON_CHANGED", module: nil, message: message(condition, declaredIn: $0)) }
        }
        return (title: "refresh check of \(package.name)", violations: violations)
    }

    package static func fetch(_ url: URL, session: URLSession) async throws -> Data {
        var request = URLRequest(url: url, timeoutInterval: 60)
        request.setValue("xcprivacy-gate/\(ToolVersion.current)", forHTTPHeaderField: "User-Agent")
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request, delegate: nil)
        } catch {
            throw ToolError(message: "\(url.absoluteString) could not be fetched: \(error.localizedDescription)")
        }
        let status = (response as? HTTPURLResponse)?.statusCode
        guard status == 200 else {
            throw ToolError(message: "\(url.absoluteString) answered \(status.map(String.init) ?? "without an HTTP status")")
        }
        return data
    }

    private static func declaredReasons(manifests: [String: Manifest], usage: Usage) -> [String: Set<String>] {
        var declared: [String: Set<String>] = [:]
        for (module, manifest) in manifests {
            for code in manifest.apiTypes.values.joined() {
                declared[code, default: []].insert("\(module) manifest")
            }
        }
        for entry in usage.entries {
            declared[entry.reason, default: []].insert("usage.json \(entry.module) \(entry.api)")
        }
        for override in usage.overrides {
            for code in override.reasons {
                declared[code, default: []].insert("usage.json override \(override.module)")
            }
        }
        return declared
    }

    private static func message(_ condition: ConditionChange, declaredIn sources: Set<String>) -> String {
        "\(condition.code) (\(condition.category)) is declared in \(sources.pythonSorted().joined(separator: ", ")), and Apple changed its condition; "
            + "check that the code still meets it: was \"\(condition.was)\", now \"\(condition.now)\" (\(ApplePage.requiredReasons.link))"
    }
}

struct ApplePages {
    let categories: [(name: String, body: AppleDocs.RequiredReasonCategory)]
    let dataTypes: [String]
    let purposes: [String]
    let tn3181: String
    let sdks: [String]

    static func fetch(session: URLSession) async throws -> ApplePages {
        let categories = try await categories(session: session)
        let dataTypes = try await document(.dataTypes, session: session)
        let purposes = try await document(.purposes, session: session)
        let tn3181 = try await document(.tn3181, session: session)
        let sdks = try await sdks(session: session)
        return try ApplePages(
            categories: categories,
            dataTypes: parsed(.dataTypes) { try AppleDocs.possibleValueNames(dataTypes) },
            purposes: parsed(.purposes) { try AppleDocs.possibleValueNames(purposes) },
            tn3181: parsed(.tn3181) { try AppleDocs.text(tn3181) },
            sdks: sdks
        )
    }

    static func categories(session: URLSession) async throws -> [(name: String, body: AppleDocs.RequiredReasonCategory)] {
        let required = try await document(.requiredReasons, session: session)
        let reasons = try parsed(.requiredReasons) { try AppleDocs.requiredReasons(required) }
        let order = try parsed(.requiredReasons) { try AppleDocs.possibleValueNames(required) }
        return order.compactMap { name in reasons[name].map { (name, $0) } }
    }

    static func sdks(session: URLSession) async throws -> [String] {
        try SDKList.names(page: await Refresh.fetch(url(.sdkList), session: session))
    }

    private static func document(_ page: ApplePage, session: URLSession) async throws -> [String: Any] {
        try AppleDocs.document(await Refresh.fetch(url(page), session: session), from: page.address)
    }

    private static func parsed<Value>(_ page: ApplePage, _ parse: () throws -> Value) throws -> Value {
        do {
            return try parse()
        } catch let error as ToolError {
            throw ToolError(message: "Apple changed the format of \(page.address): \(error.message)")
        }
    }

    private static func url(_ page: ApplePage) throws -> URL {
        guard let url = URL(string: page.address) else {
            throw ToolError(message: "\(page.address) is not a URL")
        }
        return url
    }
}
