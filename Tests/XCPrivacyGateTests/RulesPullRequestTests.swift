import Foundation
import Testing

private let branch = "bot/apple-privacy-rules"
private let title = "feat: refresh Apple privacy rules"
private let script = repositoryRoot.appending(path: "scripts/rules-pr.sh")

private let ownPullRequest = #"[{"number": 7, "isCrossRepository": false}]"#

private let fakeGh = """
    #!/bin/sh
    echo "$*" >> "$GH_LOG"
    if [ "$1 $2" = "pr list" ]; then
      filter=.
      while [ $# -gt 0 ]; do
        if [ "$1" = --jq ]; then filter=$2; fi
        shift
      done
      printf '%s' "$GH_OPEN_PRS" | jq -r "$filter"
    fi

    """

private let fakeGate = """
    #!/bin/sh
    echo "$*" >> "$GATE_LOG"
    if [ -n "$RULES_LINE" ]; then echo "$RULES_LINE" >> "$3/rules.json"; fi
    echo body > "$5"

    """

private struct CommandFailure: Error, CustomStringConvertible {
    let description: String
}

private struct RulesPullRequestRepository {
    let directory: URL
    let origin: URL
    let body: URL
    private let environment: [String: String]

    init() throws {
        directory = try canonical(makeTemporaryDirectory())
        origin = directory.appending(path: "origin.git")
        body = directory.appending(path: "body.md")
        let bin = directory.appending(path: "bin", directoryHint: .isDirectory)
        try writeFiles(["bin/gh": fakeGh, "bin/xcprivacy-gate": fakeGate], to: directory)
        for tool in ["gh", "xcprivacy-gate"] {
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bin.appending(path: tool).path)
        }
        environment = ProcessInfo.processInfo.environment.merging([
            "PATH": "\(bin.path):\(ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin")",
            "GIT_CONFIG_GLOBAL": "/dev/null",
            "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_AUTHOR_NAME": "Test",
            "GIT_AUTHOR_EMAIL": "test@example.com",
            "GIT_COMMITTER_NAME": "Test",
            "GIT_COMMITTER_EMAIL": "test@example.com",
            "GH_LOG": directory.appending(path: "gh.log").path,
            "GATE_LOG": directory.appending(path: "gate.log").path,
            "BRANCH": branch,
            "BASE_BRANCH": "main",
            "BODY": body.path
        ]) { $1 }
        try git(["init", "--quiet", "--bare", "--initial-branch=main", origin.path])
        let seed = directory.appending(path: "seed", directoryHint: .isDirectory)
        try git(["init", "--quiet", "--initial-branch=main", seed.path])
        try git(["remote", "add", "origin", origin.path], in: seed)
        try writeFiles(["Rules/rules.json": "v1\n", "Rules/apple/tn3181.txt": "note\n"], to: seed)
        try commit(seed, "Main")
        try git(["push", "--quiet", "origin", "main"], in: seed)
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }

    @discardableResult
    func run(_ arguments: [String], in workingDirectory: URL? = nil, adding extra: [String: String] = [:]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = arguments
        process.currentDirectoryURL = workingDirectory ?? directory
        process.environment = environment.merging(extra) { $1 }
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let text = String(bytes: try output.fileHandleForReading.readToEnd() ?? Data(), encoding: .utf8) ?? "output that is not UTF-8"
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw CommandFailure(description: "\(arguments.joined(separator: " ")) exited \(process.terminationStatus): \(text)")
        }
        return text
    }

    @discardableResult
    func git(_ arguments: [String], in workingDirectory: URL? = nil) throws -> String {
        try run(["git"] + arguments, in: workingDirectory)
    }

    func clone(_ name: String) throws -> URL {
        let path = directory.appending(path: name, directoryHint: .isDirectory)
        try git(["clone", "--quiet", "--branch", "main", origin.path, path.path])
        return path
    }

    func commit(_ checkout: URL, _ subject: String) throws {
        try git(["add", "-A"], in: checkout)
        try git(["commit", "--quiet", "-m", subject], in: checkout)
    }

    func pushBranch(_ subjects: [String]) throws {
        let work = try clone("branch-work")
        try git(["switch", "--quiet", "-c", branch], in: work)
        for (position, subject) in subjects.enumerated() {
            try writeFiles(["file\(position).txt": subject], to: work)
            try commit(work, subject)
        }
        try git(["push", "--quiet", "origin", branch], in: work)
    }

    func runScript(line: String?, openPullRequests: String) throws {
        let checkout = try clone("checkout-\(UUID().uuidString)")
        try run(
            ["bash", script.path, directory.appending(path: "bin/xcprivacy-gate").path],
            in: checkout,
            adding: ["RULES_LINE": line ?? "", "GH_OPEN_PRS": openPullRequests]
        )
    }

    func subjects(_ branch: String) throws -> [String] {
        try git(["--git-dir", origin.path, "log", "--format=%s", branch]).split(separator: "\n").map(String.init)
    }

    func remoteBranches() throws -> String {
        try git(["--git-dir", origin.path, "branch", "--list", branch])
    }

    func remoteRules(_ branch: String) throws -> String {
        try git(["--git-dir", origin.path, "show", "\(branch):Rules/rules.json"])
    }

    func log(_ name: String) throws -> [String] {
        let file = directory.appending(path: name)
        guard FileManager.default.fileExists(atPath: file.path) else { return [] }
        return try String(contentsOf: file, encoding: .utf8).split(separator: "\n").map(String.init)
    }
}

