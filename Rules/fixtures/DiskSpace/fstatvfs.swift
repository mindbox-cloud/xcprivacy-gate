import Darwin

public func fstatvfsFixture(_ descriptor: Int32) -> Int32 {
    var info = statvfs()
    return fstatvfs(descriptor, &info)
}
