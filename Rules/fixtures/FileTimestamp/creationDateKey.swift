import Foundation

public func creationDateKeyFixture(_ url: URL) -> URLResourceValues? {
    try? url.resourceValues(forKeys: [.creationDateKey])
}
