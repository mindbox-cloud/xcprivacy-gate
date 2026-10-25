import Foundation
import IndexStoreDB

package struct IndexScanner {
    private static let standardDefaults: Set = [
        "c:objc(cs)NSUserDefaults(cpy)standardUserDefaults",
        "c:objc(cs)NSUserDefaults(cm)standardUserDefaults"
    ]

    private let store: URL
    private let library: IndexStoreLibrary

    package init(store: URL) throws {
        let path = try Toolchain.libIndexStore().path
        do {
            library = try IndexStoreLibrary(dylibPath: path)
        } catch {
            throw ToolError(message: "\(path) could not be loaded: \(error.localizedDescription)")
        }
        self.store = store
    }

    package func findings(targets: [PackageTarget], rules: Rules, root: URL) throws -> [String: ModuleFindings] {
        let database = FileManager.default.temporaryDirectory.appending(path: "xcprivacy-gate-index-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: database) }
        return try scan(targets: targets, rules: rules, root: URL(fileURLWithPath: Self.canonicalPath(of: root), isDirectory: true), database: database)
    }

    private func scan(targets: [PackageTarget], rules: Rules, root: URL, database: URL) throws -> [String: ModuleFindings] {
        let index = try open(database)
        let unindexed = targets.flatMap(\.sources).filter { index.dateOfLatestUnitFor(filePath: $0.path) == nil }
        guard unindexed.isEmpty else {
            let files = unindexed.map { Self.repositoryPath(of: $0, root: root) }.joined(separator: ", ")
            throw ToolError(message: "the build index has no data for \(files): the build did not compile them, so the source scan cannot read them")
        }
        let matchers = rules.apis.values.sorted { $0.api < $1.api }.map(UsrMatcher.init)
        var modules: [String: ModuleFindings] = [:]
        for target in targets {
            modules[target.name] = Self.findings(in: target, index: index, matchers: matchers, root: root)
        }
        return modules
    }

    private func open(_ database: URL) throws -> IndexStoreDB {
        let index: IndexStoreDB
        do {
            index = try IndexStoreDB(storePath: store.path, databasePath: database.path, library: library, waitUntilDoneInitializing: true)
        } catch {
            throw ToolError(message: "the build index at \(store.path) could not be opened: \(error.localizedDescription)")
        }
        index.pollForUnitChangesAndWait()
        return index
    }

    private static func findings(in target: PackageTarget, index: IndexStoreDB, matchers: [UsrMatcher], root: URL) -> ModuleFindings {
        var findings: [Finding] = []
        var usesStandardDefaults = false
        for source in target.sources {
            let file = repositoryPath(of: source, root: root)
            for occurrence in index.symbolOccurrences(inFilePath: source.path).sorted() where occurrence.roles.isDisjoint(with: [.definition, .declaration]) {
                let symbol = occurrence.symbol
                usesStandardDefaults = usesStandardDefaults || standardDefaults.contains(symbol.usr)
                findings += matchers.filter { $0.matches(symbol.usr) }.map { matcher in
                    Finding(api: matcher.rule.api, categories: Set(matcher.rule.categories), file: file, line: occurrence.location.line, evidence: symbol.name)
                }
            }
        }
        return ModuleFindings(findings: findings, usesStandardDefaults: usesStandardDefaults, privateSuites: [])
    }

    private static func repositoryPath(of source: URL, root: URL) -> String {
        Report.repositoryRelative(canonicalPath(of: source), root: root)
    }

    private static func canonicalPath(of url: URL) -> String {
        guard let resolved = realpath(url.path, nil) else {
            return url.path
        }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}

private struct UsrMatcher {
    let rule: ApiRule
    private let usrs: Set<String>

    init(_ rule: ApiRule) {
        self.rule = rule
        usrs = Set(rule.usrs)
    }

    func matches(_ usr: String) -> Bool {
        usrs.contains(usr) || rule.usrPrefixes.contains(where: usr.hasPrefix)
    }
}
