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
        let matchers = rules.apis.values.sorted { $0.api < $1.api }.map(UsrMatcher.init)
        return try read(targets.flatMap(\.sources), root: root) { index, root in
            var modules: [String: ModuleFindings] = [:]
            for target in targets {
                modules[target.name] = Self.findings(in: target, index: index, matchers: matchers, root: root)
            }
            return modules
        }
    }

    package func usrs(in sources: [URL], root: URL) throws -> [URL: Set<String>] {
        try read(sources, root: root) { index, _ in
            var usrs: [URL: Set<String>] = [:]
            for source in sources {
                usrs[source] = Set(Self.references(in: source, index: index).map(\.symbol.usr))
            }
            return usrs
        }
    }

    private func read<Result>(_ sources: [URL], root: URL, _ body: (IndexStoreDB, URL) -> Result) throws -> Result {
        try WorkDirectory.with { work in
            try scan(sources, root: URL(fileURLWithPath: root.canonicalPath, isDirectory: true), database: work.appending(path: "database"), body)
        }
    }

    private func scan<Result>(_ sources: [URL], root: URL, database: URL, _ body: (IndexStoreDB, URL) -> Result) throws -> Result {
        let index = try open(database)
        let unindexed = sources.filter { index.dateOfLatestUnitFor(filePath: $0.path) == nil }
        guard unindexed.isEmpty else {
            let files = unindexed.map { Self.repositoryPath(of: $0, root: root) }.joined(separator: ", ")
            throw ToolError(message: "the build index has no data for \(files): the build did not compile them, so the source scan cannot read them")
        }
        return body(index, root)
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
            for occurrence in references(in: source, index: index) {
                let symbol = occurrence.symbol
                usesStandardDefaults = usesStandardDefaults || standardDefaults.contains(symbol.usr)
                findings += matchers.filter { $0.matches(symbol.usr) }.map { matcher in
                    Finding(api: matcher.rule.api, categories: Set(matcher.rule.categories), file: file, line: occurrence.location.line, evidence: symbol.name)
                }
            }
        }
        return ModuleFindings(findings: findings, usesStandardDefaults: usesStandardDefaults, privateSuites: [])
    }

    private static func references(in source: URL, index: IndexStoreDB) -> [SymbolOccurrence] {
        index.symbolOccurrences(inFilePath: source.path).sorted().filter { $0.roles.isDisjoint(with: [.definition, .declaration]) }
    }

    private static func repositoryPath(of source: URL, root: URL) -> String {
        Report.repositoryRelative(source.canonicalPath, root: root)
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
