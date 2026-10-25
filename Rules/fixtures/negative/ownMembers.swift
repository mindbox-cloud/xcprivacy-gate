import Foundation

public struct OwnMembersNegative {
    let creationDate: Date
    let systemSize: Int
    let systemUptime: Double

    public static func make() -> OwnMembersNegative {
        OwnMembersNegative(creationDate: Date(), systemSize: 1, systemUptime: 2)
    }
}
