import Foundation

/// One location shared by the app and extension. Installation metadata stays app-only.
enum AutomationSharedConfiguration {
    static let appGroup = "group.jp.qleap.intrcptr"

    private static func sharedBaseURL() -> URL? {
        guard var base = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup) else { return nil }
        #if DEBUG
        if let name = ProcessInfo.processInfo.environment["INTERCEPTOR_TEST_AUTOMATION_STORE"],
           name.hasPrefix("Interceptor.UITests."),
           name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" })
        {
            base.append(path: name, directoryHint: .isDirectory)
        }
        #endif
        return base
    }
    static func activationURL() -> URL? {
        sharedBaseURL()?.appending(path: "Interceptor/Automation/active.json")
    }

    static func pluginFilesURL() -> URL? {
        sharedBaseURL()?.appending(path: "Library/Application Support/Interceptor/PluginFiles", directoryHint: .isDirectory)
    }

    static func pluginFileRecordsURL() -> URL? {
        sharedBaseURL()?.appending(path: "Library/Application Support/Interceptor/PluginFileRecords", directoryHint: .isDirectory)
    }
}
