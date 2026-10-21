import AutomationCore
import SwiftUI

/// File metadata only. The exact file's source remains hidden until Source Code is explicitly opened.
struct PluginFileDetailView: View {
    let package: PluginPackage
    let file: String
    @State private var showSource = false
    @State private var selection: String?

    private var name: String {
        (file as NSString).lastPathComponent
    }

    private var rules: [PluginBrowserRule] {
        PluginBrowserModel.matchingRules(in: package.manifest, file: file)
    }

    /// Hooks sharing the same traffic conditions belong to one visible target.
    private var groupedRules: [[PluginBrowserRule]] {
        rules.reduce(into: []) { groups, rule in
            if let index = groups.firstIndex(where: { group in
                guard let first = group.first else { return false }
                return first.hosts == rule.hosts && first.methods == rule.methods
                    && first.path == rule.path && first.status == rule.status
            }) {
                groups[index].append(rule)
            } else {
                groups.append([rule])
            }
        }
    }

    private var source: String {
        package.manifest.schemaVersion == 2 ? package.sourceFiles[file] ?? "" : package.source ?? ""
    }

    var body: some View {
        List {
            Section {
                ForEach(Array(groupedRules.enumerated()), id: \.offset) { index, group in
                    let rule = group[0]
                    VStack(alignment: .leading, spacing: 8) {
                        fact("AUTO_BROWSER_TARGET_HOSTS", rule.hosts.joined(separator: "\n"))
                        fact("AUTO_TARGET_METHODS", rule.methods?.joined(separator: ", ") ?? String(localized: "AUTO_RULE_ANY_METHOD"))
                        switch rule.path {
                            case let .exact(value)?: fact("AUTO_PATH_EXACT", value)
                            case let .prefix(value)?: fact("AUTO_PATH_PREFIX", value)
                            case nil: fact("AUTO_TARGET_PATH", String(localized: "AUTO_RULE_ANY_PATH"))
                        }
                        fact("AUTO_HOOK", Array(Set(group.map(\.hook))).sorted().joined(separator: "\n"))
                        if let status = rule.status {
                            fact("AUTO_TARGET_STATUS", "\(status.lowerBound)–\(status.upperBound)")
                        }
                    }
                    .accessibilityIdentifier("plugins.file.rule.\(index)")
                }
            } header: { Text("AUTO_TARGETS") }
            Section {
                Button { showSource = true } label: {
                    HStack {
                        Text("AUTO_BROWSER_SOURCE_CODE").foregroundStyle(.primary)
                        Spacer()
                        Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .accessibilityAddTraits(.isLink)
                .accessibilityIdentifier("plugins.file.openSource")
            }
        }
        .listStyle(.plain)
        .navigationTitle(Text(verbatim: name))
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("plugins.file.detail")
        .fullScreenCover(isPresented: $showSource) {
            PluginSourceReader(fileNames: [], selection: $selection, source: { _ in source },
                               sourceIdentifier: "plugins.file.source", pickerIdentifier: "plugins.file.sourcePicker",
                               closeIdentifier: "plugins.file.closeSource", title: name,
                               accentColor: PluginBrowserColor.accent) { showSource = false }
        }
    }

    private func fact(_ title: LocalizedStringKey, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.footnote).foregroundStyle(.secondary)
            Text(verbatim: value).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
        }
    }
}

struct PluginManifestJSONView: View {
    let package: PluginPackage
    let done: () -> Void
    private var json: String {
        guard let data = try? package.manifest.json.data(), let raw = String(data: data, encoding: .utf8) else { return "" }
        return JSONPrettyPrinter.format(raw, maxBytes: Limits.package, objectOnly: true)
    }

    var body: some View {
        NavigationStack {
            PluginJSONViewer(json: json, identifier: "plugins.manifest.json", fillsAvailableSpace: true)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, 16)
                .navigationTitle("AUTO_BROWSER_MANIFEST_JSON")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("AUTO_KEYBOARD_DONE", action: done).accessibilityIdentifier("plugins.manifest.close")
                    }
                }
        }
        .tint(PluginBrowserColor.accent)
    }
}
