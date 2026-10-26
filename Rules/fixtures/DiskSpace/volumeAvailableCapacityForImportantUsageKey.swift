import Foundation

public func volumeAvailableCapacityForImportantUsageKeyFixture(_ url: URL) -> URLResourceValues? {
    try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
}
