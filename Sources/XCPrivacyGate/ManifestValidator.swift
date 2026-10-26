import Foundation

package struct Manifest: Sendable {
    package let path: URL
    package let apiTypes: [String: [String]]
    package let categoryLines: [String: Int]

    package init(path: URL, apiTypes: [String: [String]], categoryLines: [String: Int]) {
        self.path = path
        self.apiTypes = apiTypes
        self.categoryLines = categoryLines
    }
}

package enum ManifestValidator {
    package static let fileName = "PrivacyInfo.xcprivacy"

    package static func parse(_ url: URL, module: String, rules: Rules, trackingDisabled: Bool) -> (Manifest?, [Violation]) {
        var check = ManifestCheck(url: url, module: module, rules: rules, trackingDisabled: trackingDisabled)
        let manifest = check.run()
        return (manifest, check.violations)
    }

    static func isNamedLikeManifest(_ name: String) -> Bool {
        name.caseInsensitiveCompare(fileName) == .orderedSame
    }
}

enum ManifestKey {
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

private typealias Key = ManifestKey
private typealias PlistPath = [PlistPathComponent]

private struct EntryShape {
    static let api = EntryShape(keys: Key.apiEntry, code: "MANIFEST_API_ENTRY_KEYS", removal: "remove the entry if the SDK does not use that API (TN3181)")
    static let data = EntryShape(keys: Key.dataEntry, code: "MANIFEST_DATA_ENTRY_KEYS", removal: "remove the entry if the SDK does not collect that data")

    let keys: Set<String>
    let code: String
    let removal: String
}

private struct ManifestCheck {
    let url: URL
    let module: String
    let rules: Rules
    let trackingDisabled: Bool
    var lines: [PlistPath: Int] = [:]
    var violations: [Violation] = []

    mutating func run() -> Manifest? {
        if url.lastPathComponent != ManifestValidator.fileName {
            report("MANIFEST_FILE_NAME", "file is named \(url.lastPathComponent.quoted), Apple requires \(ManifestValidator.fileName.quoted)")
        }
        guard let content = read() else { return nil }
        checkDomains(content, tracking: tracking(content))
        checkCollected(content)
        let apiTypes = apiTypes(content)
        for key in content.keys.filter({ !Key.topLevel.contains($0) }).pythonSorted() {
            report("MANIFEST_UNKNOWN_KEY", "unknown top-level key \(key.quoted)", at: [.key(key)])
        }
        return Manifest(path: url, apiTypes: apiTypes.reasons, categoryLines: apiTypes.lines)
    }

    private mutating func report(_ code: String, _ message: String, at path: PlistPath = []) {
        report(code, message, line: lines[path])
    }

    private mutating func report(_ code: String, _ message: String, line: Int?) {
        violations.append(Violation(code: code, module: module, message: "\(module): \(message)", file: url.path, line: line))
    }

    private mutating func read() -> [String: PlistValue]? {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            report("MANIFEST_UNREADABLE", "cannot read the file: \(error.localizedDescription)")
            return nil
        }
        let document: PlistDocument
        do throws(PlistReadError) {
            document = try PlistReader.read(data)
        } catch {
            switch error {
            case .duplicateKey(let key, let line):
                report("MANIFEST_DUPLICATE_KEY", "key \(key.quoted) appears more than once", line: line)
            case .invalid(let message):
                report("MANIFEST_UNREADABLE", "not a valid property list: \(message)")
            }
            return nil
        }
        guard case .dictionary(let content) = document.root else {
            report("MANIFEST_UNREADABLE", "top level is of type \(document.root.plistTypeName), expected dictionary")
            return nil
        }
        lines = document.lines
        return content
    }

    private mutating func tracking(_ content: [String: PlistValue]) -> Bool {
        let path: PlistPath = [.key(Key.tracking)]
        guard let value = content[Key.tracking] else {
            if trackingDisabled {
                report("MANIFEST_MISSING_KEY", "missing key \(Key.tracking); the SDK must declare false")
            }
            return false
        }
        guard case .bool(let tracking) = value else {
            report("MANIFEST_TYPE", "\(Key.tracking) must be a Boolean, found \(value.literal)", at: path)
            return false
        }
        if tracking && trackingDisabled {
            report("TRACKING_ENABLED", "\(Key.tracking) is true; the SDK must declare false", at: path)
        }
        return tracking
    }

