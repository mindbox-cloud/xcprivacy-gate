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

private struct UndecidedCondition: Error {}
