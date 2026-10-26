import ArgumentParser
import Foundation
import XCPrivacyGate
import XCPrivacyGateRules

@main
struct XCPrivacyGateCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "xcprivacy-gate",
        abstract: "Compares the SDK's privacy manifests with the privacy-relevant APIs its code uses.",
        subcommands: [CheckCommand.self, SelfTestCommand.self, LearnCommand.self]
    )

    static func main() {
        main(nil)
    }

    static func main(_ arguments: [String]?) {
        do {
            var command = try parseAsRoot(arguments)
            try command.run()
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
        let rulesFile = URL(fileURLWithPath: rulesDirectory, isDirectory: true).appending(path: "rules.json")
        try Learn.update(rulesFile: rulesFile, api: api)
        print("\(rulesFile.path): learned \(api ?? "every API")")
    }
}

private func bundledRules() throws -> Rules {
    try Rules.load(RulesBundle.directory.appending(path: "rules.json"))
}

private func conclude(title: String, violations: [Violation], root: URL) throws -> Never {
    for violation in violations {
        print(Report.annotation(violation, root: root))
    }
    print(Report.summary(title: title, violations: violations))
    try Report.appendStepSummary(title: title, violations: violations)
    Foundation.exit(Report.exitCode(violations: violations))
}
