import Darwin

public func getattrlistbulkFixture(_ directory: Int32) -> Int32 {
    var list = attrlist()
    var buffer = [UInt8](repeating: 0, count: 64)
    return getattrlistbulk(directory, &list, &buffer, buffer.count, 0)
}
