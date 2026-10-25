import Darwin

public func lstatFixture() -> Int32 {
    var info = stat()
    return lstat("/", &info)
}