    private mutating func checkDomains(_ content: [String: PlistValue], tracking: Bool) {
        let path: PlistPath = [.key(content[Key.domains] == nil ? Key.tracking : Key.domains)]
        let value = content[Key.domains] ?? .array([])
        guard let domains = strings(value, key: Key.domains, label: nil, at: path) else { return }
        if tracking && domains.isEmpty {
            report("TRACKING_DOMAINS", "\(Key.domains) lists no domain while \(Key.tracking) is true (TN3181)", at: path)
        }
        for (index, domain) in domains.enumerated() {
            if !tracking {
                report("TRACKING_DOMAINS", "\(Key.domains) lists \(domain.quoted) while \(Key.tracking) is false (ITMS-91064)", at: path + [.index(index)])
            } else if domain.wholeMatch(of: /[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+/) == nil {
                report("TRACKING_DOMAINS", "tracking domain \(domain.quoted) must be a bare host name", at: path + [.index(index)])
            }
        }
    }

    private mutating func checkCollected(_ content: [String: PlistValue]) {
        guard let value = content[Key.collected] else { return }
        let path: PlistPath = [.key(Key.collected)]
        guard case .array(let items) = value else {
            report("MANIFEST_TYPE", "\(Key.collected) must be an array, found \(value.literal)", at: path)
            return
        }
        var seen: Set<String> = []
        for (index, item) in items.enumerated() {
            let entryPath = path + [.index(index)]
            let label = item.name(at: Key.dataType) ?? "collected data entry \(index + 1)"
            guard let entry = fields(of: item, shape: .data, label: label, at: entryPath),
                  let type = entry[Key.dataType], let linked = entry[Key.dataLinked], let tracking = entry[Key.dataTracking],
                  let purposes = entry[Key.dataPurposes] else { continue }
            checkDataType(type, label: label, seen: &seen, at: entryPath + [.key(Key.dataType)])
            for (key, value) in [(Key.dataLinked, linked), (Key.dataTracking, tracking)] where !value.isBool {
                report("MANIFEST_TYPE", "\(label): \(key) must be a Boolean, found \(value.literal)", at: entryPath + [.key(key)])
            }
            if case .bool(true) = tracking, trackingDisabled {
                report("TRACKING_ENABLED", "\(label): \(Key.dataTracking) is true; the SDK must declare false", at: entryPath + [.key(Key.dataTracking)])
            }
            checkPurposes(purposes, label: label, at: entryPath + [.key(Key.dataPurposes)])
        }
    }

    private mutating func fields(of item: PlistValue, shape: EntryShape, label: String, at path: PlistPath) -> [String: PlistValue]? {
        let expected = shape.keys.pythonSorted().joined(separator: ", ")
        guard case .dictionary(let fields) = item else {
            report(shape.code, "\(label) must be a dictionary with the keys \(expected), found \(item.literal)", at: path)
            return nil
        }
        guard Set(fields.keys) != shape.keys else {
            return fields
        }
        let missing = shape.keys.subtracting(fields.keys).pythonSorted().joined(separator: ", ")
        let extra = Set(fields.keys).subtracting(shape.keys).pythonSorted().joined(separator: ", ")
        let problem = switch (fields.isEmpty, missing.isEmpty, extra.isEmpty) {
        case (true, _, _): "has no keys. Fill it in, or \(shape.removal)"
        case (false, false, true): "lacks \(missing). Add \(missing), or \(shape.removal)"
        case (false, true, false): "also has \(extra). Remove \(extra)"
        default: "lacks \(missing) and also has \(extra). Add \(missing) and remove \(extra)"
        }
        report(shape.code, "\(label) must have exactly the keys \(expected), but it \(problem)", at: path)
        return nil
    }

    private mutating func checkDataType(_ type: PlistValue, label: String, seen: inout Set<String>, at path: PlistPath) {
        guard let name = type.stringValue, isKnownDataType(name) else {
            report("MANIFEST_UNKNOWN_DATA_TYPE", "\(label): unknown data type \(type.literal)", at: path)
            return
        }
        if !seen.insert(name).inserted {
            report("MANIFEST_DUPLICATE_ENTRY", "\(name) is listed in two collected data entries", at: path)
        }
    }

    private mutating func checkPurposes(_ value: PlistValue, label: String, at path: PlistPath) {
        guard let purposes = strings(value, key: Key.dataPurposes, label: label, at: path) else { return }
        guard !purposes.isEmpty else {
            report("MANIFEST_TYPE", "\(label): \(Key.dataPurposes) is empty; list the purposes Apple defines", at: path)
            return
        }
        for (index, purpose) in purposes.enumerated() where !rules.purposes.contains(where: { $0.isLiterally(purpose) }) {
            report("MANIFEST_UNKNOWN_PURPOSE", "\(label): unknown purpose \(purpose.quoted)", at: path + [.index(index)])
        }
        for purpose in purposes.repeated {
            report("MANIFEST_DUPLICATE_ENTRY", "\(label): \(Key.dataPurposes) lists \(purpose.quoted) twice", at: path)
        }
    }

    private mutating func strings(_ value: PlistValue, key: String, label: String?, at path: PlistPath) -> [String]? {
        let subject = label.map { "\($0): \(key)" } ?? key
        guard let strings = value.strings else {
            report("MANIFEST_TYPE", "\(subject) must be an array of strings, found \(value.literal)", at: path)
            return nil
        }
        guard !strings.contains(where: \.isEmpty) else {
            report("MANIFEST_TYPE", "\(subject) contains an empty string", at: path)
            return nil
        }
        return strings
    }

    private mutating func apiTypes(_ content: [String: PlistValue]) -> (reasons: [String: [String]], lines: [String: Int]) {
        guard let value = content[Key.apiTypes] else { return ([:], [:]) }
        let path: PlistPath = [.key(Key.apiTypes)]
        guard case .array(let items) = value else {
            report("MANIFEST_TYPE", "\(Key.apiTypes) must be an array, found \(value.literal)", at: path)
            return ([:], [:])
        }
        guard !items.isEmpty else {
            report("MANIFEST_EMPTY_API_TYPES", "\(Key.apiTypes) is empty; remove the key instead (TN3181)", at: path)
            return ([:], [:])
        }
        var result: [String: [String]] = [:]
        var categoryLines: [String: Int] = [:]
        for (index, item) in items.enumerated() {
            let entryPath = path + [.index(index)]
            let label = item.name(at: Key.apiType) ?? "API entry \(index + 1)"
            guard let entry = fields(of: item, shape: .api, label: label, at: entryPath),
                  let type = entry[Key.apiType], let reasonsValue = entry[Key.apiReasons] else { continue }
            let typePath = entryPath + [.key(Key.apiType)]
            let reasons = reasons(reasonsValue, category: type, label: label, at: entryPath + [.key(Key.apiReasons)])
            guard let category = type.stringValue, knownReasons(of: category) != nil else {
                let categories = rules.categories.keys.pythonSorted().joined(separator: ", ")
                report("MANIFEST_UNKNOWN_CATEGORY", "unknown required-reason category \(type.literal) (ITMS-91054); Apple's categories are \(categories)", at: typePath)
                continue
            }
            guard result[category] == nil else {
                report("MANIFEST_DUPLICATE_ENTRY", "\(category) is listed in two API entries", at: typePath)
                continue
            }
            result[category] = reasons
            categoryLines[category] = lines[typePath]
        }
        return (result, categoryLines)
    }

    private mutating func reasons(_ value: PlistValue, category: PlistValue, label: String, at path: PlistPath) -> [String] {
        guard let reasons = value.strings else {
            report("MANIFEST_TYPE", "\(label): \(Key.apiReasons) must be an array of strings, found \(value.literal)", at: path)
            return []
        }
        if reasons.isEmpty {
            report("MANIFEST_EMPTY_REASONS", "\(label): \(Key.apiReasons) is empty", at: path)
        }
        for reason in reasons.repeated {
            report("MANIFEST_DUPLICATE_ENTRY", "\(label): \(Key.apiReasons) lists \(reason.quoted) twice", at: path)
        }
        if let name = category.stringValue, let own = knownReasons(of: name) {
            for (index, reason) in reasons.enumerated() where own[reason] == nil {
                reportForeign(reason, label: label, at: path + [.index(index)])
            }
        }
        return reasons
    }

    private mutating func reportForeign(_ reason: String, label: String, at path: PlistPath) {
        let owners = rules.categories.filter { $0.value[reason] != nil }.keys.pythonSorted()
        if owners.isEmpty {
            report("MANIFEST_UNKNOWN_REASON", "\(label): unknown reason \(reason.quoted)", at: path)
        } else {
            report("MANIFEST_REASON_WRONG_CATEGORY", "\(label): reason \(reason.quoted) belongs to \(owners.joined(separator: ", ")), not to this category (ITMS-91055)", at: path)
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

    func name(at key: String) -> String? {
        guard case .dictionary(let fields) = self, let name = fields[key]?.stringValue, !name.isEmpty, name.isPlain else { return nil }
        return name
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

private extension Array where Element == String {
    var repeated: [String] {
        var seen: Set<String> = []
        return Set(filter { !seen.insert($0).inserted }).pythonSorted()
    }
}
