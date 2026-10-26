import Foundation
import XCPrivacyGateRules

package struct FixtureBuild: Sendable {
    let root: URL
    let index: URL
    let fixtures: [BuiltFixture]
    let platforms: [PlatformBuild]
}

struct BuiltFixture: Sendable {
    let file: String
    let target: PackageTarget
}

struct PlatformBuild: Sendable {
    let triple: String
    let objects: SDKBuild
    let library: SDKBuild
}

private struct Expectation {
    let file: String
    let target: String
    let apis: Set<String>
}

package enum SelfTest {
    private static let negativeDirectory = "fixtures/negative"
    private static let noUsage = Usage(entries: [], overrides: [], privateSuites: [])

    package static func run(rules: Rules, rulesDirectory: URL) throws -> [Violation] {
        let files = try fixtureFiles(rules: rules, rulesDirectory: rulesDirectory)
        return try WorkDirectory.with { work in
            try incomplete(rules: rules, rulesDirectory: rulesDirectory) + compare(rules: rules, build: build(files, rulesDirectory: rulesDirectory, work: work))
        }
    }

    package static func fixtureFiles(rules: Rules, rulesDirectory: URL) throws -> [String] {
        let fixtures = Set(rules.apis.values.flatMap(\.fixtures).filter { isSwiftFixture($0, in: rulesDirectory) })
        let negatives = try FileManager.default.contentsOfDirectory(atPath: rulesDirectory.appending(path: negativeDirectory).path)
            .filter { $0.hasSuffix(".swift") }
            .map { "\(negativeDirectory)/\($0)" }
        return fixtures.pythonSorted() + negatives.pythonSorted()
    }

    package static func incomplete(rules: Rules, rulesDirectory: URL) -> [Violation] {
        rules.sortedApis.compactMap { rule in
            var missing: [String] = []
            if rule.usrs.isEmpty {
                missing.append("usrs")
            }
            if rule.symbols.isEmpty, rule.selectors.isEmpty, rule.swiftSymbols.isEmpty {
                missing.append("binary names")
            }
            if rule.fixtures.isEmpty {
                missing.append("a Swift fixture")
            }
            missing += rule.fixtures.filter { !isSwiftFixture($0, in: rulesDirectory) }.map { "the Swift fixture \($0)" }
            guard !missing.isEmpty else {
                return nil
            }
            return Violation(
                code: "RULE_INCOMPLETE",
                module: nil,
                message: "\(rule.api): rules.json lacks \(missing.joined(separator: ", ")); write the fixture, "
                    + "then run `xcprivacy-gate learn \(rule.api) --rules-directory \(RulesBundle.repositoryPath)`"
            )
        }
    }

    package static func build(_ files: [String], rulesDirectory: URL, work: URL) throws -> FixtureBuild {
        let root = work.appending(path: "sources", directoryHint: .isDirectory)
        let sources = try files.map { file in
            let copy = root.appending(path: file)
            try WorkDirectory.copy(rulesDirectory.appending(path: file), to: copy)
            return copy
        }
        let index = work.appending(path: "index", directoryHint: .isDirectory)
        let compiler = try FixtureCompiler()
        let platforms = try compiler.compile(sources, into: work, index: index).map { batch in
            let library = work.appending(path: "\(batch.platform.triple)/library", directoryHint: .isDirectory)
            try compiler.link(batch.objects, for: batch.platform, into: library.appending(path: "\(FixtureCompiler.module).o"))
            return PlatformBuild(
                triple: batch.platform.triple,
                objects: SDKBuild(indexStore: index, products: batch.directory),
                library: SDKBuild(indexStore: index, products: library)
            )
        }
        let fixtures = zip(files, sources).map { file, source in
            BuiltFixture(file: file, target: pseudoTarget(source.deletingPathExtension().lastPathComponent, sources: [source]))
        }
        return FixtureBuild(root: root, index: index, fixtures: fixtures, platforms: platforms)
    }

    package static func compare(rules: Rules, build: FixtureBuild) throws -> [Violation] {
        var listed: [String: Set<String>] = [:]
        for rule in rules.apis.values {
            for fixture in rule.fixtures {
                listed[fixture, default: []].insert(rule.api)
            }
        }
        let expectations = build.fixtures.compactMap { fixture -> Expectation? in
            let apis = listed[fixture.file] ?? (fixture.file.hasPrefix("\(negativeDirectory)/") ? [] : nil)
            return apis.map { Expectation(file: "\(RulesBundle.repositoryPath)/\(fixture.file)", target: fixture.target.name, apis: $0) }
        }
        let targets = build.fixtures.map(\.target)
        let index = try IndexScanner(store: build.index).findings(targets: targets, rules: rules, root: build.root)
        let strings = try StringLiterals.findings(targets: targets, rules: rules, usage: noUsage, root: build.root)
        var violations = compare(lane: "source", found: index.merging(strings) { $0.merging($1) }, expectations: expectations)
        for platform in build.platforms {
            let objects = try BinaryScanner.findings(build: platform.objects, targets: targets, rules: rules, usage: noUsage)
            violations += compare(lane: "binary \(platform.triple) object", found: objects, expectations: expectations)
            let library = pseudoTarget(FixtureCompiler.module, sources: [])
            let linked = try BinaryScanner.findings(build: platform.library, targets: [library], rules: rules, usage: noUsage)
            violations += missed(in: apis(linked[library.name]), triple: platform.triple, expectations: expectations)
        }
        return violations
    }

    static func isSwiftFixture(_ fixture: String, in rulesDirectory: URL) -> Bool {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: rulesDirectory.appending(path: fixture).path, isDirectory: &isDirectory)
        return exists && !isDirectory.boolValue && fixture.hasSuffix(".swift")
    }

    private static func compare(lane: String, found: [String: ModuleFindings], expectations: [Expectation]) -> [Violation] {
        var violations: [Violation] = []
        for expectation in expectations {
            let reported = apis(found[expectation.target])
            guard !expectation.apis.isEmpty else {
                if !reported.isEmpty {
                    let names = reported.pythonSorted().joined(separator: ", ")
                    violations.append(violation("NEGATIVE_HIT", "\(expectation.file): the \(lane) scan reports \(names) in a negative fixture", expectation))
                }
                continue
            }
            for api in expectation.apis.subtracting(reported).pythonSorted() {
                violations.append(violation("FIXTURE_MISSED", "\(api): the \(lane) scan finds nothing in \(expectation.file)", expectation))
            }
            let owners = expectation.apis.pythonSorted().joined(separator: ", ")
            for other in reported.subtracting(expectation.apis).pythonSorted() {
                violations.append(violation("FIXTURE_CROSSTALK", "\(expectation.file): the \(lane) scan also reports \(other) in the \(owners) fixture", expectation))
            }
        }
        return violations
    }

    private static func missed(in linked: Set<String>, triple: String, expectations: [Expectation]) -> [Violation] {
        expectations.flatMap { expectation in
            expectation.apis.subtracting(linked).pythonSorted().map { api in
                violation("FIXTURE_MISSED", "\(api): the binary scan finds nothing in the \(triple) library linked from \(expectation.file)", expectation)
            }
        }
    }

    private static func apis(_ module: ModuleFindings?) -> Set<String> {
        Set(module?.findings.map(\.api) ?? [])
    }

    private static func violation(_ code: String, _ message: String, _ expectation: Expectation) -> Violation {
        Violation(code: code, module: nil, message: message, file: expectation.file)
    }

    private static func pseudoTarget(_ name: String, sources: [URL]) -> PackageTarget {
        PackageTarget(name: name, sources: sources, manifest: nil, definesDebugInRelease: false)
    }
}
