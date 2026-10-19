import AutomationCore
import SwiftUI

/// Publisher-supplied text is shown as written; absence is explicit and nothing here is verified.
struct ScriptMetadataSection: View {
    let manifest: PluginManifest

    var body: some View {
        Section {
            LabeledContent("AUTO_NAME") { Text(verbatim: manifest.name) }
            LabeledContent("AUTO_VERSION") { Text(verbatim: manifest.version) }
            optional("AUTO_AUTHOR", manifest.author, id: "script.author")
            optional("AUTO_SUMMARY", manifest.summary, id: "script.summary")
        } header: { Text("AUTO_METADATA") } footer: { Text("AUTO_METADATA_FOOTER") }
    }

    private func optional(_ title: LocalizedStringKey, _ value: String?, id: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.footnote).foregroundStyle(.secondary)
            if let value {
                Text(verbatim: value).textSelection(.enabled)
            } else {
                Text("AUTO_NOT_PROVIDED").foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(id)
    }
}

/// Declared subscriptions: phase, hosts, path semantics and optional method/status qualifiers.
struct ScriptTargetsSection: View {
    let manifest: PluginManifest

    var body: some View {
        Section {
            ForEach(Array(targets.enumerated()), id: \.offset) { index, sub in
                VStack(alignment: .leading, spacing: 6) {
                    if let phase = sub.phase {
                        row("AUTO_TARGET_PHASE", phase)
                    }
                    if let file = sub.file {
                        row("AUTO_SOURCE", file)
                    }
                    row("AUTO_TARGET_HOSTS", sub.hosts.joined(separator: ", "))
                    switch sub.path {
                        case nil:
                            VStack(alignment: .leading, spacing: 2) {
                                Text("AUTO_TARGET_PATH").font(.footnote).foregroundStyle(.secondary)
                                Text("AUTO_PATH_ALL")
                            }
                        case let .exact(p)?: row("AUTO_PATH_EXACT", p)
                        case let .prefix(p)?: row("AUTO_PATH_PREFIX", p)
                    }
                    if let methods = sub.methods {
                        row("AUTO_TARGET_METHODS", methods.joined(separator: ", "))
                    }
                    if let status = sub.status {
                        row("AUTO_TARGET_STATUS", "\(status.lowerBound)–\(status.upperBound)")
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("script.target.\(index)")
            }
        } header: { Text("AUTO_TARGETS") } footer: { Text("AUTO_TARGETS_FOOTER") }
            .accessibilityIdentifier("script.targets")
    }

    private struct Target {
        let phase: String?
        let file: String?
        let hosts: [String]
        let methods: [String]?
        let path: PluginSubscription.PathMatch?
        let status: ClosedRange<Int>?
    }

    private var targets: [Target] {
        if manifest.schemaVersion == 2 {
            return manifest.matches.flatMap { match in
                match.hooks.keys.sorted().map { phase in
                    Target(phase: phase, file: match.hooks[phase], hosts: match.hosts, methods: match.methods,
                           path: match.path, status: match.status)
                }
            }
        }
        return manifest.subscriptions.map { Target(phase: $0.phase.rawValue, file: nil, hosts: $0.hosts, methods: $0.methods, path: $0.path, status: $0.status) }
    }

    private func row(_ title: LocalizedStringKey, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.footnote).foregroundStyle(.secondary)
            Text(verbatim: value).font(.system(.footnote, design: .monospaced)).textSelection(.enabled)
        }
    }
}
