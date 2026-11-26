import Foundation

enum Launch {
    static let freePeriod = true
    static var testing: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("-ui-testing")
        #else
        false
        #endif
    }

}
