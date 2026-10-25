import SwiftIfConfig
import SwiftSyntax

struct ShippedBuildLane: BuildConfiguration {
    static let all: [ShippedBuildLane] = operatingSystems.flatMap { names in
        versionExtremes.flatMap { language in
            versionExtremes.flatMap { compiler in
                [32, 64].map { ShippedBuildLane(operatingSystemNames: names, languageVersion: language, compilerVersion: compiler, targetPointerBitWidth: $0) }
            }
        }
    }

    private static let operatingSystems: [Set<String>] = [["iOS"], ["tvOS"], ["watchOS"], ["visionOS", "xrOS"]]
    private static let versionExtremes = [VersionTuple(0), VersionTuple(Int.max)]

    private let operatingSystemNames: Set<String>
    let languageVersion: VersionTuple
    let compilerVersion: VersionTuple
    let targetPointerBitWidth: Int
    var targetAtomicBitWidths: [Int] { [8, 16, 32, 64, 128] }
    var endianness: Endianness { .little }

    func isCustomConditionSet(name: String) throws -> Bool {
        guard name == "DEBUG" else {
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

    func isActiveTargetEnvironment(name: String) -> Bool {
        false
    }

    func isActiveTargetRuntime(name: String) -> Bool {
        name == "_ObjC"
    }

    func isActiveTargetPointerAuthentication(name: String) throws -> Bool {
        throw UndecidedCondition()
    }

    func isActiveTargetObjectFormat(name: String) -> Bool {
        name == "MachO"
    }
}

private struct UndecidedCondition: Error {}
