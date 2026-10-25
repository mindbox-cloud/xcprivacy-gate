import Foundation

public enum RulesBundle {
    public static var directory: URL {
        Bundle.module.resourceURL ?? Bundle.module.bundleURL
    }
}
