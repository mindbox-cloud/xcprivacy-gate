import Darwin

public func getattrlistatFixture(_ directory: Int32) -> Int32 {
    var list = attrlist()
    var buffer = [UInt8](repeating: 0, count: 64)
    return getattrlistat(directory, "file", &list, &buffer, buffer.count, 0)
}
