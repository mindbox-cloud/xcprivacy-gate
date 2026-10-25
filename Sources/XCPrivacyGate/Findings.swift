import Foundation

package struct Finding: Sendable {
    package let api: String
    package let categories: Set<String>
    package let file: String?
    package let line: Int?
    package let evidence: String

    package init(api: String, categories: Set<String>, file: String?, line: Int?, evidence: String) {
        self.api = api
        self.categories = categories
        self.file = file
        self.line = line
        self.evidence = evidence
    }
}

package struct ModuleFindings: Sendable {
    package let findings: [Finding]
    package let usesStandardDefaults: Bool
    package let privateSuites: Set<String>

    package init(findings: [Finding], usesStandardDefaults: Bool, privateSuites: Set<String>) {
        self.findings = findings
        self.usesStandardDefaults = usesStandardDefaults
        self.privateSuites = privateSuites
    }
}

extension ModuleFindings {
    static let empty = ModuleFindings(findings: [], usesStandardDefaults: false, privateSuites: [])

    func merging(_ other: ModuleFindings) -> ModuleFindings {
        ModuleFindings(
            findings: findings + other.findings,
            usesStandardDefaults: usesStandardDefaults || other.usesStandardDefaults,
            privateSuites: privateSuites.union(other.privateSuites)
        )
    }

    func onePerCallSite() -> ModuleFindings {
        var callSites: Set<CallSite> = []
        let unique = findings
            .sorted { ($0.api, $0.file ?? "", $0.line ?? 0, $0.evidence) < ($1.api, $1.file ?? "", $1.line ?? 0, $1.evidence) }
            .filter { callSites.insert(CallSite(api: $0.api, file: $0.file, line: $0.line)).inserted }
        return ModuleFindings(findings: unique, usesStandardDefaults: usesStandardDefaults, privateSuites: privateSuites)
    }
}

private struct CallSite: Hashable {
    let api: String
    let file: String?
    let line: Int?
}
