import Foundation

package enum Gate {
    package static func check(config: GateConfig, rules: Rules, today: Date) throws -> (title: String, violations: [Violation]) {
        let usage = try Usage.load(config.usage, rules: rules, userDefaultsAppGroup: config.userDefaultsAppGroup)
        let package = try PackageReader.read(root: config.packagePath)
        try requireSourcesInside(config.repositoryRoot, package: package)
        let (use, shipped) = try WorkDirectory.with { work in
            let build = try PackageBuilder.build(root: package.root, targets: package.targets, work: work)
            let use = try scan(package, build: build, rules: rules, usage: usage, root: config.repositoryRoot)
            return (use, shippedManifests(of: package, build: build, root: config.repositoryRoot))
        }
        let declared = manifests(of: shipped.targets, rules: rules, trackingDisabled: config.trackingDisabled)
        var violations = package.violations + shipped.violations + declared.violations
        let policy = Policy(usage: usage, rules: rules, userDefaultsAppGroup: config.userDefaultsAppGroup, today: today)
        violations += policy.evaluate(targets: shipped.targets, source: use.source, binary: use.binary, manifests: declared.manifests)
        return (title: "check of \(package.name)", violations: violations)
    }

    static func manifests(of targets: [PackageTarget], rules: Rules, trackingDisabled: Bool) -> (manifests: [String: Manifest], violations: [Violation]) {
        var manifests: [String: Manifest] = [:]
        var violations: [Violation] = []
        for target in targets {
            guard let file = target.manifest else { continue }
            let (manifest, found) = ManifestValidator.parse(file, module: target.name, rules: rules, trackingDisabled: trackingDisabled)
            manifests[target.name] = manifest
            violations += found
        }
        return (manifests, violations)
    }

    private static func requireSourcesInside(_ root: URL, package: PackageDescription) throws {
        let outside = package.targets.flatMap(\.sources).filter { !root.encloses($0.canonicalPath) }
        guard outside.isEmpty else {
            let files = outside.map { "\(Report.repositoryRelative($0.path, root: root)) resolves to \($0.canonicalPath)" }.joined(separator: ", ")
            throw ToolError(message: "\(files), outside the git checkout \(root.path): the gate needs every source inside the checkout")
        }
    }

    private static func shippedManifests(of package: PackageDescription, build: SDKBuild, root: URL) -> (targets: [PackageTarget], violations: [Violation]) {
        var violations: [Violation] = []
        let targets = package.targets.map { target in
            guard target.manifest == nil, let unlisted = package.unlistedManifests[target.name] else {
                return target
            }
            let bundle = build.resourceBundle(of: target.name, in: package.name)
            if let shipped = unlisted.files.first(where: { FileManager.default.contentsEqual(atPath: $0.canonicalPath, andPath: bundle.appending(path: $0.lastPathComponent).path) }) {
                return target.shipping(shipped)
            }
            if let file = unlisted.atTargetRoot {
                violations.append(Violation(
                    code: "MANIFEST_NOT_WIRED",
                    module: target.name,
                    message: "\(target.name): \(Report.repositoryRelative(file.path, root: root)) is not shipped as a resource of the target; "
                        + "check the file name's case and the target's resources in Package.swift",
                    file: file.path
                ))
            }
            return target
        }
        return (targets, violations)
    }

    private static func scan(
        _ package: PackageDescription,
        build: SDKBuild,
        rules: Rules,
        usage: Usage,
        root: URL
    ) throws -> (source: [String: ModuleFindings], binary: [String: ModuleFindings]) {
        let index = try IndexScanner(store: build.indexStore).findings(targets: package.targets, rules: rules, root: root)
        let strings = try StringLiterals.findings(targets: package.targets, rules: rules, usage: usage, root: root)
        let binary = try BinaryScanner.findings(build: build, targets: package.targets, rules: rules, usage: usage)
        return (source: strings.merging(index) { $0.merging($1) }, binary: binary)
    }
}
