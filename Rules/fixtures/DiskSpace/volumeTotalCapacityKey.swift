import Foundation

public func volumeTotalCapacityKeyFixture(_ url: URL) -> URLResourceValues? {
    try? url.resourceValues(forKeys: [.volumeTotalCapacityKey])
}
