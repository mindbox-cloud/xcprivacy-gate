import Darwin

public func statfsFixture() -> Int32 {
    var info = statfs()
    return statfs("/", &info)
}
