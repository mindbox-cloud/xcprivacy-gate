import Foundation

package struct LearnedNames: Sendable {
    package var usrs: [String]
    package var symbols: [String]
    package var selectors: [String]
    package var swiftSymbols: [String]

    private static let excludedUsrPrefixes = ["c:@S@", "c:@T@", "c:@M@"]
    private static let objectiveCPrefix = "c:objc("

    package func selected(for api: String) -> LearnedNames {
        let key = api.lowercased()
        let named = { (names: [String]) in names.filter { $0.lowercased().contains(key) } }
        return LearnedNames(
            usrs: named(usrs).filter { usr in
                usr.hasPrefix("c:") && !Self.excludedUsrPrefixes.contains(where: usr.hasPrefix) && !Self.namesObjectiveCType(usr)
            },
            symbols: named(symbols),
            selectors: named(selectors),
            swiftSymbols: named(swiftSymbols)
        )
    }

    private static func namesObjectiveCType(_ usr: String) -> Bool {
        usr.hasPrefix(objectiveCPrefix) && !usr.dropFirst(objectiveCPrefix.count).contains("(")
    }
}

private struct CompiledSource {
    let usrs: Set<String>
    let artifacts: [BinaryEvidence]

    func present(_ field: KeyPath<BinaryEvidence, Set<String>>) -> Set<String> {
        artifacts.dropFirst().reduce(artifacts.first?[keyPath: field] ?? []) { $0.intersection($1[keyPath: field]) }
    }

    func any(_ field: KeyPath<BinaryEvidence, Set<String>>) -> Set<String> {
        artifacts.reduce(into: []) { $0.formUnion($1[keyPath: field]) }
    }

    func names(without baseline: CompiledSource) -> LearnedNames {
        LearnedNames(
            usrs: usrs.subtracting(baseline.usrs).pythonSorted(),
            symbols: present(\.symbols).subtracting(baseline.any(\.symbols)).pythonSorted(),
            selectors: present(\.selectors).subtracting(baseline.any(\.selectors)).pythonSorted(),
            swiftSymbols: present(\.demangled).subtracting(baseline.any(\.demangled)).pythonSorted()
        )
    }
}

package enum Learn {
    private static let baselineName = "learnBaseline"

    package static func learn(fixtures: [URL]) throws -> [URL: LearnedNames] {
        try WorkDirectory.with { work in
            let sources = work.appending(path: "sources", directoryHint: .isDirectory)
            let copies = try fixtures.enumerated().map { position, fixture in
                let copy = sources.appending(path: "\(position)/\(fixture.lastPathComponent)")
                try WorkDirectory.copy(fixture, to: copy)
                return copy
            }
            let baseline = sources.appending(path: "\(baselineName).swift")
            try Data("public func \(baselineName)() {}\n".utf8).write(to: baseline)
            let compiled = try compile(copies + [baseline], work: work)
            let noise = compiled[copies.count]
            return Dictionary(zip(fixtures, compiled.map { $0.names(without: noise) })) { first, _ in first }
        }
    }

    package static func update(rulesFile: URL, api: String?) throws {
        var file = try RulesFile.load(rulesFile).file
        if let api, !file.apis.contains(where: { $0.api == api }) {
            throw ToolError(message: "\(api): not in \(rulesFile.path)")
        }
        let directory = rulesFile.deletingLastPathComponent()
        let chosen = file.apis.indices.filter { api == nil || file.apis[$0].api == api }
        let fixtures = try chosen.map { try swiftFixtures(of: file.apis[$0], in: directory) }
        let learned = try learn(fixtures: Set(fixtures.joined()).sorted { $0.path < $1.path })
        for (position, urls) in zip(chosen, fixtures) {
            let rule = file.apis[position]
            let names = urls.compactMap { learned[$0]?.selected(for: rule.api) }
            file.apis[position].usrs = Set(names.flatMap(\.usrs)).pythonSorted()
            file.apis[position].symbols = Set(names.flatMap(\.symbols)).pythonSorted()
            file.apis[position].selectors = Set(names.flatMap(\.selectors)).pythonSorted()
            file.apis[position].swiftSymbols = Set(names.flatMap(\.swiftSymbols)).pythonSorted()
            try requireNames(file.apis[position])
        }
        try JSONFormat.data(file).write(to: rulesFile, options: .atomic)
    }

    private static func compile(_ sources: [URL], work: URL) throws -> [CompiledSource] {
        let index = work.appending(path: "index", directoryHint: .isDirectory)
        let compiler = try FixtureCompiler()
        var artifacts = Array(repeating: [URL](), count: sources.count)
        for batch in try compiler.compile(sources, into: work, index: index) {
            for (position, object) in batch.objects.enumerated() {
                let library = object.deletingPathExtension().appendingPathExtension("dylib")
                try compiler.link([object], for: batch.platform, into: library)
                artifacts[position] += [object, library]
            }
        }
        let evidence = try BinaryScanner.read(artifacts.flatMap { $0 })
        let usrs = try IndexScanner(store: index).usrs(in: sources, root: work)
        return zip(sources, artifacts).map { source, files in
            CompiledSource(usrs: usrs[source, default: []], artifacts: files.map { evidence[$0, default: BinaryEvidence()] })
        }
    }

    private static func swiftFixtures(of rule: ApiRule, in directory: URL) throws -> [URL] {
        guard !rule.fixtures.isEmpty else {
            throw ToolError(message: "\(rule.api): rules.json lists no fixture")
        }
        return try rule.fixtures.map { fixture in
            guard SelfTest.isSwiftFixture(fixture, in: directory) else {
                throw ToolError(message: "\(rule.api): fixture \(fixture.quoted) is not a Swift file in \(directory.path)")
            }
            return directory.appending(path: fixture)
        }
    }

    private static func requireNames(_ rule: ApiRule) throws {
        guard !rule.usrs.isEmpty else {
            throw ToolError(message: "\(rule.api): no learned USR names \(rule.api.quoted); check its fixtures")
        }
        guard !(rule.symbols.isEmpty && rule.selectors.isEmpty && rule.swiftSymbols.isEmpty) else {
            throw ToolError(message: "\(rule.api): no learned binary name contains \(rule.api.quoted); check its fixtures")
        }
    }
}
