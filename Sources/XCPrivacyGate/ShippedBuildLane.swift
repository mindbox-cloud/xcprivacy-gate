import SwiftIfConfig
import SwiftSyntax

struct ShippedBuildLane: BuildConfiguration {
    static func all(definesDebugInRelease: Bool) -> [ShippedBuildLane] {
        operatingSystems.flatMap { names in
            [32, 64].map { ShippedBuildLane(operatingSystemNames: names, targetPointerBitWidth: $0, definesDebugInRelease: definesDebugInRelease) }
        }
    }

    private static let operatingSystems: [Set<String>] = [["iOS"], ["tvOS"], ["watchOS"], ["visionOS", "xrOS"]]
    private static let swiftVersion = VersionTuple(6, 3)
    private static let environments = ["simulator": false, "macCatalyst": false]
    private static let runtimes = ["_ObjC": true, "_multithreaded": true, "_Native": false]
    private static let objectFormats = ["MachO": true, "ELF": false, "COFF": false, "Wasm": false]

    private let operatingSystemNames: Set<String>
    let targetPointerBitWidth: Int
    private let definesDebugInRelease: Bool
    var languageVersion: VersionTuple { Self.swiftVersion }
    var compilerVersion: VersionTuple { Self.swiftVersion }
    var targetAtomicBitWidths: [Int] { [8, 16, 32, 64, 128] }
    var endianness: Endianness { .little }

    func isCustomConditionSet(name: String) throws -> Bool {
        guard name == "DEBUG", !definesDebugInRelease else {
            throw UndecidedCondition()
        }
        return false
    }

    func hasFeature(name: String) throws -> Bool {
        throw UndecidedCondition()
    }

    func hasAttribute(name: String) throws -> Bool {
        throw UndecidedCondition()
    }

    func canImport(importPath: [(TokenSyntax, String)], version: CanImportVersion) throws -> Bool {
        throw UndecidedCondition()
    }

    func isActiveTargetOS(name: String) -> Bool {
        operatingSystemNames.contains(name)
    }

    func isActiveTargetArchitecture(name: String) throws -> Bool {
        throw UndecidedCondition()
    }

    func isActiveTargetEnvironment(name: String) throws -> Bool {
        try Self.answer(name, from: Self.environments)
    }

    func isActiveTargetRuntime(name: String) throws -> Bool {
        try Self.answer(name, from: Self.runtimes)
    }

    func isActiveTargetPointerAuthentication(name: String) throws -> Bool {
        throw UndecidedCondition()
    }

    func isActiveTargetObjectFormat(name: String) throws -> Bool {
        try Self.answer(name, from: Self.objectFormats)
    }

    private static func answer(_ name: String, from known: [String: Bool]) throws -> Bool {
        guard let active = known[name] else {
            throw UndecidedCondition()
        }
        return active
    }
}

extension ShippedBuildLane {
    private static let versionCheckLimit = 8

    func reachedClauses(of node: IfConfigDeclSyntax) -> [IfConfigClauseSyntax] {
        var reached: [IfConfigClauseSyntax] = []
        for clause in node.clauses {
            guard let condition = clause.condition else {
                return reached + [clause]
            }
            guard let outcomes = outcomes(of: condition) else {
                return Array(node.clauses)
            }
            if outcomes.contains(true) {
                reached.append(clause)
            }
            if !outcomes.contains(false) {
                return reached
            }
        }
        return reached
    }

    private func outcomes(of condition: ExprSyntax) -> Set<Bool>? {
        let probe = VersionCheckReplacer(assignment: 0)
        let first = probe.visit(condition.detached)
        guard probe.replaced <= Self.versionCheckLimit else {
            return nil
        }
        let decided = [first] + (1..<(1 << probe.replaced)).map { VersionCheckReplacer(assignment: $0).visit(condition.detached) }
        var outcomes: Set<Bool> = []
        for condition in decided {
            let evaluation = IfConfigRegionState.evaluating(condition, in: self)
            guard evaluation.diagnostics.isEmpty else {
                return nil
            }
            outcomes.insert(evaluation.state == .active)
        }
        return outcomes
    }
}

private final class VersionCheckReplacer: SyntaxRewriter {
    private static let versionChecks: Set = ["swift", "compiler", "_compiler_version"]

    private let assignment: Int
    private(set) var replaced = 0

    init(assignment: Int) {
        self.assignment = assignment
        super.init(viewMode: .sourceAccurate)
    }

    override func visit(_ node: FunctionCallExprSyntax) -> ExprSyntax {
        guard let callee = node.calledExpression.as(DeclReferenceExprSyntax.self), Self.versionChecks.contains(callee.baseName.text) else {
            return super.visit(node)
        }
        defer { replaced += 1 }
        return ExprSyntax(BooleanLiteralExprSyntax(literal: .keyword((assignment >> replaced) & 1 == 1 ? .true : .false)))
    }
}

private struct UndecidedCondition: Error {}
