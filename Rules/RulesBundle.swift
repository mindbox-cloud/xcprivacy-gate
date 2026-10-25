import Foundation

package enum RulesBundle {
    package static var directory: URL {
        Bundle.module.resourceURL ?? Bundle.module.bundleURL
    }
}
