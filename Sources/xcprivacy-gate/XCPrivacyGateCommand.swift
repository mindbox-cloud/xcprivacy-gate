import ArgumentParser
import Foundation

@main
struct XCPrivacyGateCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "xcprivacy-gate",
        abstract: "Compares the SDK's privacy manifests with the privacy-relevant APIs its code uses."
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
