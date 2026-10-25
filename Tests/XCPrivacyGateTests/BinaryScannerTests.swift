import Foundation
import Testing
import XCPrivacyGate

private let userDefaults = "NSPrivacyAccessedAPICategoryUserDefaults"
private let diskSpace = "NSPrivacyAccessedAPICategoryDiskSpace"
private let bootTime = "NSPrivacyAccessedAPICategorySystemBootTime"
private let fileTimestamp = "NSPrivacyAccessedAPICategoryFileTimestamp"
private let localState = "com.example.sdk.localState"
private let getter = "Foundation.URLResourceValues.contentModificationDate.getter : Foundation.Date?"
private let mixedAPIs: Set = ["systemUptime", "systemFreeSize", "UserDefaults", "mach_absolute_time", "contentModificationDateKey"]

private func binaryRules() throws -> Rules {
    try Rules(RulesFile(
        categories: appleRules().categories.mapValues { CategoryReasons(reasons: $0) },
        apis: [
            ApiRule(api: "systemUptime", docc: nil, categories: [bootTime], selectors: ["systemUptime"]),
            ApiRule(api: "mach_absolute_time", docc: nil, categories: [bootTime], symbols: ["_mach_absolute_time"]),
            ApiRule(api: "systemFreeSize", docc: nil, categories: [diskSpace], strings: ["NSFileSystemFreeSize"], symbols: ["_NSFileSystemFreeSize"]),
            ApiRule(api: "UserDefaults", docc: nil, categories: [userDefaults], symbols: ["_OBJC_CLASS_$_NSUserDefaults"]),
            ApiRule(api: "contentModificationDateKey", docc: nil, categories: [fileTimestamp], swiftSymbols: [getter]),
            ApiRule(api: "stat", docc: nil, categories: [fileTimestamp], symbols: ["_stat"]),
            ApiRule(api: "fstat", docc: nil, categories: [fileTimestamp], symbols: ["_fstat"])
        ],
        collectedDataTypes: [],
        purposes: []
    ))
}

private struct Products {
    let directory: URL

    func compile(
        _ target: String,
        _ sources: [URL],
        triple: String = "arm64-apple-ios15.0-simulator",
        sdk: String = "iphonesimulator",
        library: Bool = false,
        options: [String] = []
    ) throws {
        let output = object(target).path
        _ = try Toolchain.run(
            ["xcrun", "--sdk", sdk, "swiftc", "-target", triple, "-parse-as-library", "-module-name", target] + options + sources.map(\.path)
                + (library ? ["-emit-library", "-o", output] : ["-c", "-o", output])
        )
    }

    func source(_ name: String, _ lines: String...) throws -> URL {
        let file = directory.appending(path: "sources/\(name)")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: file)
        return file
    }

    func object(_ target: String) -> URL {
        directory.appending(path: "\(target).o")
    }

    func findings(_ targets: [String], suites: [String] = []) throws -> [String: ModuleFindings] {
        try BinaryScanner.findings(
            build: SDKBuild(indexStore: directory.appending(path: "index"), products: directory),
            targets: targets.map { PackageTarget(name: $0, path: directory.appending(path: $0), sources: [], manifest: nil, definesDebugInRelease: false) },
            rules: binaryRules(),
            usage: Usage(entries: [], overrides: [], privateSuites: suites)
        )
    }

    func apis(_ target: String = "Fixture") throws -> Set<String> {
        Set(try findings([target])[target]?.findings.map(\.api) ?? [])
    }
}

private func withProducts<Result>(_ body: (Products) throws -> Result) throws -> Result {
    try withTemporaryDirectory { try body(Products(directory: $0)) }
}

