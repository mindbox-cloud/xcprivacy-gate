# xcprivacy-gate

> [!WARNING]
> xcprivacy-gate is early software and gives no guarantees. A clean run does not mean App Store Connect will accept
> your build, and a finding can be wrong. Check every result and every manifest change by hand in review and against
> Apple's documentation. The project is not affiliated with Apple.

xcprivacy-gate is a CI gate for Swift packages. It fails a pull request when a module's `PrivacyInfo.xcprivacy` and
its code disagree on required-reason APIs.

## What it checks

For each library target of the package:

- the code uses a required-reason API whose category the manifest does not declare;
- the manifest declares a category that no code in the module uses;
- every call has an entry in `usage.json` with Apple's reason code and a purpose, and the manifest declares exactly
  the registered reasons;
- the manifest is named `PrivacyInfo.xcprivacy`, is valid by Apple's rules (keys, types, categories, reasons, data
  types, purposes, tracking) and `Package.swift` ships it as a resource of the target.

Each finding is a GitHub annotation on `file:line` when the gate knows the line.

## How it works

`check` builds the package for iOS in release with SwiftPM in a temporary directory, so the checkout stays untouched.
Three scans then read the result:

| Scan | Reads | Finds |
|---|---|---|
| Index store | the build's index through indexstore-db | references to each API by its USR, with `file:line` |
| String literals | the Swift sources through SwiftSyntax | APIs reached by name, such as `FileAttributeKey(rawValue:)` |
| Compiled objects | each target's object file through `nm`, `otool` and `swift-demangle` | APIs that no source file shows (`BINARY_ONLY_API`) |

The string scan reads only the `#if` branches that a shipped build can compile: iOS, tvOS, watchOS and visionOS in
release, so `DEBUG` is off unless the package defines it for release. It reads every branch of a condition it cannot
decide.

The rules ship with the tool in `Rules/rules.json`: Apple's categories, reasons and APIs, and how each scan finds each
API. `self-test` compiles one small fixture per API for an iOS device and two simulators with the selected Xcode. Each
scan must find that fixture's API and nothing else. Run it before `check`: when a new Xcode changes how an API is
compiled, `self-test` fails first, so a broken rule cannot pass for clean code.

## Requirements

