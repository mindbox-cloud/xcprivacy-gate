import Foundation

package enum Gate {
    package static func check(config: GateConfig, rules: Rules, today: Date) throws -> (title: String, violations: [Violation]) {
        let usage = try Usage.load(config.usage, rules: rules, userDefaultsAppGroup: config.userDefaultsAppGroup)
        let package = try PackageReader.read(root: config.packagePath)
        try requireSourcesInside(config.repositoryRoot, package: package)
        let declared = manifests(of: package, rules: rules, trackingDisabled: config.trackingDisabled)
        var violations = package.violations + declared.violations
        let use = try WorkDirectory.with { work in
            try scan(package, rules: rules, usage: usage, root: config.repositoryRoot, work: work)
        }
        let policy = Policy(usage: usage, rules: rules, userDefaultsAppGroup: config.userDefaultsAppGroup, today: today)
        violations += policy.evaluate(targets: package.targets, source: use.source, binary: use.binary, manifests: declared.manifests)
        return (title: "check of \(package.name)", violations: violations)
    }

    static func manifests(of package: PackageDescription, rules: Rules, trackingDisabled: Bool) -> (manifests: [String: Manifest], violations: [Violation]) {
        var manifests: [String: Manifest] = [:]
        var violations: [Violation] = []
        for target in package.targets {
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

    private static func scan(
        _ package: PackageDescription,
        rules: Rules,
        usage: Usage,
        root: URL,
        work: URL
    ) throws -> (source: [String: ModuleFindings], binary: [String: ModuleFindings]) {
        let build = try PackageBuilder.build(root: package.root, targets: package.targets, work: work)
        let index = try IndexScanner(store: build.indexStore).findings(targets: package.targets, rules: rules, root: root)
        let strings = try StringLiterals.findings(targets: package.targets, rules: rules, usage: usage, root: root)
        let binary = try BinaryScanner.findings(build: build, targets: package.targets, rules: rules, usage: usage)
        return (source: strings.merging(index) { $0.merging($1) }, binary: binary)
    }
}
