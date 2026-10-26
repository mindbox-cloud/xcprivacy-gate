import ArgumentParser
import Foundation
import XCPrivacyGate
import XCPrivacyGateRules

@main
struct XCPrivacyGateCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "xcprivacy-gate",
        abstract: "Compares the SDK's privacy manifests with the privacy-relevant APIs its code uses.",
        version: ToolVersion.current,
        subcommands: [CheckCommand.self, SelfTestCommand.self, LearnCommand.self, RefreshCommand.self]
    )

    static func main() async {
        await main(nil)
    }

    static func main(_ arguments: [String]?) async {
        do {
            var command = try parseAsRoot(arguments)
            if var asyncCommand = command as? AsyncParsableCommand {
                try await asyncCommand.run()
            } else {
                try command.run()
            }
        } catch {
            finish(with: error)
        }
    }

    func run() throws {
        throw ValidationError("a subcommand is required")
    }

    private static func finish(with error: Error) -> Never {
        if exitCode(for: error) == .success {
            print(fullMessage(for: error))
            Foundation.exit(EXIT_SUCCESS)
        }
        print(Report.toolErrorAnnotation(message(for: error)))
        FileHandle.standardError.write(Data((fullMessage(for: error) + "\n").utf8))
        Foundation.exit(2)
    }
}

struct CheckCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "check",
        abstract: "Builds the SDK package and compares its privacy manifests with the required-reason APIs its code uses."
    )

    @Option(help: "The gate's config.json.")
    var config: String

    func run() throws {
        let gateConfig = try GateConfig.load(URL(fileURLWithPath: config))
        let result = try Gate.check(config: gateConfig, rules: bundledRules(), today: Date())
        try conclude(title: result.title, violations: result.violations, root: gateConfig.repositoryRoot)
    }
}

struct SelfTestCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "self-test",
        abstract: "Checks that the bundled rules find every fixture, and nothing else, with the selected Xcode."
    )

    func run() throws {
        let violations = try SelfTest.run(rules: bundledRules(), rulesDirectory: RulesBundle.directory)
        try conclude(title: "self-test", violations: violations, root: URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true))
    }
}

struct LearnCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "learn",
        abstract: "Compiles the fixtures and writes the names they produce into rules.json."
    )

    @Argument(help: "The API to learn; every API when omitted.")
    var api: String?

    @Option(help: "The rules directory of the tool's source tree.")
    var rulesDirectory: String

    func run() throws {
        let rulesFile = URL(fileURLWithPath: rulesDirectory, isDirectory: true).appending(path: RulesFile.fileName)
        try Learn.update(rulesFile: rulesFile, api: api)
        print("\(rulesFile.path): learned \(api ?? "every API")")
    }
}

struct RefreshCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "refresh",
        abstract: "Updates the rules from Apple's documentation pages, or with --check reports Apple's changes that concern one SDK."
    )

    @Flag(help: "Report changed conditions of the reasons the config's SDK declares and Apple's live SDK-list verdict; write nothing.")
    var check = false

    @Option(help: "With --check: the gate's config.json.")
    var config: String?

    @Option(help: "The rules directory of the tool's source tree.")
    var rulesDirectory: String?

    @Option(help: "Where to write the pull request body when the rules change.")
    var outPrBody: String?

    func run() async throws {
        let session = URLSession(configuration: .ephemeral)
        switch (check, config, rulesDirectory, outPrBody) {
        case (true, let config?, nil, nil):
            let gateConfig = try GateConfig.load(URL(fileURLWithPath: config))
            let result = try await Refresh.check(config: gateConfig, rulesDirectory: RulesBundle.directory, session: session)
            try conclude(title: result.title, violations: result.violations, root: gateConfig.repositoryRoot)
        case (false, nil, let rulesDirectory?, let outPrBody?):
            let result = try await Refresh.run(rulesDirectory: URL(fileURLWithPath: rulesDirectory, isDirectory: true), session: session)
            guard result.changed else {
                print("Apple's pages match the rules in \(rulesDirectory)")
                return
            }
            try Data(result.body.utf8).write(to: URL(fileURLWithPath: outPrBody))
            print("Apple's pages changed; the rules in \(rulesDirectory) are updated and the pull request body is in \(outPrBody)")
        default:
            throw ValidationError("use refresh --rules-directory <path> --out-pr-body <path>, or refresh --check --config <path>")
        }
    }
}

private func bundledRules() throws -> Rules {
    try Rules.load(RulesBundle.directory.appending(path: RulesFile.fileName))
}

private func conclude(title: String, violations: [Violation], root: URL) throws -> Never {
    for violation in violations {
        print(Report.annotation(violation, root: root))
    }
    print(Report.summary(title: title, violations: violations))
    try Report.appendStepSummary(title: title, violations: violations)
    Foundation.exit(Report.exitCode(violations: violations))
}
