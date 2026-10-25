import Foundation

public func systemUptimeFixture() -> TimeInterval {
    ProcessInfo.processInfo.systemUptime
}
