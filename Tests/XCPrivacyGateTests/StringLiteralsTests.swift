import Foundation
import Testing
import XCPrivacyGate
import XCPrivacyGateRules

private let diskSpace = "NSPrivacyAccessedAPICategoryDiskSpace"
private let localState = "com.example.sdk.localState"
private let loader = "Core/Storage/StorageLoader.swift"

private struct Literal: Equatable {
    let value: String
    let line: Int
}

private func literals(_ lines: String...) -> [Literal] {
    StringLiterals.swiftLiterals(in: lines.joined(separator: "\n"), definesDebugInRelease: false).map { Literal(value: $0.value, line: $0.line) }
}

private let ifBranch = Literal(value: "NSFileCreationDate", line: 2)
private let elseBranch = Literal(value: "NSFileSystemSize", line: 4)

private func branchLiterals(_ condition: String) -> [Literal] {
    literals("#if \(condition)", #"let a = "NSFileCreationDate""#, "#else", #"let b = "NSFileSystemSize""#, "#endif")
}

private func calls(_ module: ModuleFindings) -> [String] {
    module.findings.map { "\($0.api) \($0.file ?? "") \($0.line ?? 0)" }
}

@Suite("String literals")
struct StringLiteralsTests {
    private let rules: Rules
    private let usage = Usage(entries: [], overrides: [], privateSuites: [localState])

    init() throws {
        rules = try Rules.load(RulesBundle.directory.appending(path: "rules.json"))
    }

    @Test("a literal in code is found with its line")
    func literalInCodeIsFound() {
        #expect(literals(
            "import Foundation",
            "let keys = [",
            #"    "NSFileSystemFreeSize""#,
            "]"
        ) == [Literal(value: "NSFileSystemFreeSize", line: 3)])
    }

    @Test("literals in line and block comments are ignored")
    func commentsAreIgnored() {
        #expect(literals(
            #"let size = 1 // "NSFileSystemFreeSize""#,
            #"/// "NSUserDefaults""#,
            #"/* "NSFileSystemSize" */ let key = "NSURLCreationDateKey""#
        ) == [Literal(value: "NSURLCreationDateKey", line: 3)])
    }

    @Test("nested block comments are ignored")
    func nestedBlockCommentsAreIgnored() {
        #expect(literals(
            #"/* outer /* "NSFileSystemFreeSize" */ still outer "NSUserDefaults" */"#,
            #"let key = "NSFileSystemSize""#
        ) == [Literal(value: "NSFileSystemSize", line: 2)])
    }

    @Test("a URL with // inside a string does not start a comment")
    func urlDoesNotStartComment() {
        #expect(literals(#"let url = "https://example.com/path"; let key = "NSFileSystemFreeSize""#) == [
            Literal(value: "https://example.com/path", line: 1),
            Literal(value: "NSFileSystemFreeSize", line: 1)
        ])
    }

    @Test("multi-line string content is a literal")
    func multiLineStringIsLiteral() {
        #expect(literals(
            "let size = 1",
            #"let key = """"#,
            "    NSFileSystemFreeSize",
            #"    """"#
        ) == [Literal(value: "NSFileSystemFreeSize", line: 2)])
        #expect(literals(
            #"let text = """"#,
            #"    see "NSUserDefaults" // here"#,
            #"    """"#,
            #"let key = "NSFileSystemFreeSize""#
        ) == [
            Literal(value: #"see "NSUserDefaults" // here"#, line: 1),
            Literal(value: "NSFileSystemFreeSize", line: 4)
        ])
    }

    @Test("raw string #\"…\"# is a literal")
    func rawStringIsLiteral() {
        #expect(literals(
            ##"let key = #"NSFileSystemFreeSize"#"##,
            ##"let text = #"see "NSUserDefaults" \(name)"#"##
        ) == [
            Literal(value: "NSFileSystemFreeSize", line: 1),
            Literal(value: #"see "NSUserDefaults" \(name)"#, line: 2)
        ])
    }

    @Test("escaped quote stays inside the literal")
    func escapedQuoteStaysInside() {
        #expect(literals(#"let text = "say \"NSFileSystemFreeSize\" twice"; let key = "NSUserDefaults""#) == [
            Literal(value: #"say "NSFileSystemFreeSize" twice"#, line: 1),
            Literal(value: "NSUserDefaults", line: 1)
        ])
    }

    @Test("interpolated strings never equal a name")
    func interpolatedStringsAreSkipped() {
        #expect(literals(
            #"let key = "NS\(kind)FreeSize""#,
            #"let other = "\(prefix)NSUserDefaults""#,
            #"let plain = "NSFileSystemSize""#
        ) == [Literal(value: "NSFileSystemSize", line: 3)])
    }

    @Test("a literal inside an interpolation is a literal")
    func literalInsideInterpolationIsFound() {
        #expect(literals(
            "log(",
            #"    "free: \(attributes[FileAttributeKey(rawValue: "NSFileSystemFreeSize")] ?? 0)""#,
            ")"
        ) == [Literal(value: "NSFileSystemFreeSize", line: 2)])
    }

    @Test(
        "a clause no shipped build compiles is skipped and its #else counts",
        arguments: [
            "os(macOS)", "os(Linux)", "targetEnvironment(simulator)", "targetEnvironment(macCatalyst)", "DEBUG",
            "_runtime(_Native)", "objectFormat(ELF)", "objectFormat(COFF)", "objectFormat(Wasm)", "_endian(big)", "!_hasAtomicBitWidth(_128)"
        ]
    )
    func unshippedClauseIsSkipped(condition: String) {
        #expect(branchLiterals(condition) == [elseBranch])
    }

    @Test(
        "a clause every shipped build compiles drops its #else",
        arguments: ["_runtime(_ObjC)", "_runtime(_multithreaded)", "objectFormat(MachO)", "_endian(little)"]
    )
    func everyShippedBuildDropsElse(condition: String) {
        #expect(branchLiterals(condition) == [ifBranch])
    }

    @Test(
        "a condition that differs between shipped builds keeps both branches",
        arguments: [
            "os(iOS)", "os(tvOS)", "os(watchOS)", "os(visionOS)", "os(xrOS)",
            "swift(>=5.9)", "compiler(>=6.0)", "swift(<6) && compiler(>=6)", "_pointerBitWidth(_32)"
        ]
    )
    func laneDependentConditionKeepsBothBranches(condition: String) {
        #expect(branchLiterals(condition) == [ifBranch, elseBranch])
    }

    @Test(
        "a condition no shipped build can decide keeps every clause",
        arguments: [
            "SWIFT_PACKAGE", "canImport(UIKit)", "arch(arm64)", "os(macOS) || canImport(X)",
            "_ptrauth(arm64e)", "hasFeature(StrictConcurrency)", "hasAttribute(retroactive)",
            "_runtime(_Embedded)", "targetEnvironment(exclave)", "objectFormat(XCOFF)"
        ]
    )
    func undecidableConditionKeepsEveryClause(condition: String) {
        #expect(branchLiterals(condition) == [ifBranch, elseBranch])
    }

    @Test("an #elseif chain keeps the clauses some shipped build reaches")
    func elseIfChainKeepsReachedClauses() {
        #expect(literals(
            "#if os(tvOS)",
            #"let a = "NSFileCreationDate""#,
            "#elseif os(macOS)",
            #"let b = "NSFileSystemSize""#,
            "#elseif os(watchOS)",
            #"let c = "NSFileSystemFreeSize""#,
            "#else",
            #"let d = "NSUserDefaults""#,
            "#endif"
        ) == [
            Literal(value: "NSFileCreationDate", line: 2),
            Literal(value: "NSFileSystemFreeSize", line: 6),
            Literal(value: "NSUserDefaults", line: 8)
        ])
    }

    @Test("a nested #if os(iOS) inside #if os(macOS) is skipped, and so is os(macOS) inside os(iOS)")
    func nestedClausesAreSkipped() {
        #expect(literals(
            "#if os(macOS)",
            "#if os(iOS)",
            #"let a = "NSFileCreationDate""#,
            "#endif",
            "#endif",
            "#if os(iOS)",
            "#if os(macOS)",
            #"let b = "NSFileSystemSize""#,
            "#endif",
            #"let c = "NSUserDefaults""#,
            "#endif"
        ) == [Literal(value: "NSUserDefaults", line: 10)])
    }

    @Test("FileAttributeKey(rawValue: \"NSFileSystemFreeSize\") is systemFreeSize")
    func rawValueKeyIsSystemFreeSize() throws {
        let core = try scan([loader: ["import Foundation", "", #"let key = FileAttributeKey(rawValue: "NSFileSystemFreeSize")"#]], target: "Core")
        let finding = try #require(core.findings.first)

        #expect(core.findings.count == 1)
        #expect(finding.api == "systemFreeSize")
        #expect(finding.categories == [diskSpace])
        #expect(finding.file == loader)
        #expect(finding.line == 3)
        #expect(finding.evidence == "string literal")
    }

    @Test("a log text mentioning UserDefaults is not a finding")
    func logTextIsNotFinding() throws {
        let core = try scan([loader: [#"log("UserDefaults read failed: NSUserDefaults")"#, #"let type = NSClassFromString("NSUserDefaults")"#]], target: "Core")

        #expect(calls(core) == ["UserDefaults \(loader) 2"])
        #expect(core.usesStandardDefaults == false)
    }

    @Test("the private suite literal marks the module")
    func privateSuiteMarksModule() throws {
        let core = try scan([loader: [
            #"let defaults = UserDefaults(suiteName: "com.example.sdk.localState")"#,
            #"let other = UserDefaults(suiteName: "com.example.sdk.other")"#
        ]], target: "Core")

        #expect(core.privateSuites == [localState])
        #expect(core.findings.isEmpty)
        #expect(core.usesStandardDefaults == false)
    }

    @Test("every target gets an entry even when nothing is found in it")
    func everyTargetGetsEntry() throws {
        let modules = try scan([loader: [#"let key = "NSFileSystemFreeSize""#], "Logger/Log.swift": ["let level = 1"]])
        let logger = try #require(modules["Logger"])

        #expect(Set(modules.keys) == ["Core", "Logger"])
        #expect(calls(try #require(modules["Core"])) == ["systemFreeSize \(loader) 1"])
        #expect(logger.findings.isEmpty)
        #expect(logger.privateSuites.isEmpty)
    }

    @Test("#if DEBUG keeps both clauses in a target that defines DEBUG for release and drops the DEBUG clause otherwise")
    func releaseDebugKeepsDebugClause() throws {
        let source = ["#if DEBUG", #"let a = "NSFileCreationDate""#, "#else", #"let b = "NSFileSystemSize""#, "#endif"]

        let modules = try scan([loader: source, "Logger/Log.swift": source], debugInRelease: ["Core"])

        #expect(calls(try #require(modules["Core"])) == ["creationDate \(loader) 2", "systemSize \(loader) 4"])
        #expect(calls(try #require(modules["Logger"])) == ["systemSize Logger/Log.swift 4"])
    }

    @Test("an unreadable source is a tool error naming the file")
    func unreadableSourceIsToolError() throws {
        try withTemporaryDirectory { root in
            let missing = root.appending(path: "Core/Missing.swift")
            let target = PackageTarget(name: "Core", path: root.appending(path: "Core"), sources: [missing], manifest: nil, definesDebugInRelease: false)

            let error = #expect(throws: ToolError.self) { try StringLiterals.findings(targets: [target], rules: rules, usage: usage, root: root) }
            let message = try #require(error).message
            #expect(message.contains(missing.path))
        }
    }

    private func scan(_ files: [String: [String]], target name: String) throws -> ModuleFindings {
        try #require(scan(files)[name])
    }

    private func scan(_ files: [String: [String]], debugInRelease: Set<String> = []) throws -> [String: ModuleFindings] {
        try withTemporaryDirectory { root in
            var sources: [String: [URL]] = [:]
            for (path, lines) in files.sorted(by: { $0.key < $1.key }) {
                let file = root.appending(path: path)
                try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data(lines.joined(separator: "\n").utf8).write(to: file)
                sources[String(path.prefix { $0 != "/" }), default: []].append(file)
            }
            let targets = sources.map { PackageTarget(name: $0.key, path: root.appending(path: $0.key), sources: $0.value, manifest: nil, definesDebugInRelease: debugInRelease.contains($0.key)) }
            return try StringLiterals.findings(targets: targets, rules: rules, usage: usage, root: root)
        }
    }
}