@Suite("Binary scanner")
struct BinaryScannerTests {
    @Test("the APIs of the mixed fixture are found in every single-architecture artifact", arguments: ["arm64", "x86_64"], [false, true])
    func mixedAPIsAreFoundInEveryArtifact(architecture: String, library: Bool) throws {
        try withProducts { products in
            try products.compile("Fixture", [testData("binary/mixed.swift")], triple: "\(architecture)-apple-ios15.0-simulator", library: library)

            #expect(try products.apis() == mixedAPIs)
        }
    }

    @Test("a multi-architecture library is a tool error")
    func multiArchitectureLibraryIsToolError() throws {
        try withProducts { products in
            try products.compile("Arm", [testData("binary/mixed.swift")], triple: "arm64-apple-ios15.0-simulator", library: true)
            try products.compile("Intel", [testData("binary/mixed.swift")], triple: "x86_64-apple-ios15.0-simulator", library: true)
            _ = try Toolchain.run(["lipo", "-create", products.object("Arm").path, products.object("Intel").path, "-output", products.object("Fixture").path])

            let error = #expect(throws: ToolError.self) { try products.findings(["Fixture"]) }

            #expect(error?.message.contains(products.object("Fixture").path) == true)
        }
    }

    @Test("a finding names the symbol and the object, with the API's categories and no file")
    func findingNamesTheSymbol() throws {
        try withProducts { products in
            try products.compile("Fixture", [testData("binary/mixed.swift")], library: true)

            let findings = try #require(try products.findings(["Fixture"])["Fixture"]).findings
            let freeSize = try #require(findings.first { $0.api == "systemFreeSize" })

            #expect(freeSize.evidence == "_NSFileSystemFreeSize in Fixture.o")
            #expect(freeSize.categories == [diskSpace])
            #expect(freeSize.file == nil)
            #expect(freeSize.line == nil)
        }
    }

    @Test("fstat does not report stat")
    func fstatDoesNotReportStat() throws {
        try withProducts { products in
            let source = try products.source(
                "Size.swift",
                "import Darwin",
                "public func size() -> Int64 { var info = stat(); _ = fstat(0, &info); return info.st_size }"
            )
            try products.compile("Fixture", [source], library: true)

            #expect(try products.apis() == ["fstat"])
        }
    }

    @Test("a libc symbol with a $INODE64 suffix matches its rule")
    func suffixedLibcSymbolMatches() throws {
        try withProducts { products in
            let source = try products.source(
                "Size.swift",
                "import Darwin",
                #"public func size() -> Int64 { var info = stat(); _ = stat("/", &info); return info.st_size }"#
            )
            try products.compile("Fixture", [source], triple: "x86_64-apple-macos10.13", sdk: "macosx")

            #expect(try products.apis() == ["stat"])
        }
    }

    @Test("an own @objc member named like a selector is reported as a hit")
    func ownObjcMemberNamedLikeSelectorIsHit() throws {
        try withProducts { products in
            let source = try products.source(
                "Clock.swift",
                "import Foundation",
                "public final class Clock: NSObject {",
                "    @objc public var systemUptime: Double { 0 }",
                "}"
            )
            try products.compile("Fixture", [source], library: true)

            #expect(try products.apis() == ["systemUptime"])
        }
    }

    @Test("an object without undefined symbols has no findings")
    func objectWithoutUndefinedSymbolsHasNoFindings() throws {
        try withProducts { products in
            let source = try products.source("Answer.swift", "public let answer = 42")
            try products.compile("Fixture", [source], triple: "arm64-apple-ios18.0", sdk: "iphoneos", options: ["-O", "-wmo"])
            #expect(try Toolchain.run(["xcrun", "nm", "-u", products.object("Fixture").path]).isEmpty)

            let module = try #require(try products.findings(["Fixture"])["Fixture"])

            #expect(module.findings.isEmpty)
            #expect(!module.usesStandardDefaults)
            #expect(module.privateSuites.isEmpty)
        }
    }

