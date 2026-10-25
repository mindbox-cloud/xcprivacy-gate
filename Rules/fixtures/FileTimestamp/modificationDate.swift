import Foundation

public func modificationDateFixture(_ attributes: [FileAttributeKey: Any]) -> Any? {
    attributes[.modificationDate]
}
