import Foundation

package struct Finding: Hashable, Sendable {
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
