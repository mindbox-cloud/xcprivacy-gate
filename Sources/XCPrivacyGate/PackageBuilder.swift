import Foundation

package struct SDKBuild: Sendable {
    package let indexStore: URL
    package let products: URL

    package init(indexStore: URL, products: URL) {
        self.indexStore = indexStore
        self.products = products
    }

    func object(of target: String) -> URL {
        products.appending(path: "\(target).o")
    }
}

package enum PackageBuilder {
    package static func build(root: URL, targets: [PackageTarget], work: URL) throws -> SDKBuild {
        let scratch = work.appending(path: "build", directoryHint: .isDirectory)
        let build = SDKBuild(
            indexStore: work.appending(path: "index", directoryHint: .isDirectory),
            products: scratch.appending(path: "out/Products/Release-iphoneos", directoryHint: .isDirectory)
        )
        let sdk = try Toolchain.run(["xcrun", "--sdk", "iphoneos", "--show-sdk-path"]).trimmingCharacters(in: .whitespacesAndNewlines)
        _ = try Toolchain.run([
            "swift", "build", "--package-path", root.path, "--scratch-path", scratch.path, "--build-system", "swiftbuild",
            "--triple", "arm64-apple-ios", "--sdk", sdk, "-c", "release", "--force-resolved-versions",
            "-Xswiftc", "-index-store-path", "-Xswiftc", build.indexStore.path, "-Xcc", "-index-store-path", "-Xcc", build.indexStore.path
        ])
        let missing = targets.map(\.name).filter { !FileManager.default.fileExists(atPath: build.object(of: $0).path) }
        guard missing.isEmpty else {
            throw ToolError(message: "swift build left no object for \(missing.joined(separator: ", ")) in \(build.products.path), so the binary scan cannot read those targets")
        }
        return build
    }
}