    @Test("a file that is not Mach-O is a tool error")
    func notMachOIsToolError() throws {
        try withProducts { products in
            try Data("let a = 1\n".utf8).write(to: products.object("Fixture"))

            #expect(throws: ToolError.self) { try products.findings(["Fixture"]) }
        }
    }

    @Test("every target is keyed, and UserDefaults.standard and a listed private suite belong to the target that uses them")
    func findingsBelongToTheirTarget() throws {
        try withProducts { products in
            let store = try products.source(
                "Store.swift",
                "import Foundation",
                "public func store() {",
                #"    UserDefaults.standard.set(1, forKey: "a")"#,
                #"    UserDefaults(suiteName: "\#(localState)")?.set(1, forKey: "b")"#,
                "}"
            )
            let clock = try products.source("Clock.swift", "import Darwin", "public func now() -> UInt64 { mach_absolute_time() }")
            let answer = try products.source("Answer.swift", "public let answer = 42")
            try products.compile("Core", [store])
            try products.compile("Logger", [clock])
            try products.compile("Notifications", [answer])

            let modules = try products.findings(["Core", "Logger", "Notifications"], suites: [localState])

            #expect(modules.keys.sorted() == ["Core", "Logger", "Notifications"])
            let core = try #require(modules["Core"])
            #expect(core.findings.map(\.api) == ["UserDefaults"])
            #expect(core.usesStandardDefaults)
            #expect(core.privateSuites == [localState])
            let logger = try #require(modules["Logger"])
            #expect(logger.findings.map(\.evidence) == ["_mach_absolute_time in Logger.o"])
            #expect(!logger.usesStandardDefaults)
            #expect(logger.privateSuites.isEmpty)
            #expect(modules["Notifications"]?.findings.isEmpty == true)
        }
    }

    @Test("rule strings and private suites match __cstring entries only by exact equality")
    func cstringEntriesMatchExactly() throws {
        try withProducts { products in
            let exact = try products.source(
                "Exact.swift",
                "import Foundation",
                #"public func freeSize() -> FileAttributeKey { FileAttributeKey(rawValue: "NSFileSystemFreeSize") }"#,
                #"public func suite() -> UserDefaults? { UserDefaults(suiteName: "\#(localState)") }"#
            )
            let near = try products.source(
                "Near.swift",
                "import Foundation",
                #"public func freeSize() -> FileAttributeKey { FileAttributeKey(rawValue: "key NSFileSystemFreeSize") }"#,
                #"public func suite() -> UserDefaults? { UserDefaults(suiteName: "\#(localState).backup") }"#
            )
            try products.compile("Core", [exact])
            try products.compile("Logger", [near])

            let modules = try products.findings(["Core", "Logger"], suites: [localState])

            #expect(modules["Core"]?.findings.map(\.evidence) == ["_OBJC_CLASS_$_NSUserDefaults in Core.o", "NSFileSystemFreeSize in Core.o"])
            #expect(modules["Core"]?.privateSuites == [localState])
            #expect(modules["Logger"]?.findings.map(\.api) == ["UserDefaults"])
            #expect(modules["Logger"]?.privateSuites.isEmpty == true)
        }
    }

    @Test("more Swift symbols than one process can take as arguments are all demangled")
    func manySwiftSymbolsAreDemangled() throws {
        try withProducts { products in
            let count = 4_200
            let names = (0..<count).map { "f\($0)" }
            let source = try products.source(
                "Many.swift",
                names.map { #"@_silgen_name("$s4Many\#($0.count)\#($0)yyF") func \#($0)()"# }.joined(separator: "\n"),
                "public func callAll() {",
                names.map { "    \($0)()" }.joined(separator: "\n"),
                "}"
            )
            try products.compile("Fixture", [source])

            let evidence = try #require(try BinaryScanner.read([products.object("Fixture")])[products.object("Fixture")])

            #expect(evidence.demangled.count == count)
            #expect(evidence.demangled.contains("Many.f4199() -> ()"))
        }
    }
}
