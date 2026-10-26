import Foundation

public func volumeAvailableCapacityKeyFixture(_ url: URL) -> URLResourceValues? {
    try? url.resourceValues(forKeys: [.volumeAvailableCapacityKey])
}
