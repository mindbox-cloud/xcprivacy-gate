import Darwin

public func statFixture() -> Int32 {
    var info = stat()
    return stat("/", &info)
}
