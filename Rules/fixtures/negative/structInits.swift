import Darwin

public func structInitsNegative() -> (stat, statfs, statvfs, attrlist) {
    var info = stat()
    info.st_size = 1
    return (info, statfs(), statvfs(), attrlist())
}
