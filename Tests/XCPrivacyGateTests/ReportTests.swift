import Foundation
import Testing
import XCPrivacyGate

@Suite("Report formatting")
struct ReportTests {
    private let root = URL(fileURLWithPath: "/work/repo", isDirectory: true)

    @Test("annotation escapes data and properties")
    func annotationEscapesDataAndProperties() {
        let violation = Violation(
            code: "MISSING_CATEGORY",
            module: "Lib",
            message: "50% done,\nnext line",
            file: "/work/repo/Lib/a,b.swift",
            line: 7
        )

        #expect(
            Report.annotation(violation, root: root)
                == "::error file=Lib/a%2Cb.swift,line=7,title=MISSING_CATEGORY::50%25 done,%0Anext line"
        )
    }

    @Test("annotation escapes carriage returns everywhere and colons only in properties")
    func annotationEscapesCarriageReturnsAndColons() {
        let violation = Violation(
            code: "UNREGISTERED_CALL",
            module: "Lib",
            message: "first: a\r\nsecond",
            file: "/work/repo/Lib/x:y.swift"
        )

        #expect(
            Report.annotation(violation, root: root)
                == "::error file=Lib/x%3Ay.swift,title=UNREGISTERED_CALL::first: a%0D%0Asecond"
        )
    }

    @Test("annotation without a file has only a title")
    func annotationWithoutFile() {
        let violation = Violation(code: "RULE_INCOMPLETE", module: nil, message: "stat: lacks")

        #expect(Report.annotation(violation, root: root) == "::error title=RULE_INCOMPLETE::stat: lacks")
    }

    @Test("annotation omits the line when it is not set")
    func annotationWithoutLine() {
        let violation = Violation(code: "MISSING_CATEGORY", module: "Lib", message: "m", file: "/work/repo/Lib/a.swift")

        #expect(Report.annotation(violation, root: root) == "::error file=Lib/a.swift,title=MISSING_CATEGORY::m")
    }

    @Test("annotation keeps paths outside the root as given")
    func annotationKeepsForeignPaths() {
        let paths = ["Lib/a.swift", "/elsewhere/a.swift", "/work/repo-other/a.swift"]

        for path in paths {
            let violation = Violation(code: "MISSING_CATEGORY", module: "Lib", message: "m", file: path, line: 1)

            #expect(Report.annotation(violation, root: root) == "::error file=\(path),line=1,title=MISSING_CATEGORY::m")
        }
    }

    @Test("summary names the title, counts violations and lists each one")
    func summaryListsViolations() {
        let violations = [
            Violation(code: "MISSING_CATEGORY", module: "Lib", message: "Lib: lacks Boot"),
            Violation(code: "EXTRA_CATEGORY", module: "Lib", message: "Lib: declares Disk")
        ]

        #expect(
            Report.summary(title: "check", violations: violations)
                == "Privacy manifest gate, check: 2 violations\nMISSING_CATEGORY Lib: lacks Boot\nEXTRA_CATEGORY Lib: declares Disk"
        )
    }

    @Test("summary uses the singular for one violation and the plural for none")
    func summaryPluralisation() {
        let one = [Violation(code: "MISSING_CATEGORY", module: "Lib", message: "m")]

        #expect(Report.summary(title: "check", violations: one).hasPrefix("Privacy manifest gate, check: 1 violation\n"))
        #expect(Report.summary(title: "check", violations: []) == "Privacy manifest gate, check: 0 violations")
    }

    @Test("exit code is 1 with violations and 0 without")
    func exitCodes() {
        let violation = Violation(code: "MISSING_CATEGORY", module: "Lib", message: "m")

        #expect(Report.exitCode(violations: [violation]) == 1)
        #expect(Report.exitCode(violations: []) == 0)
    }

    @Test("tool error describes itself with its message")
    func toolErrorDescription() {
        #expect(String(describing: ToolError(message: "swiftlint exited with 1")) == "swiftlint exited with 1")
    }
}
