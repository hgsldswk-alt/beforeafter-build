import Foundation

enum Launch {
    static let freePeriod = false
    static var testing: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("-ui-testing")
        #else
        false
        #endif
    }

    static func isFree(arguments: [String]) -> Bool {
        freePeriod && !arguments.contains(where: { ["-paid-mode", "-paywall", "-expired"].contains($0) })
    }
    static var isFree: Bool { isFree(arguments: ProcessInfo.processInfo.arguments) }
}
