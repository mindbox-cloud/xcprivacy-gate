import SwiftIfConfig
import SwiftSyntax

struct ShippedBuildLane: BuildConfiguration {
    static func all(definesDebugInRelease: Bool) -> [ShippedBuildLane] {
        operatingSystems.flatMap { names in
            versionExtremes.flatMap { language in
                versionExtremes.flatMap { compiler in
                    [32, 64].map {
                        ShippedBuildLane(
                            operatingSystemNames: names,
                            languageVersion: language,
                            compilerVersion: compiler,
                            targetPointerBitWidth: $0,
                            definesDebugInRelease: definesDebugInRelease
                        )
                    }
                }
            }
        }
    }

    private static let operatingSystems: [Set<String>] = [["iOS"], ["tvOS"], ["watchOS"], ["visionOS", "xrOS"]]
    private static let versionExtremes = [VersionTuple(0), VersionTuple(Int.max)]
    private static let environments = ["simulator": false, "macCatalyst": false]
    private static let runtimes = ["_ObjC": true, "_multithreaded": true, "_Native": false]
    private static let objectFormats = ["MachO": true, "ELF": false, "COFF": false, "Wasm": false]

    private let operatingSystemNames: Set<String>
    let languageVersion: VersionTuple
    let compilerVersion: VersionTuple
    let targetPointerBitWidth: Int
    private let definesDebugInRelease: Bool
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

private struct UndecidedCondition: Error {}
