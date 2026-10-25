import Foundation

struct FixturePlatform: Sendable {
    let triple: String
    let sdk: String
    let sdkPath: String

    var isDevice: Bool {
        sdk == "iphoneos"
    }
}

struct CompiledBatch {
    let platform: FixturePlatform
    let directory: URL
    let objects: [URL]
}

struct FixtureCompiler {
    static let module = "Fixtures"
    private static let targets = [
        (triple: "arm64-apple-ios15.0", sdk: "iphoneos"),
        (triple: "arm64-apple-ios15.0-simulator", sdk: "iphonesimulator"),
        (triple: "x86_64-apple-ios15.0-simulator", sdk: "iphonesimulator")
    ]

    private let swiftc: String
    private let platforms: [FixturePlatform]

    init() throws {
        swiftc = try Self.output(of: ["xcrun", "--find", "swiftc"])
        var sdkPaths: [String: String] = [:]
        platforms = try Self.targets.map { target in
            let sdkPath = try sdkPaths[target.sdk] ?? Self.output(of: ["xcrun", "--sdk", target.sdk, "--show-sdk-path"])
            sdkPaths[target.sdk] = sdkPath
            return FixturePlatform(triple: target.triple, sdk: target.sdk, sdkPath: sdkPath)
        }
    }

    static func withWorkDirectory<Result>(_ body: (URL) throws -> Result) throws -> Result {
        let directory = FileManager.default.temporaryDirectory.appending(path: "xcprivacy-gate-fixtures-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        return try body(directory)
    }

    func compile(_ sources: [URL], into work: URL, index: URL) throws -> [CompiledBatch] {
        try platforms.map { platform in
            let directory = work.appending(path: "\(platform.triple)/objects", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let indexing = platform.isDevice ? ["-index-store-path", index.path, "-index-ignore-system-modules"] : []
            _ = try Toolchain.run(
                command(for: platform) + ["-parse-as-library", "-module-name", Self.module, "-c", "-working-directory", directory.path]
                    + indexing + sources.map(\.path)
            )
            return CompiledBatch(
                platform: platform,
                directory: directory,
                objects: sources.map { directory.appending(path: "\($0.deletingPathExtension().lastPathComponent).o") }
            )
        }
    }

    func link(_ objects: [URL], for platform: FixturePlatform, into library: URL) throws {
        try FileManager.default.createDirectory(at: library.deletingLastPathComponent(), withIntermediateDirectories: true)
        _ = try Toolchain.run(command(for: platform) + ["-emit-library"] + objects.map(\.path) + ["-o", library.path])
    }

    private func command(for platform: FixturePlatform) -> [String] {
        [swiftc, "-sdk", platform.sdkPath, "-target", platform.triple]
    }

    private static func output(of command: [String]) throws -> String {
        try Toolchain.run(command).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
