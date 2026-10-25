import Foundation

enum UserDefaultsPolicy {
    static let category = "NSPrivacyAccessedAPICategoryUserDefaults"
    static let appGroupReason = "1C8F.1"
    static let standardReason = "CA92.1"
}

package struct Policy: Sendable {
    let usage: Usage
    let rules: Rules
    let userDefaultsAppGroup: Bool
    let today: Date

    package init(usage: Usage, rules: Rules, userDefaultsAppGroup: Bool, today: Date) {
        self.usage = usage
        self.rules = rules
        self.userDefaultsAppGroup = userDefaultsAppGroup
        self.today = today
    }

    package func evaluate(
        targets: [PackageTarget],
        source: [String: ModuleFindings],
        binary: [String: ModuleFindings],
        manifests: [String: Manifest]
    ) -> [Violation] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        let startOfToday = calendar.startOfDay(for: today)
        let modules = Set(targets.map(\.name))
        var violations = entryViolations(modules: modules) + overrideViolations(modules: modules, startOfToday: startOfToday)
        let liveOverrides = usage.overrides.filter { $0.expires >= startOfToday }
        for target in targets {
            let use = ModuleUse(source: source[target.name], binary: binary[target.name])
            guard target.manifest != nil else {
                if !use.findings.isEmpty {
                    violations.append(Violation(
                        code: "TARGET_WITHOUT_MANIFEST_USES_API",
                        module: target.name,
                        message: "\(target.name): the target has no \(ManifestValidator.fileName) but uses required-reason APIs: "
                            + "\(calls(use.findings)). Add a manifest and list it in the target's resources in Package.swift"
                    ))
                }
                continue
            }
            if let manifest = manifests[target.name] {
                var check = ModuleCheck(name: target.name, use: use, manifest: manifest, policy: self, overrides: liveOverrides.filter { $0.module == target.name })
                violations += check.run()
            }
        }
        return violations.sorted {
            ($0.module ?? "", $0.code, $0.file ?? "", $0.line ?? 0, $0.message) < ($1.module ?? "", $1.code, $1.file ?? "", $1.line ?? 0, $1.message)
        }
    }

    func category(of entry: UsageEntry) -> String? {
        (rules.apis[entry.api]?.categories ?? []).pythonSorted().first { rules.categories[$0]?[entry.reason] != nil }
    }

    private func entryViolations(modules: Set<String>) -> [Violation] {
        usage.entries.flatMap { entry in
            let place = "usage.json call \(entry.module) \(entry.file) \(entry.api)"
            var violations: [Violation] = []
            if !modules.contains(entry.module) {
                violations.append(Violation(code: "REGISTRY_UNKNOWN_MODULE", module: entry.module, message: "\(place): \(entry.module) is not a target in Package.swift"))
            }
            if category(of: entry) == nil {
                let categories = (rules.apis[entry.api]?.categories ?? []).pythonSorted().joined(separator: ", ")
                violations.append(Violation(code: "REGISTRY_UNKNOWN_REASON", module: entry.module, message: "\(place): \(entry.reason) is not an Apple reason of \(categories)"))
            }
            return violations
        }
    }

    private func overrideViolations(modules: Set<String>, startOfToday: Date) -> [Violation] {
        usage.overrides.flatMap { override in
            let place = "usage.json override \(override.module) \(override.category)"
            var violations: [Violation] = []
            if !modules.contains(override.module) {
                violations.append(Violation(code: "REGISTRY_UNKNOWN_MODULE", module: override.module, message: "\(place): \(override.module) is not a target in Package.swift"))
            }
            let unknown = override.reasons.filter { rules.categories[override.category]?[$0] == nil }
            if !unknown.isEmpty {
                violations.append(Violation(
                    code: "REGISTRY_UNKNOWN_REASON",
                    module: override.module,
                    message: "\(place): \(unknown.joined(separator: ", ")) are not Apple reasons of \(override.category)"
                ))
            }
            if override.expires < startOfToday {
                violations.append(Violation(
                    code: "OVERRIDE_EXPIRED",
                    module: override.module,
                    message: "\(place): expired on \(override.expires.formatted(Override.dayFormat)); re-check the evidence (\(override.evidence)) "
                        + "and extend or remove the override"
                ))
            }
            return violations
        }
    }
}

private struct ModuleUse {
    let source: [Finding]
    let binaryOnly: [Finding]
    let usesStandardDefaults: Bool
    let privateSuites: Set<String>

    init(source: ModuleFindings?, binary: ModuleFindings?) {
        let sourceFindings = source?.findings ?? []
        let sourceAPIs = Set(sourceFindings.map(\.api))
        self.source = sourceFindings
        binaryOnly = (binary?.findings ?? []).filter { !sourceAPIs.contains($0.api) }
        usesStandardDefaults = source?.usesStandardDefaults == true || binary?.usesStandardDefaults == true
        privateSuites = (source?.privateSuites ?? []).union(binary?.privateSuites ?? [])
    }

