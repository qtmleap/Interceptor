import Foundation

/// One location shared by the app and extension. Installation metadata stays app-only.
enum AutomationSharedConfiguration {
    static let appGroup = "group.jp.qleap.intrcptr"

    static func activationURL() -> URL? {
        guard var base = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup) else { return nil }
        #if DEBUG
        if let name = ProcessInfo.processInfo.environment["INTERCEPTOR_TEST_AUTOMATION_STORE"],
           name.hasPrefix("Interceptor.UITests."),
           name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" })
        {
            base.append(path: name, directoryHint: .isDirectory)
        }
        #endif
        return base.appending(path: "Interceptor/Automation/active.json")
    }
}
