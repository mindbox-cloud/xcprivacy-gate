import Foundation
import XCPrivacyGateRules

struct RefreshChange {
    let text: String
    let page: ApplePage
}

struct ConditionChange {
    let code: String
    let category: String
    let was: String
    let now: String
}

struct RulesComparison {
    private static let tn3181File = "apple/tn3181.txt"

    let changes: [RefreshChange]
    let conditions: [ConditionChange]
    private let rules: RulesFile?
    private let texts: [String: String]
    private let tn3181Diff: [String]

    init(saved: RulesFile, rulesDirectory: URL, pages: ApplePages) throws {
        var changes: [RefreshChange] = []
        var conditions: [ConditionChange] = []
        let rules = try RulesFile(
            categories: Self.categories(saved.categories, apple: pages.categories, changes: &changes, conditions: &conditions),
            apis: Self.apis(saved.apis, apple: pages.categories, changes: &changes),
            collectedDataTypes: Self.names(saved.collectedDataTypes, apple: pages.dataTypes, key: "collectedDataTypes", page: .dataTypes, changes: &changes),
            purposes: Self.names(saved.purposes, apple: pages.purposes, key: "purposes", page: .purposes, changes: &changes)
        )
        var texts: [String: String] = [:]
        let savedNote = try Self.savedText(rulesDirectory.appending(path: Self.tn3181File))
        if savedNote != pages.tn3181 {
            texts[Self.tn3181File] = pages.tn3181
            changes.append(RefreshChange(text: "TN3181 text changed; see the diff below", page: .tn3181))
        }
        let sdkFile = rulesDirectory.appending(path: SDKList.fileName)
        let savedSdks = FileManager.default.fileExists(atPath: sdkFile.path) ? try SDKList.read(sdkFile) : []
        if savedSdks != pages.sdks {
            texts[SDKList.fileName] = SDKList.text(pages.sdks)
            changes += pages.sdks.filter { !savedSdks.contains($0) }.map { RefreshChange(text: "Apple's SDK list adds `\($0)`", page: .sdkList) }
            changes += savedSdks.filter { !pages.sdks.contains($0) }.map { RefreshChange(text: "Apple's SDK list no longer names `\($0)`", page: .sdkList) }
        }
        self.changes = changes
        self.conditions = conditions
        self.rules = rules == saved ? nil : rules
        self.texts = texts
        tn3181Diff = Self.lineDiff(from: savedNote, to: pages.tn3181)
    }

    var pullRequestBody: String {
        var lines = [
            "Apple changed the pages xcprivacy-gate reads. Review each change; a new API needs a fixture and learned names before the self-test passes.",
            "",
            "### Changes",
            ""
        ]
        lines += changes.map { "- \($0.text) ([page](\($0.page.link)))" }
        if !tn3181Diff.isEmpty {
            lines += ["", "<details><summary>TN3181 diff</summary>", "", "```diff", "--- tn3181.txt (saved)", "+++ tn3181.txt (Apple)"]
            lines += tn3181Diff + ["```", "", "</details>"]
        }
        return lines.joined(separator: "\n") + "\n"
    }

    func write(to rulesDirectory: URL, rulesFileName: String) throws {
        if let rules {
            try JSONFormat.data(rules).write(to: rulesDirectory.appending(path: rulesFileName), options: .atomic)
        }
        for (path, text) in texts {
            try Data(text.utf8).write(to: rulesDirectory.appending(path: path), options: .atomic)
        }
    }

    private static func categories(
        _ saved: [String: CategoryReasons],
        apple: [(name: String, body: AppleDocs.RequiredReasonCategory)],
        changes: inout [RefreshChange],
        conditions: inout [ConditionChange]
    ) throws -> [String: CategoryReasons] {
        let lost = saved.keys.filter { name in !apple.contains { $0.name == name } }.pythonSorted()
        guard lost.isEmpty else {
            throw shrink("Apple's list lost categories \(lost)")
        }
        for (category, body) in apple {
            let old = saved[category]?.reasons ?? [:]
            if saved[category] == nil {
                changes.append(RefreshChange(text: "New category `\(category)`", page: .requiredReasons))
            }
            let lostReasons = old.keys.filter { body.reasons[$0] == nil }.pythonSorted()
            guard lostReasons.isEmpty else {
                throw shrink("\(category) lost reasons \(lostReasons)")
            }
            for (code, now) in body.reasons.sorted(by: { $0.key.pythonPrecedes($1.key) }) {
                guard let was = old[code] else {
                    changes.append(RefreshChange(text: "`\(category)`: new reason `\(code)`: \(now)", page: .requiredReasons))
                    continue
                }
                if was != now {
                    changes.append(RefreshChange(text: "`\(code)` (`\(category)`): was \"\(was)\" → now \"\(now)\"", page: .requiredReasons))
                    conditions.append(ConditionChange(code: code, category: category, was: was, now: now))
                }
            }
        }
        return Dictionary(apple.map { ($0.name, CategoryReasons(reasons: $0.body.reasons)) }) { first, _ in first }
    }

