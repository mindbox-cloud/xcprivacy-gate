import Foundation

public func mixedProbe(url: URL) -> [Any] {
    let attributes = try? FileManager.default.attributesOfFileSystem(forPath: "/")
    let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
    return [
        ProcessInfo.processInfo.systemUptime,
        attributes?[.systemFreeSize] as Any,
        UserDefaults.standard.bool(forKey: "probe"),
        UserDefaults(suiteName: "cloud.Mindbox.webview.localState") as Any,
        mach_absolute_time(),
        values?.contentModificationDate as Any,
    ]
}