@Suite("Rules pull request script")
struct RulesPullRequestTests {
    @Test("the first run refreshes the rules with the built tool and opens a pull request from main without a reviewer")
    func firstRunOpensPullRequest() throws {
        let repository = try RulesPullRequestRepository()
        defer { repository.remove() }

        try repository.runScript(line: "v2", openPullRequests: "[]")

        #expect(try repository.subjects(branch) == [title, "Main"])
        #expect(try repository.remoteRules(branch) == "v1\nv2\n")
        #expect(try repository.log("gate.log") == ["refresh --rules-directory Rules --out-pr-body \(repository.body.path)"])
        #expect(try repository.log("gh.log").contains(
            "pr create --base main --head \(branch) --title \(title) --body-file \(repository.body.path)"
        ))
    }

    @Test("a run with no change pushes nothing and opens nothing")
    func noChangePushesNothing() throws {
        let repository = try RulesPullRequestRepository()
        defer { repository.remove() }

        try repository.runScript(line: nil, openPullRequests: "[]")

        #expect(try repository.remoteBranches().isEmpty)
        #expect(try repository.log("gh.log").allSatisfy { $0.hasPrefix("pr list") })
    }

    @Test("an open pull request keeps the commits people pushed and gets a comment")
    func openPullRequestKeepsPushedCommits() throws {
        let repository = try RulesPullRequestRepository()
        defer { repository.remove() }
        try repository.pushBranch([title, "Add the fixture for the new API"])

        try repository.runScript(line: "v3", openPullRequests: ownPullRequest)

        #expect(try repository.subjects(branch).prefix(3) == [title, "Add the fixture for the new API", title])
        #expect(try repository.remoteRules(branch) == "v1\nv3\n")
        #expect(try repository.log("gh.log").contains { $0.hasPrefix("pr comment 7 --body-file ") })
    }

    @Test("a branch without an open pull request restarts from main")
    func branchWithoutPullRequestRestartsFromMain() throws {
        let repository = try RulesPullRequestRepository()
        defer { repository.remove() }
        try repository.pushBranch(["Stale refresh"])

        try repository.runScript(line: "v2", openPullRequests: "[]")

        #expect(try repository.subjects(branch) == [title, "Main"])
    }

    @Test("an open pull request that already holds the change gets nothing")
    func openPullRequestWithSameChangeGetsNothing() throws {
        let repository = try RulesPullRequestRepository()
        defer { repository.remove() }
        let work = try repository.clone("same-work")
        try repository.git(["switch", "--quiet", "-c", branch], in: work)
        try writeFiles(["Rules/rules.json": "v1\nv2\n"], to: work)
        try repository.commit(work, title)
        try repository.git(["push", "--quiet", "origin", branch], in: work)

        try repository.runScript(line: nil, openPullRequests: ownPullRequest)

        #expect(try repository.subjects(branch).count == 2)
        #expect(try repository.log("gh.log").allSatisfy { $0.hasPrefix("pr list") })
    }
}
