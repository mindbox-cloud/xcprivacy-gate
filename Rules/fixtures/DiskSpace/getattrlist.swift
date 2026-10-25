import Darwin

public func getattrlistFixture() -> Int32 {
    var list = attrlist()
    var buffer = [UInt8](repeating: 0, count: 64)
    return getattrlist("/", &list, &buffer, buffer.count, 0)
}
