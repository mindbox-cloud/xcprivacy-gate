import Foundation

public func volumeAvailableCapacityForOpportunisticUsageKeyFixture(_ url: URL) -> URLResourceValues? {
    try? url.resourceValues(forKeys: [.volumeAvailableCapacityForOpportunisticUsageKey])
}
