import Foundation

package struct Manifest: Sendable {
    package let path: URL
    package let tracking: Bool
    package let domains: [String]
    package let apiTypes: [String: [String]]
}

package enum ManifestValidator {
    package static let fileName = "PrivacyInfo.xcprivacy"

    package static func parse(_ url: URL, module: String, rules: Rules, trackingDisabled: Bool) -> (Manifest?, [Violation]) {
        var check = ManifestCheck(url: url, module: module, rules: rules, trackingDisabled: trackingDisabled)
        let manifest = check.run()
        return (manifest, check.violations)
    }
}

private enum Key {
    static let tracking = "NSPrivacyTracking"
    static let domains = "NSPrivacyTrackingDomains"
    static let collected = "NSPrivacyCollectedDataTypes"
    static let apiTypes = "NSPrivacyAccessedAPITypes"
    static let apiType = "NSPrivacyAccessedAPIType"
    static let apiReasons = "NSPrivacyAccessedAPITypeReasons"
    static let dataType = "NSPrivacyCollectedDataType"
    static let dataLinked = "NSPrivacyCollectedDataTypeLinked"
    static let dataTracking = "NSPrivacyCollectedDataTypeTracking"
    static let dataPurposes = "NSPrivacyCollectedDataTypePurposes"
    static let topLevel: Set = [tracking, domains, collected, apiTypes]
    static let apiEntry: Set = [apiType, apiReasons]
    static let dataEntry: Set = [dataType, dataLinked, dataTracking, dataPurposes]
}

private struct ManifestCheck {
    let url: URL
    let module: String
    let rules: Rules
    let trackingDisabled: Bool
    var violations: [Violation] = []

    mutating func run() -> Manifest? {
        guard let content = read() else { return nil }
        let tracking = tracking(content)
        let domains = domains(content, tracking: tracking)
        checkCollected(content)
        let apiTypes = apiTypes(content)
        for key in content.keys.filter({ !Key.topLevel.contains($0) }).pythonSorted() {
            report("MANIFEST_UNKNOWN_KEY", "unknown top-level key \(key.pythonRepr)")
        }
        return Manifest(path: url, tracking: tracking, domains: domains, apiTypes: apiTypes)
    }

    private mutating func report(_ code: String, _ message: String) {
        violations.append(Violation(code: code, module: module, message: "\(url.path): \(message)", file: url.path))
    }

    private mutating func read() -> [String: PlistValue]? {
        guard let data = fileContents() else { return nil }
        let root: PlistValue
        do throws(PlistReadError) {
            root = try PlistReader.read(data)
        } catch {
            switch error {
            case .duplicateKey(let key):
                report("MANIFEST_DUPLICATE_KEY", "key \(key.pythonRepr) appears more than once")
            case .invalid(let message):
                report("MANIFEST_UNREADABLE", "not a valid property list: \(message)")
            }
            return nil
        }
        guard case .dictionary(let content) = root else {
            report("MANIFEST_UNREADABLE", "top level is \(root.pythonTypeName), expected a dictionary")
            return nil
        }
        return content
    }