- A macOS 26 runner (`macos-26` on GitHub).
- Xcode 26.4 or later, the first Xcode with Swift 6.3. The tool is tested with Xcode 26.6.
- A Swift package whose library targets are Swift only and that has no package dependencies (see
  [Limitations](#limitations)).
- The config inside a git checkout.

## Use it in a repository

Add the config files (below) and a job:

```yaml
jobs:
  privacy-manifest:
    runs-on: macos-26
    steps:
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
      - uses: mindbox-cloud/xcprivacy-gate@<full commit SHA> # v0.1.0
        with:
          args: self-test
      - uses: mindbox-cloud/xcprivacy-gate@<full commit SHA> # v0.1.0
        with:
          args: check --config .github/privacy-manifest/config.json
```

| Input | Default | Meaning |
|---|---|---|
| `args` | required | the command and its options on one line; the action splits it on whitespace and does not read quotes |
| `working-directory` | `.` | the directory the tool runs in |

The action builds the tool from source at the pinned commit and caches the build by runner OS, Xcode version and
commit. The first run builds for a few minutes; later runs reuse the cache. The action saves the build before the
gate runs, so a run that finds violations still leaves the cache for the next one. Pin a full commit SHA with the tag
in a comment, as above.

### `config.json`

```json
{
  "usage": "usage.json",
  "packagePath": "../..",
  "policy": {
    "userDefaultsAppGroup": false,
    "trackingDisabled": true
  },
  "appleSdkList": {
    "name": "Sample",
    "listed": false
  }
}
```

| Key | Required | Meaning |
|---|---|---|
| `usage` | yes | the path of `usage.json`, relative to the config |
| `packagePath` | no | the directory that holds `Package.swift`, relative to the config and inside the git checkout that holds the config; by default the root of that checkout |
| `policy.userDefaultsAppGroup` | yes | `true`: UserDefaults follows a fixed policy instead of `usage.json`. Any use needs `1C8F.1`, because the SDK keeps its data in an App Group suite; `UserDefaults.standard` or a suite listed in `privateUserDefaultsSuites` also needs `CA92.1`; no other UserDefaults reason is allowed. `false`: UserDefaults calls are registered like any other API |
| `policy.trackingDisabled` | yes | `true`: every manifest declares `NSPrivacyTracking` as `false`, lists no tracking domains and no tracked data |
| `appleSdkList` | no | `name` and `listed`: whether Apple's [list of SDKs that require a privacy manifest and signature](https://developer.apple.com/support/third-party-SDK-requirements/) names this SDK, as you last reviewed it. Only `refresh --check` reads it and compares it with the live page; `check` ignores it |

Unknown keys are a tool error.

### `usage.json`

```json
{
  "calls": [
    {
      "module": "Core",
      "file": "Sources/Core/Clock.swift",
      "api": "mach_absolute_time",
      "reason": "35F9.1",
      "purpose": "Measure the time between two events in the app"
    }
  ],
  "privateUserDefaultsSuites": [],
  "overrides": [
    {
      "module": "Core",
      "category": "NSPrivacyAccessedAPICategoryDiskSpace",
      "reasons": ["E174.1"],
      "evidence": "App Store Connect email about build 1.4.0 on 2026-09-14",
      "expires": "2027-03-14"
    }
  ]
}
```

- `calls` registers each file that calls a required-reason API: the target, the file's path relative to the
  repository root with symlinks resolved, the API's name in `Rules/rules.json`, one of Apple's reasons for its
  category, and why the code calls it.
- `privateUserDefaultsSuites` lists the suite names that need `CA92.1` under `userDefaultsAppGroup`.
- `overrides` declares a category that no visible call explains, for example after an email from App Store Connect.
  Each override needs evidence and an `expires` date (`YYYY-MM-DD`); `check` fails once the date passes.

All three keys are required, even when empty.

## Exit codes and output

| Code | Meaning |
|---|---|
| `0` | no violations |
| `1` | violations |
| `2` | the tool failed: a broken config, a failed build, a source file the build did not index |

Each violation is printed as an `::error` annotation, followed by a summary. When `GITHUB_STEP_SUMMARY` is set, the
summary is also appended to the job summary.

## Commands

| Command | What it does |
|---|---|
| `check --config <path>` | builds the package and checks it |
| `self-test` | checks the bundled rules against their fixtures with the selected Xcode |
| `refresh --check --config <path>` | reads Apple's required-reasons page, and its SDK list when the config has `appleSdkList`, and reports changed conditions of the reasons the SDK declares and Apple's current SDK-list verdict; writes nothing |
| `learn [<api>] --rules-directory Rules` | for maintainers: compiles the fixtures and writes the names they produce into `Rules/rules.json` |
| `refresh --rules-directory Rules --out-pr-body <path>` | for maintainers: updates the rules from Apple's pages |
| `--version` | prints the version |

## Violation codes

| Code | Meaning |
|---|---|
| `MISSING_CATEGORY` | the code uses a category the manifest does not declare |
| `EXTRA_CATEGORY` | the manifest declares a category no code uses; remove it, or add an override with evidence |
| `UNREGISTERED_CALL` | a call has no entry in `usage.json` for its file; the message lists Apple's reasons |
| `STALE_ENTRY` | an entry points at a call that is gone |
| `LIKELY_MOVE` | a registered call moved to another file |
| `REASONS_MISMATCH` | the manifest's reasons differ from the registered ones |
| `BINARY_ONLY_API` | the compiled module uses an API that no source file in it calls |
| `UD_APP_GROUP_REQUIRED`, `UD_STANDARD_REQUIRED`, `UD_CA92_UNUSED` | the UserDefaults reasons break the `userDefaultsAppGroup` policy |
| `TARGET_WITHOUT_MANIFEST_USES_API` | a target without a manifest uses a required-reason API |
| `OVERRIDE_EXPIRED`, `REGISTRY_UNKNOWN_MODULE`, `REGISTRY_UNKNOWN_REASON` | an entry in `usage.json` is out of date |
| `MANIFEST_API_ENTRY_KEYS`, `MANIFEST_DATA_ENTRY_KEYS`, `MANIFEST_DUPLICATE_ENTRY`, `MANIFEST_DUPLICATE_KEY`, `MANIFEST_EMPTY_API_TYPES`, `MANIFEST_EMPTY_REASONS`, `MANIFEST_FILE_NAME`, `MANIFEST_MISSING_KEY`, `MANIFEST_REASON_WRONG_CATEGORY`, `MANIFEST_TYPE`, `MANIFEST_UNKNOWN_CATEGORY`, `MANIFEST_UNKNOWN_DATA_TYPE`, `MANIFEST_UNKNOWN_KEY`, `MANIFEST_UNKNOWN_PURPOSE`, `MANIFEST_UNKNOWN_REASON`, `MANIFEST_UNREADABLE` | the manifest is not valid by Apple's rules |
| `TRACKING_ENABLED`, `TRACKING_DOMAINS` | tracking breaks the `trackingDisabled` policy, or the tracking domains do not match `NSPrivacyTracking` |
| `MANIFEST_NOT_WIRED` | a manifest at the target's root is not shipped as a resource: `Package.swift` does not list it, or names it in another case |
| `PACKAGE_DEPENDENCY`, `UNSCANNABLE_SOURCE` | the package has code the gate cannot read (see [Limitations](#limitations)) |
| `SDK_ON_APPLE_LIST`, `SDK_OFF_APPLE_LIST` | `refresh --check`: Apple's live SDK list disagrees with `appleSdkList` |
| `DECLARED_REASON_CHANGED` | `refresh --check`: Apple changed the condition of a reason the SDK declares |
| `RULE_INCOMPLETE`, `FIXTURE_MISSED`, `FIXTURE_CROSSTALK`, `NEGATIVE_HIT` | `self-test`: a rule lacks data, misses its fixture, matches another API's fixture, or matches code that is not a call |

## Limitations

- Objective-C, C and C++ sources fail with `UNSCANNABLE_SOURCE` ([#1](https://github.com/mindbox-cloud/xcprivacy-gate/issues/1)).
- Only Swift packages are read, not Xcode projects ([#2](https://github.com/mindbox-cloud/xcprivacy-gate/issues/2)).
- `check` always builds the package itself and cannot reuse an existing build ([#3](https://github.com/mindbox-cloud/xcprivacy-gate/issues/3)).
- The results are annotations and a job summary, not SARIF ([#4](https://github.com/mindbox-cloud/xcprivacy-gate/issues/4)).
- Packages with dependencies are not supported yet (`PACKAGE_DEPENDENCY`). The build runs with
  `--force-resolved-versions`, so it never writes `Package.resolved` into your package.
- The compiled-object scan does not see access by string, and private suite names of 15 bytes or fewer are invisible
  to it: Swift stores such small strings inline, not in the string section.
- Only the string scan sees `#else` branches of `#if SWIFT_PACKAGE`, because the build is SwiftPM's.

## Versioning

Releases follow [Semantic Versioning](https://semver.org) with tags `v<MAJOR>.<MINOR>.<PATCH>`:

- MAJOR: an incompatible change to `config.json`, `usage.json` or the command line.
- MINOR: new rules or checks, including Apple's updates that the weekly rules refresh brings in. A MINOR release can
  turn a passing repository red.
- PATCH: fixes that add no failures.

The release notes name the date the Apple rules last changed. Read them before you move the pinned commit.

## Releasing

1. Set `ToolVersion.current` in `Sources/XCPrivacyGate/ToolVersion.swift` to the new version in a pull request and
   merge it.
2. Run the Release workflow on `main` with that version.

The workflow refuses any other branch and any version that is not `X.Y.Z`, not greater than the latest `v` tag, or not
equal to `xcprivacy-gate --version`. It builds the tool, runs the tests and `self-test`, tags the tested commit, and
publishes a GitHub release with generated notes. Releases carry no binaries: the action builds from source.

## License

MIT, see [LICENSE](LICENSE). The Apple documentation excerpts in `Rules/` and the Apple pages saved as test data are
not covered by it; see [NOTICE](NOTICE).
