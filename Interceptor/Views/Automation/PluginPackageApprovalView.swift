import AutomationCore
import SwiftUI

/// This immutable package is the exact byte sequence bound to the parent's captured grant generation.
struct PluginPackageApprovalView: View {
    let package: PluginPackage
    let confirmTitle: LocalizedStringKey
    let isBusy: Bool
    let onCancel: () -> Void
    let onConfirm: () -> Void

    private var fields: [String] {
        let read = package.manifest.read
        let metadata = read.metadata.map { field in
            switch field {
                case "method": String(localized: "AUTO_APPROVAL_READ_METHOD")
                case "host": String(localized: "AUTO_APPROVAL_READ_HOST")
                case "path": String(localized: "AUTO_APPROVAL_READ_PATH")
                case "status": String(localized: "AUTO_APPROVAL_READ_STATUS")
                default: field
            }
        }
        var values = metadata + read.headers.map { String(localized: "AUTO_APPROVAL_HEADER_PREFIX") + $0 }
            + read.queryKeys.map { String(localized: "AUTO_APPROVAL_QUERY_PREFIX") + $0 }
        if read.body == .json {
            values.append(String(localized: "AUTO_JSON_BODY"))
        }
        return values
    }

    var body: some View {
        NavigationStack {
            Form {
                Section { Text(verbatim: package.manifest.name) } footer: { Text("AUTO_ALERT_CONNECTION") }
                ScriptTargetsSection(manifest: package.manifest)
                Section {
                    LabeledContent("AUTO_APPROVAL_REQUEST_JSON") {
                        Text(LocalizedStringKey(package.manifest.writeRequestBody ? "AUTO_APPROVAL_CAN_CHANGE" : "AUTO_APPROVAL_CANNOT_CHANGE"))
                    }
                    LabeledContent("AUTO_APPROVAL_RESPONSE_JSON") {
                        Text(LocalizedStringKey(package.manifest.writeResponseBody ? "AUTO_APPROVAL_CAN_CHANGE" : "AUTO_APPROVAL_CANNOT_CHANGE"))
                    }
                    if package.manifest.writeFiles {
                        LabeledContent("AUTO_APPROVAL_FILES") { Text("AUTO_APPROVAL_FILES_ALLOWED") }
                    }
                } footer: {
                    VStack(alignment: .leading) {
                        if package.manifest.writeFiles {
                            Text("AUTO_APPROVAL_FILES_FOOTER")
                        }
                        if package.manifest.outbound.isEmpty {
                            Text("AUTO_ALERT_WEBHOOK")
                        }
                    }
                }
                Section {
                    if fields.isEmpty {
                        Text("AUTO_READ_NONE")
                    }
                    ForEach(Array(fields.enumerated()), id: \.offset) { index, field in
                        HashText(value: field, identifier: "plugins.approval.read.\(index)")
                    }
                } header: { Text("AUTO_APPROVAL_READ_DATA") }
                if !package.manifest.outbound.isEmpty {
                    Section {
                        ForEach(package.manifest.outbound.keys.sorted(), id: \.self) { binding in
                            if let endpoint = package.manifest.outbound[binding] {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(verbatim: binding).font(.headline)
                                    Text(verbatim: "GET " + endpoint.url).font(.footnote).textSelection(.enabled)
                                    LabeledContent("AUTO_APPROVAL_OUTBOUND_HEADERS") {
                                        if endpoint.headers.isEmpty {
                                            Text("AUTO_READ_NONE")
                                        } else {
                                            Text(verbatim: endpoint.headers.joined(separator: ", "))
                                        }
                                    }.font(.footnote)
                                }
                                .accessibilityIdentifier("plugins.approval.outbound.\(binding)")
                            }
                        }
                    } header: { Text("AUTO_APPROVAL_OUTBOUND") }
                        footer: { Text("AUTO_APPROVAL_OUTBOUND_FOOTER") }
                }
                Section {
                    HashText(value: package.revision, identifier: "plugins.approval.revision")
                } header: { Text("AUTO_ALERT_REVISION") }
            }
            .navigationTitle("AUTO_APPROVAL_REVIEW")
            .navigationBarTitleDisplayMode(.inline)
            .accessibilityIdentifier("plugins.approval.form")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("AUTO_BROWSER_CANCEL", role: .cancel, action: onCancel)
                        .disabled(isBusy).accessibilityIdentifier("plugins.approval.cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(confirmTitle, action: onConfirm)
                        .disabled(isBusy).accessibilityIdentifier("plugins.approval.confirm")
                }
            }
        }
        .interactiveDismissDisabled(isBusy)
        .tint(PluginBrowserColor.accent)
    }
}
