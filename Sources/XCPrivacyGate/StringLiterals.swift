import Foundation
import SwiftIfConfig
import SwiftParser
import SwiftSyntax

package enum StringLiterals {
    package static func findings(targets: [PackageTarget], rules: Rules, usage: Usage, root: URL) throws -> [String: ModuleFindings] {
        var apisByString: [String: [ApiRule]] = [:]
        for rule in rules.apis.values.sorted(by: { $0.api < $1.api }) {
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
                for literal in try swiftLiterals(in: contents(of: source), definesDebugInRelease: target.definesDebugInRelease) {
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

    private static func contents(of source: URL) throws -> String {
        do {
            return try String(contentsOf: source, encoding: .utf8)
        } catch {
            throw ToolError(message: "\(source.path) could not be read: \(error.localizedDescription)")
        }
    }
}

private final class LiteralCollector: SyntaxVisitor {
    private let converter: SourceLocationConverter
    private let lanes: [ShippedBuildLane]
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
        let outcomes = lanes.map { node.activeClause(in: $0) }
        guard outcomes.allSatisfy({ $0.diagnostics.isEmpty }) else {
            return .visitChildren
        }
        let shipped = Set(outcomes.compactMap(\.clause))
        for clause in node.clauses where shipped.contains(clause) {
            if let elements = clause.elements {
                walk(elements)
            }
        }
        return .skipChildren
    }
}
