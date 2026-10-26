import Foundation
import SwiftIfConfig
import SwiftParser
import SwiftSyntax

package enum StringLiterals {
    package static func findings(targets: [PackageTarget], rules: Rules, usage: Usage, root: URL) throws -> [String: ModuleFindings] {
        var apisByString: [String: [ApiRule]] = [:]
        for rule in rules.sortedApis {
            for string in rule.strings {
                apisByString[string, default: []].append(rule)
            }
        }
        let suites = Set(usage.privateSuites)
        var modules: [String: ModuleFindings] = [:]
        for target in targets {
            var findings: [Finding] = []
            var privateSuites: Set<String> = []
            for source in target.sources {
                let file = Report.repositoryPath(of: source, root: root)
                for literal in try swiftLiterals(in: source.text(), definesDebugInRelease: target.definesDebugInRelease) {
                    findings += apisByString[literal.value, default: []].map { rule in
                        Finding(api: rule.api, categories: Set(rule.categories), file: file, line: literal.line, evidence: "string literal")
                    }
                    if suites.contains(literal.value) {
                        privateSuites.insert(literal.value)
                    }
                }
            }
            modules[target.name] = ModuleFindings(findings: findings, usesStandardDefaults: false, privateSuites: privateSuites)
        }
        return modules
    }

    package static func swiftLiterals(in source: String, definesDebugInRelease: Bool) -> [(value: String, line: Int)] {
        let tree = Parser.parse(source: source)
        let collector = LiteralCollector(
            converter: SourceLocationConverter(fileName: "", tree: tree),
            lanes: ShippedBuildLane.all(definesDebugInRelease: definesDebugInRelease)
        )
        collector.walk(tree)
        return collector.literals
    }
}

private final class LiteralCollector: SyntaxVisitor {
    private let converter: SourceLocationConverter
    private var lanes: [ShippedBuildLane]
    private(set) var literals: [(value: String, line: Int)] = []

    init(converter: SourceLocationConverter, lanes: [ShippedBuildLane]) {
        self.converter = converter
        self.lanes = lanes
        super.init(viewMode: .sourceAccurate)
    }

    override func visit(_ node: StringLiteralExprSyntax) -> SyntaxVisitorContinueKind {
        if let value = node.representedLiteralValue {
            literals.append((value: value, line: node.startLocation(converter: converter).line))
        }
        return .visitChildren
    }

    override func visit(_ node: IfConfigDeclSyntax) -> SyntaxVisitorContinueKind {
        let reaching = lanes
        let checksVersion = VersionCheckFinder.checksVersion(node)
        var lanesByClause: [IfConfigClauseSyntax: [ShippedBuildLane]] = [:]
        for lane in reaching {
            for clause in Self.clauses(of: node, reachedBy: lane, keepingEvery: checksVersion) {
                lanesByClause[clause, default: []].append(lane)
            }
        }
        for clause in node.clauses {
            guard let clauseLanes = lanesByClause[clause], let elements = clause.elements else { continue }
            lanes = clauseLanes
            walk(elements)
        }
        lanes = reaching
        return .skipChildren
    }

    private static func clauses(of node: IfConfigDeclSyntax, reachedBy lane: ShippedBuildLane, keepingEvery: Bool) -> [IfConfigClauseSyntax] {
        guard !keepingEvery else { return Array(node.clauses) }
        let outcome = node.activeClause(in: lane)
        guard outcome.diagnostics.isEmpty else { return Array(node.clauses) }
        return outcome.clause.map { [$0] } ?? []
    }
}

private final class VersionCheckFinder: SyntaxVisitor {
    private static let versionChecks: Set = ["swift", "compiler", "_compiler_version"]

    private var found = false

    static func checksVersion(_ node: IfConfigDeclSyntax) -> Bool {
        let finder = VersionCheckFinder(viewMode: .sourceAccurate)
        for condition in node.clauses.compactMap(\.condition) {
            finder.walk(condition)
        }
        return finder.found
    }

    override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
        if let callee = node.calledExpression.as(DeclReferenceExprSyntax.self), Self.versionChecks.contains(callee.baseName.text) {
            found = true
        }
        return .visitChildren
    }
}
