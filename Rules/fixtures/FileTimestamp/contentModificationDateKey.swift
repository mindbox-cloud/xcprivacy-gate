import Foundation

public func contentModificationDateKeyFixture(_ url: URL) -> URLResourceValues? {
    try? url.resourceValues(forKeys: [.contentModificationDateKey])
}
