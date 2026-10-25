import Foundation
import Testing
import XCPrivacyGate

@Suite("Toolchain")
struct ToolchainTests {
    @Test("a failing command is a tool error with the command and the tail of its stderr")
    func failingCommandReportsStderrTail() throws {
        let script = "printf START >&2; yes e | head -c 5000 >&2; printf END >&2; exit 3"

        let error = #expect(throws: ToolError.self) { try Toolchain.run(["sh", "-c", script], in: nil) }

        let message = try #require(error?.message)
        let prefix = "sh -c \(script) failed (3): "
        #expect(message.hasPrefix(prefix))
        let tail = message.dropFirst(prefix.count)
        #expect(tail.hasSuffix("END"))
        #expect(!tail.contains("START"))
        #expect(tail.count <= 2_000)
    }

    @Test("output larger than a pipe buffer on both streams is read in full")
    func largeOutputOnBothStreamsIsRead() throws {
        let output = try Toolchain.run(["sh", "-c", "yes e | head -c 300000 >&2; yes o | head -c 300000"], in: nil)

        #expect(output.count == 300_000)
        #expect(output.hasPrefix("o\no\n"))
    }

    @Test("a command runs in the given directory")
    func commandRunsInGivenDirectory() throws {
        try withTemporaryDirectory { directory in
            try Data().write(to: directory.appendingPathComponent("marker"))

            let output = try Toolchain.run(["ls"], in: directory)

            #expect(output == "marker\n")
        }
    }

    @Test("a command in a directory that does not exist cannot start")
    func missingDirectoryCannotStart() throws {
        try withTemporaryDirectory { directory in
            let missing = directory.appendingPathComponent("missing", isDirectory: true)

            let error = #expect(throws: ToolError.self) { try Toolchain.run(["ls"], in: missing) }

            #expect(error?.message.hasPrefix("ls could not start: ") == true)
        }
    }

    @Test("output that is not UTF-8 is still a tool error naming the command", arguments: [#"printf '\377'"#, #"printf '\377' >&2; exit 1"#])
    func nonUTF8OutputIsToolError(script: String) throws {
        let error = #expect(throws: ToolError.self) { try Toolchain.run(["sh", "-c", script], in: nil) }

        #expect(error?.message.hasPrefix("sh -c \(script) ") == true)
        #expect(error?.message.contains("not UTF-8") == true)
    }
}
