import Darwin

public func fstatFixture(_ descriptor: Int32) -> Int32 {
    var info = stat()
    return fstat(descriptor, &info)
}