    private static func apis(
        _ saved: [ApiRule],
        apple categories: [(name: String, body: AppleDocs.RequiredReasonCategory)],
        changes: inout [RefreshChange]
    ) throws -> [ApiRule] {
        var listed: [(api: String, docc: String?, categories: [String])] = []
        var listedPosition: [String: Int] = [:]
        for (category, body) in categories {
            for entry in body.apis {
                if let position = listedPosition[entry.api] {
                    listed[position].categories.append(category)
                } else {
                    listedPosition[entry.api] = listed.count
                    listed.append((entry.api, entry.docc, [category]))
                }
            }
        }
        let lost = saved.map(\.api).filter { listedPosition[$0] == nil }.pythonSorted()
        guard lost.isEmpty else {
            throw shrink("Apple's list lost APIs \(lost)")
        }
        var apis = saved
        let savedPosition = Dictionary(saved.enumerated().map { ($1.api, $0) }) { first, _ in first }
        for apple in listed {
            guard let position = savedPosition[apple.api] else {
                apis.append(ApiRule(api: apple.api, docc: apple.docc, categories: apple.categories))
                let names = apple.categories.map { "`\($0)`" }.joined(separator: ", ")
                changes.append(RefreshChange(
                    text: "New API `\(apple.api)` in \(names); write its fixture, then run "
                        + "`xcprivacy-gate learn \(apple.api) --rules-directory \(RulesBundle.repositoryPath)`",
                    page: .requiredReasons
                ))
                continue
            }
            let rule = apis[position]
            let lostCategories = rule.categories.filter { !apple.categories.contains($0) }.pythonSorted()
            guard lostCategories.isEmpty else {
                throw shrink("\(apple.api) lost categories \(lostCategories)")
            }
            changes += apple.categories.filter { !rule.categories.contains($0) }.map {
                RefreshChange(text: "`\(apple.api)` is now also in `\($0)`", page: .requiredReasons)
            }
            if rule.docc != apple.docc {
                changes.append(RefreshChange(
                    text: "`\(apple.api)` documentation link: was `\(rule.docc ?? "none")` → now `\(apple.docc ?? "none")`",
                    page: .requiredReasons
                ))
            }
            apis[position].categories = apple.categories
            apis[position].docc = apple.docc
        }
        return apis
    }

    private static func names(_ saved: [String], apple: [String], key: String, page: ApplePage, changes: inout [RefreshChange]) throws -> [String] {
        let lost = saved.filter { !apple.contains($0) }.pythonSorted()
        guard lost.isEmpty else {
            throw shrink("Apple's \(key) lost \(lost)")
        }
        changes += apple.filter { !saved.contains($0) }.map { RefreshChange(text: "New \(key) value `\($0)`", page: page) }
        return apple
    }

    private static func shrink(_ problem: String) -> ToolError {
        ToolError(message: "\(problem); check the parser before trusting a shrink")
    }

    private static func savedText(_ file: URL) throws -> String {
        guard FileManager.default.fileExists(atPath: file.path) else {
            return ""
        }
        do {
            return try String(contentsOf: file, encoding: .utf8)
        } catch {
            throw ToolError(message: "\(file.path): cannot read the saved text: \(error.localizedDescription)")
        }
    }

    private static func lineDiff(from old: String, to new: String) -> [String] {
        let before = old.split(separator: "\n", omittingEmptySubsequences: false)
        let after = new.split(separator: "\n", omittingEmptySubsequences: false)
        var removed: Set<Int> = []
        var inserted: Set<Int> = []
        for change in after.difference(from: before) {
            switch change {
            case .remove(let offset, _, _):
                removed.insert(offset)
            case .insert(let offset, _, _):
                inserted.insert(offset)
            }
        }
        var lines: [String] = []
        var (oldLine, newLine) = (0, 0)
        while oldLine < before.count || newLine < after.count {
            if removed.contains(oldLine) {
                lines.append("-\(before[oldLine])")
                oldLine += 1
            } else if inserted.contains(newLine) {
                lines.append("+\(after[newLine])")
                newLine += 1
            } else {
                oldLine += 1
                newLine += 1
            }
        }
        return lines
    }
}
