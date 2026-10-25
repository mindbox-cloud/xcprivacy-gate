import Darwin

public func fgetattrlistFixture(_ descriptor: Int32) -> Int32 {
    var list = attrlist()
    var buffer = [UInt8](repeating: 0, count: 64)
    return fgetattrlist(descriptor, &list, &buffer, buffer.count, 0)
}
