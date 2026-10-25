import Darwin

public func fstatatFixture(_ directory: Int32) -> Int32 {
    var info = stat()
    return fstatat(directory, "file", &info, 0)
}
