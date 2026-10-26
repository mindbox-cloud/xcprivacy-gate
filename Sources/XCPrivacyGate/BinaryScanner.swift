import Foundation

package struct BinaryEvidence: Sendable {
    package var symbols: Set<String> = []
    package var demangled: Set<String> = []
    package var selectors: Set<String> = []
    package var strings: Set<String> = []
}

package enum BinaryScanner {
    private static let standardSelector = "standardUserDefaults"

    package static func findings(build: SDKBuild, targets: [PackageTarget], rules: Rules, usage: Usage) throws -> [String: ModuleFindings] {
        let evidence = try read(targets.map { build.object(of: $0.name) })
        let suites = Set(usage.privateSuites)
        let apis = rules.sortedApis
        var modules: [String: ModuleFindings] = [:]
        for target in targets {
            let object = build.object(of: target.name)
            let found = evidence[object, default: BinaryEvidence()]
            modules[target.name] = ModuleFindings(
                findings: apis.compactMap { found.finding(for: $0, in: object.lastPathComponent) },
                usesStandardDefaults: found.selectors.contains(standardSelector),
                privateSuites: suites.intersection(found.strings)
            )
        }
        return modules
    }

    package static func read(_ files: [URL]) throws -> [URL: BinaryEvidence] {
        let tools = try BinaryTools()
        var evidence: [URL: BinaryEvidence] = [:]
        for file in files {
            evidence[file] = try tools.evidence(of: file)
        }
        let mangled = Set(evidence.values.flatMap { $0.symbols.filter { $0.hasPrefix("_$s") } })
        let names = try tools.demangle(mangled.sorted())
        return evidence.mapValues { found in
            var found = found
            found.demangled = Set(found.symbols.compactMap { names[$0] })
            return found
        }
    }
}

private extension BinaryEvidence {
    func finding(for rule: ApiRule, in object: String) -> Finding? {
        let matched = symbols.intersection(rule.symbols)
            .union(selectors.intersection(rule.selectors))
            .union(demangled.intersection(rule.swiftSymbols))
        guard !matched.isEmpty else {
            return nil
        }
        return Finding(api: rule.api, categories: Set(rule.categories), file: nil, line: nil, evidence: "\(matched.pythonSorted().joined(separator: ", ")) in \(object)")
    }
}

private struct BinaryTools {
    private static let selectorStub = "_objc_msgSend$"
    private static let extensionSuffix = "$DARWIN_EXTSN"
    private static let demangleChunk = 1_000

    private let nm: String
    private let otool: String
    private let demangler: String

    init() throws {
        nm = try Toolchain.find("nm")
        otool = try Toolchain.find("otool")
        demangler = try Toolchain.find("swift-demangle")
    }

    func evidence(of file: URL) throws -> BinaryEvidence {
        var evidence = BinaryEvidence()
        for name in try undefinedSymbols(of: file) {
            if name.hasPrefix(Self.selectorStub) {
                evidence.selectors.insert(String(name.dropFirst(Self.selectorStub.count)))
            } else {
                evidence.symbols.insert(String(name.hasSuffix(Self.extensionSuffix) ? name.dropLast(Self.extensionSuffix.count) : name))
            }
        }
        evidence.selectors.formUnion(try section("__objc_methname", of: file))
        evidence.strings = try section("__cstring", of: file)
        return evidence
    }

    func demangle(_ names: [String]) throws -> [String: String] {
        var demangled: [String: String] = [:]
        for start in stride(from: 0, to: names.count, by: Self.demangleChunk) {
            let chunk = Array(names[start..<min(start + Self.demangleChunk, names.count)])
            let lines = try Toolchain.run([demangler, "--compact"] + chunk).split(separator: "\n")
            guard lines.count == chunk.count else {
                throw ToolError(message: "swift-demangle printed \(lines.count) lines for \(chunk.count) symbols")
            }
            for (name, line) in zip(chunk, lines) {
                demangled[name] = String(line)
            }
        }
        return demangled
    }

    private func undefinedSymbols(of file: URL) throws -> [Substring] {
        let output = try Toolchain.run([nm, "-u", "-j", "--arch=all", file.path])
        guard !output.hasPrefix("\n"), !output.contains("\n\n") else {
            throw ToolError(message: "\(file.path) holds several architectures; the binary scan reads only the single-architecture objects of its own build")
        }
        return output.split(separator: "\n")
    }

    private func section(_ name: String, of file: URL) throws -> Set<String> {
        Set(try Toolchain.run([otool, "-arch", "all", "-X", "-v", "-s", "__TEXT", name, file.path]).split(separator: "\n").map(String.init))
    }
}
