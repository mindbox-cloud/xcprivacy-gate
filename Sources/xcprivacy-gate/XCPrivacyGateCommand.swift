import ArgumentParser
import Foundation
import XCPrivacyGate
import XCPrivacyGateRules

@main
struct XCPrivacyGateCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "xcprivacy-gate",
        abstract: "Compares the SDK's privacy manifests with the privacy-relevant APIs its code uses.",
        subcommands: [SelfTestCommand.self, LearnCommand.self]
    )

    static func main() {
        do {
            var command = try parseAsRoot()
            try command.run()
        } catch {
            finish(with: error)
        }
    }

    private static func finish(with error: Error) -> Never {
        let message = fullMessage(for: error)
        if exitCode(for: error) == .success {
            print(message)
            Foundation.exit(EXIT_SUCCESS)
        }
        FileHandle.standardError.write(Data((message + "\n").utf8))
        Foundation.exit(2)
    }
}

struct SelfTestCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "self-test",
        abstract: "Checks that the bundled rules find every fixture, and nothing else, with the selected Xcode."
    )

    func run() throws {
        let violations = try SelfTest.run(rules: Rules.load(RulesBundle.directory.appending(path: "rules.json")), rulesDirectory: RulesBundle.directory)
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        for violation in violations {
            print(Report.annotation(violation, root: root))
        }
        print(Report.summary(title: "self-test", violations: violations))
        Foundation.exit(Report.exitCode(violations: violations))
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
