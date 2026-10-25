import Darwin

public func fstatfsFixture(_ descriptor: Int32) -> Int32 {
    var info = statfs()
    return fstatfs(descriptor, &info)
}