    var findings: [Finding] {
        source + binaryOnly
    }
}

private struct CallKey: Hashable {
    let api: String
    let category: String
}

private struct ModuleCheck {
    let name: String
    let use: ModuleUse
    let manifest: Manifest
    let policy: Policy
    let overrides: [Override]
    let used: [String: [Finding]]
    let sourceUsed: [String: [Finding]]
    let entries: [(entry: UsageEntry, category: String)]
    let standardOrPrivate: Bool
    var reasons: [String: Set<String>] = [:]
    var unresolved: Set<String> = []

    init(name: String, use: ModuleUse, manifest: Manifest, policy: Policy, overrides: [Override]) {
        self.name = name
        self.use = use
        self.manifest = manifest
        self.policy = policy
        self.overrides = overrides
        used = Self.byCategory(use.findings)
        sourceUsed = Self.byCategory(use.source)
        entries = policy.usage.entries.filter { $0.module == name }.compactMap { entry in policy.category(of: entry).map { (entry: entry, category: $0) } }
        standardOrPrivate = use.usesStandardDefaults || !use.privateSuites.isDisjoint(with: policy.usage.privateSuites)
    }

    mutating func run() -> [Violation] {
        var violations = callViolations() + binaryOnlyViolations()
        for override in overrides {
            reasons[override.category, default: []].formUnion(override.reasons.filter { policy.rules.categories[override.category]?[$0] != nil })
        }
        let overridden = Set(overrides.map(\.category))
        let declared = manifest.apiTypes
        for category in Set(used.keys).union(declared.keys) {
            guard let declaredReasons = declared[category] else {
                violations.append(missing(category))
                continue
            }
            if used[category] == nil && !overridden.contains(category) {
                violations.append(violation(
                    "EXTRA_CATEGORY",
                    "\(name): the manifest declares \(category), but no code in the module uses it. Remove the entry, or add an override with evidence to usage.json if Apple requires it"
                ))
            } else if isPolicyGoverned(category) {
                violations += userDefaultsViolations(declared: Set(declaredReasons))
            } else if !unresolved.contains(category) && Set(declaredReasons) != reasons[category, default: []] {
                violations.append(violation(
                    "REASONS_MISMATCH",
                    "\(name): the manifest declares \(category) reasons \(codes(declaredReasons)), but usage.json explains \(codes(reasons[category, default: []])). Make them equal"
                ))
            }
        }
        return violations
    }

    private static func byCategory(_ findings: [Finding]) -> [String: [Finding]] {
        var result: [String: [Finding]] = [:]
        for finding in findings {
            for category in finding.categories {
                result[category, default: []].append(finding)
            }
        }
        return result
    }

    private func isPolicyGoverned(_ category: String) -> Bool {
        policy.userDefaultsAppGroup && category == UserDefaultsPolicy.category
    }

    private mutating func callViolations() -> [Violation] {
        var unregistered: [CallKey: [Finding]] = [:]
        for (category, findings) in sourceUsed where !isPolicyGoverned(category) {
            for finding in findings {
                let matched = entries.filter { $0.category == category && $0.entry.api == finding.api && $0.entry.file == finding.file }
                reasons[category, default: []].formUnion(matched.map(\.entry.reason))
                if matched.isEmpty {
                    unregistered[CallKey(api: finding.api, category: category), default: []].append(finding)
                    unresolved.insert(category)
                }
            }
        }
        var stale: [CallKey: [UsageEntry]] = [:]
        for (entry, category) in entries where !isExplained(entry, category: category) {
            stale[CallKey(api: entry.api, category: category), default: []].append(entry)
        }
        return Set(unregistered.keys).union(stale.keys).flatMap { key in
            callViolations(key, unregistered: unregistered[key] ?? [], stale: stale[key] ?? [])
        }
    }

    private func isExplained(_ entry: UsageEntry, category: String) -> Bool {
        sourceUsed[category, default: []].contains { $0.api == entry.api && $0.file == entry.file }
            || use.binaryOnly.contains { $0.api == entry.api && $0.categories.contains(category) }
    }

    private func callViolations(_ key: CallKey, unregistered: [Finding], stale: [UsageEntry]) -> [Violation] {
        let api = key.api
        let category = key.category
        if let moved = unregistered.first, !stale.isEmpty {
            let old = Set(stale.map(\.file)).pythonSorted().joined(separator: ", ")
            let new = Set(unregistered.map { $0.location ?? $0.evidence }).pythonSorted().joined(separator: ", ")
            return [violation(
                "LIKELY_MOVE",
                "\(name): usage.json registers \(api) (\(category)) in \(old), but the call is now at \(new). Update the file in usage.json",
                at: moved
            )]
        }
        let calls = unregistered.map { finding in
            violation(
                "UNREGISTERED_CALL",
                "\(name): \(finding.location ?? finding.evidence) calls \(api) (\(category)), and usage.json has no entry for it in this file. "
                    + "Add an entry with module, file, api, purpose and one of Apple's reasons: \(reasonTexts(category))",
                at: finding
            )
        }
        let entries = stale.map { entry in
            Violation(
                code: "STALE_ENTRY",
                module: name,
                message: "\(name): usage.json registers \(api) (\(entry.reason)) in \(entry.file), but no such call exists there. Remove the entry",
                file: entry.file
            )
        }
        return calls + entries
    }

