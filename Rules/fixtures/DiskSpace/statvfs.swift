import Darwin

public func statvfsFixture() -> Int32 {
    var info = statvfs()
    return statvfs("/", &info)
}