    private mutating func fileContents() -> Data? {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)) ?? []
        guard names.contains(url.lastPathComponent) else {
            if let other = names.first(where: { $0.lowercased() == url.lastPathComponent.lowercased() }) {
                report("MANIFEST_FILE_NAME", "file is named \(other.pythonRepr), Apple requires \(ManifestValidator.fileName.pythonRepr)")
            } else {
                report("MANIFEST_MISSING_FILE", "file does not exist")
            }
            return nil
        }
        do {
            return try Data(contentsOf: url)
        } catch {
            report("MANIFEST_UNREADABLE", "cannot read the file: \(error.localizedDescription)")
            return nil
        }
    }

    private mutating func tracking(_ content: [String: PlistValue]) -> Bool {
        guard let value = content[Key.tracking] else {
            report("MANIFEST_MISSING_KEY", "missing key \(Key.tracking.pythonRepr)")
            return false
        }
        guard case .bool(let tracking) = value else {
            report("MANIFEST_TYPE", "\(Key.tracking) must be a Boolean, found \(value.pythonRepr)")
            return false
        }
        if tracking && trackingDisabled {
            report("TRACKING_ENABLED", "\(Key.tracking) is \(value.pythonRepr); the SDK must declare false")
        }
        return tracking
    }

    private mutating func domains(_ content: [String: PlistValue], tracking: Bool) -> [String] {
        let value = content[Key.domains] ?? .array([])
        guard let domains = value.nonEmptyStrings else {
            report("MANIFEST_TYPE", "\(Key.domains) must be an array of non-empty strings, found \(value.pythonRepr)")
            return []
        }
        if tracking && domains.isEmpty {
            report("TRACKING_DOMAINS", "\(Key.domains) lists no domain while \(Key.tracking) is true (TN3181)")
        }
        for domain in domains {
            if !tracking {
                report("TRACKING_DOMAINS", "\(Key.domains) lists \(domain.pythonRepr) while \(Key.tracking) is false (ITMS-91064)")
            } else if domain.wholeMatch(of: /[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+/) == nil {
                report("TRACKING_DOMAINS", "tracking domain \(domain.pythonRepr) must be a bare host name")
            }
        }
        return domains
    }

    private mutating func checkCollected(_ content: [String: PlistValue]) {
        guard let value = content[Key.collected] else {
            report("MANIFEST_MISSING_KEY", "missing key \(Key.collected.pythonRepr) (Xcode privacy report needs it, may be empty)")
            return
        }
        guard case .array(let items) = value else {
            report("MANIFEST_TYPE", "\(Key.collected) must be an array, found \(value.pythonRepr)")
            return
        }
        var seen: Set<String> = []
        for item in items {
            guard let entry = fields(of: item, keys: Key.dataEntry, code: "MANIFEST_DATA_ENTRY_KEYS", entry: "collected data entry"),
                  let type = entry[Key.dataType], let linked = entry[Key.dataLinked], let tracking = entry[Key.dataTracking],
                  let purposes = entry[Key.dataPurposes] else { continue }
            checkDataEntry(type: type, linked: linked, tracking: tracking, purposes: purposes, seen: &seen)
        }
    }

    private mutating func fields(of item: PlistValue, keys: Set<String>, code: String, entry: String) -> [String: PlistValue]? {
        if case .dictionary(let fields) = item, Set(fields.keys) == keys {
            return fields
        }
        let found = if case .dictionary(let fields) = item { PlistValue.list(fields.keys.pythonSorted()) } else { item }
        report(code, "\(entry) must have exactly \(PlistValue.list(keys.pythonSorted()).pythonRepr), found \(found.pythonRepr)")
        return nil
    }

    private mutating func checkDataEntry(type: PlistValue, linked: PlistValue, tracking: PlistValue, purposes: PlistValue, seen: inout Set<String>) {
        let label = type.pythonStr
        checkDataType(type, seen: &seen)
        for (key, value) in [(Key.dataLinked, linked), (Key.dataTracking, tracking)] where !value.isBool {
            report("MANIFEST_TYPE", "\(label): \(key) must be a Boolean, found \(value.pythonRepr)")
        }
        if case .bool(true) = tracking, trackingDisabled {
            report("TRACKING_ENABLED", "\(label): \(Key.dataTracking) is True; the SDK must declare false")
        }
        checkPurposes(purposes, label: label)
    }

    private mutating func checkDataType(_ type: PlistValue, seen: inout Set<String>) {
        guard let name = type.stringValue, isKnownDataType(name) else {
            report("MANIFEST_UNKNOWN_DATA_TYPE", "unknown collected data type \(type.pythonRepr)")
            return
        }
        if !seen.insert(name).inserted {
            report("MANIFEST_DUPLICATE_ENTRY", "collected data type \(type.pythonRepr) is listed twice")
        }
    }

    private mutating func checkPurposes(_ value: PlistValue, label: String) {
        guard let purposes = value.nonEmptyStrings, !purposes.isEmpty else {
            report("MANIFEST_TYPE", "\(label): \(Key.dataPurposes) must be a non-empty array of strings, found \(value.pythonRepr)")
            return
        }
        for purpose in purposes where !rules.purposes.contains(where: { $0.isLiterally(purpose) }) {
            report("MANIFEST_UNKNOWN_PURPOSE", "\(label): unknown purpose \(purpose.pythonRepr)")
        }
        if Set(purposes).count != purposes.count {
            report("MANIFEST_DUPLICATE_ENTRY", "\(label): a purpose is listed twice in \(value.pythonRepr)")
        }
    }

    private mutating func apiTypes(_ content: [String: PlistValue]) -> [String: [String]] {
        guard let value = content[Key.apiTypes] else { return [:] }
        guard case .array(let items) = value else {
            report("MANIFEST_TYPE", "\(Key.apiTypes) must be an array, found \(value.pythonRepr)")
            return [:]
        }
        guard !items.isEmpty else {
            report("MANIFEST_EMPTY_API_TYPES", "\(Key.apiTypes) is \(value.pythonRepr); remove the key instead (TN3181)")
            return [:]
        }
        var result: [String: [String]] = [:]
        for item in items {
            guard let entry = fields(of: item, keys: Key.apiEntry, code: "MANIFEST_API_ENTRY_KEYS", entry: "API entry"),
                  let type = entry[Key.apiType], let reasonsValue = entry[Key.apiReasons] else { continue }
            let reasons = reasons(reasonsValue, category: type)
            guard let category = type.stringValue, knownReasons(of: category) != nil else {
                report("MANIFEST_UNKNOWN_CATEGORY", "unknown required-reason category \(type.pythonRepr)")
                continue
            }
            guard result[category] == nil else {
                report("MANIFEST_DUPLICATE_ENTRY", "category \(type.pythonRepr) is listed twice")
                continue
            }
            result[category] = reasons
        }
        return result
    }

    private mutating func reasons(_ value: PlistValue, category: PlistValue) -> [String] {
        let label = category.pythonRepr
        guard let reasons = value.strings else {
            report("MANIFEST_TYPE", "\(label): \(Key.apiReasons) must be an array of strings, found \(value.pythonRepr)")
            return []
        }
        if reasons.isEmpty {
            report("MANIFEST_EMPTY_REASONS", "\(label): \(Key.apiReasons) is empty")
        }
        if Set(reasons).count != reasons.count {
            report("MANIFEST_DUPLICATE_ENTRY", "\(label): a reason is listed twice in \(value.pythonRepr)")
        }
        if let name = category.stringValue, let own = knownReasons(of: name) {
            for reason in reasons where own[reason] == nil {
                reportForeign(reason, category: label)
            }
        }
        return reasons
    }

    private mutating func reportForeign(_ reason: String, category label: String) {
        let owners = rules.categories.filter { $0.value[reason] != nil }.keys.pythonSorted()
        if owners.isEmpty {
            report("MANIFEST_UNKNOWN_REASON", "\(label): unknown reason \(reason.pythonRepr)")
        } else {
            report("MANIFEST_REASON_WRONG_CATEGORY", "reason \(reason.pythonRepr) belongs to \(owners.joined(separator: ", ")), not to \(label) (ITMS-91055)")
        }
    }

    private func knownReasons(of category: String) -> [String: String]? {
        rules.categories.first { $0.key.isLiterally(category) }?.value
    }

    private func isKnownDataType(_ name: String) -> Bool {
        rules.dataTypes.contains { $0.isLiterally(name) }
    }
}

private extension PlistValue {
    var stringValue: String? {
        guard case .string(let text) = self else { return nil }
        return text
    }

    var strings: [String]? {
        guard case .array(let items) = self else { return nil }
        let strings = items.compactMap(\.stringValue)
        return strings.count == items.count ? strings : nil
    }

    var nonEmptyStrings: [String]? {
        strings.flatMap { $0.contains(where: \.isEmpty) ? nil : $0 }
    }

    var isBool: Bool {
        guard case .bool = self else { return false }
        return true
    }
}

private extension String {
    func isLiterally(_ other: String) -> Bool {
        unicodeScalars.elementsEqual(other.unicodeScalars)
    }
}