    private mutating func binaryOnlyViolations() -> [Violation] {
        var violations: [Violation] = []
        for (api, findings) in Dictionary(grouping: use.binaryOnly, by: \.api) {
            let categories = Set(findings.flatMap(\.categories)).filter { !isPolicyGoverned($0) }
            let explaining = entries.filter { $0.entry.api == api && categories.contains($0.category) }
            for (entry, category) in explaining {
                reasons[category, default: []].insert(entry.reason)
            }
            guard !categories.isEmpty, explaining.isEmpty, !overrides.contains(where: { categories.contains($0.category) }) else { continue }
            unresolved.formUnion(categories)
            let evidence = Set(findings.map(\.evidence)).pythonSorted().joined(separator: "; ")
            violations.append(violation(
                "BINARY_ONLY_API",
                "\(name): the compiled module uses \(api) (\(evidence)), but no source file in the module calls it. Add a usage.json entry "
                    + "with the file that reaches it, or an override with evidence for \(categories.pythonSorted().joined(separator: ", "))"
            ))
        }
        return violations
    }

    private func missing(_ category: String) -> Violation {
        let needed = isPolicyGoverned(category) ? userDefaultsRequired : reasons[category, default: []]
        let advice = needed.isEmpty
            ? "Register its calls in usage.json, then declare it with the registered reasons"
            : "Declare it with reasons \(codes(needed))"
        return violation(
            "MISSING_CATEGORY",
            "\(name): the code uses \(category) (\(calls(used[category, default: []]))), but the manifest does not declare it. \(advice)"
        )
    }

    private var userDefaultsRequired: Set<String> {
        standardOrPrivate ? [UserDefaultsPolicy.appGroupReason, UserDefaultsPolicy.standardReason] : [UserDefaultsPolicy.appGroupReason]
    }

    private func userDefaultsViolations(declared: Set<String>) -> [Violation] {
        let appGroup = UserDefaultsPolicy.appGroupReason
        let standard = UserDefaultsPolicy.standardReason
        let category = UserDefaultsPolicy.category
        var violations: [Violation] = []
        if !declared.contains(appGroup) {
            violations.append(violation(
                "UD_APP_GROUP_REQUIRED",
                "\(name): the module uses UserDefaults, and the userDefaultsAppGroup policy requires \(appGroup) because the SDK keeps its data "
                    + "in an App Group suite. Add \(appGroup) to \(category)"
            ))
        }
        if standardOrPrivate && !declared.contains(standard) {
            violations.append(violation(
                "UD_STANDARD_REQUIRED",
                "\(name): the module uses UserDefaults.standard or a private suite listed in usage.json. Add \(standard) to \(category)"
            ))
        }
        if !standardOrPrivate && declared.contains(standard) {
            violations.append(violation(
                "UD_CA92_UNUSED",
                "\(name): the manifest declares \(standard), but the module uses neither UserDefaults.standard nor a private suite listed in usage.json. Remove \(standard)"
            ))
        }
        let others = declared.subtracting([appGroup, standard])
        if !others.isEmpty {
            violations.append(violation(
                "REASONS_MISMATCH",
                "\(name): the manifest declares \(category) reasons \(codes(others)); the userDefaultsAppGroup policy allows only \(appGroup) "
                    + "(App Group suite) and \(standard) (standard or private suite)"
            ))
        }
        return violations
    }

    private func reasonTexts(_ category: String) -> String {
        (policy.rules.categories[category] ?? [:]).sorted { $0.key.pythonPrecedes($1.key) }.map { "\($0.key): \($0.value)" }.joined(separator: "; ")
    }

    private func violation(_ code: String, _ message: String, at finding: Finding? = nil) -> Violation {
        if let finding, let file = finding.file {
            return Violation(code: code, module: name, message: message, file: file, line: finding.line)
        }
        return Violation(code: code, module: name, message: message, file: manifest.path.path)
    }
}

private extension Finding {
    var location: String? {
        guard let file, let line else { return nil }
        return "\(file):\(line)"
    }

    var summary: String {
        location.map { "\(api) at \($0)" } ?? "\(api): \(evidence)"
    }
}

private func calls(_ findings: [Finding]) -> String {
    Set(findings.map(\.summary)).pythonSorted().joined(separator: ", ")
}

private func codes(_ values: some Sequence<String>) -> String {
    let sorted = values.pythonSorted()
    return sorted.isEmpty ? "none" : sorted.joined(separator: ", ")
}
