import AutomationCore
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Settings > Plugins. Repositories and scripts; nothing here enables, captures or sends anything.
struct PluginsView: View {
    @State private var controller = AutomationController.live()
    @State private var showAddRepository = false
    @State private var showImporter = false
    @State private var pendingDelete: PendingDelete?

    private enum PendingDelete: Identifiable {
        case script(InstalledRevision), repository(RepositoryRecord)
        var id: String {
            switch self {
            case .script(let r): "s" + r.id
            case .repository(let r): "r" + r.url.canonical
            }
        }
    }

    var body: some View {
        List {
            if let error = controller.storeError {
                Section {
                    Text(LocalizedStringKey(AutomationErrorText.key(for: error))).foregroundStyle(AutomationStatusColor.error)
                    Text("AUTO_STORE_PRESERVED").font(.footnote).foregroundStyle(.secondary)
                }
                .accessibilityIdentifier("plugins.storeError")
            }
            if let error = controller.actionError {
                Section { Text(LocalizedStringKey(AutomationErrorText.key(for: error))).foregroundStyle(AutomationStatusColor.error) }
                    .accessibilityIdentifier("plugins.error")
            }
            Section {
                if controller.repositories.isEmpty { Text("AUTO_REPOSITORIES_EMPTY").foregroundStyle(.secondary) }
                ForEach(controller.repositories, id: \.url) { record in
                    NavigationLink {
                        RepositoryDetailView(model: RepositoryDetailModel(controller: controller, record: record))
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(verbatim: record.displayName)
                            TrustBadgeLabel(badge: AutomationTrustBadge(record.trust)).font(.footnote)
                        }
                    }
                    .accessibilityIdentifier("plugins.repo.\(record.displayName)")
                    .swipeActions { Button("Delete", role: .destructive) { pendingDelete = .repository(record) } }
                }
            } header: { Text("AUTO_REPOSITORIES") }
            Section {
                if controller.scripts.isEmpty { Text("AUTO_SCRIPTS_EMPTY").foregroundStyle(.secondary) }
                ForEach(controller.scripts, id: \.id) { revision in
                    NavigationLink {
                        ScriptDetailView(session: ScriptSession(controller: controller, revision: revision))
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(verbatim: revision.package.manifest.name)
                            TrustBadgeLabel(badge: AutomationTrustBadge(revision.provenance)).font(.footnote)
                        }
                    }
                    .accessibilityIdentifier("plugins.script.\(revision.package.manifest.name)")
                    .swipeActions { Button("Delete", role: .destructive) { pendingDelete = .script(revision) } }
                }
            } header: { Text("AUTO_SCRIPTS") } footer: { Text("AUTO_SCRIPTS_FOOTER") }
        }
        .navigationTitle(Text("AUTO_PLUGINS"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("AUTO_CREATE_EXAMPLE") { Task { await controller.createExample(name: String(localized: "AUTO_EXAMPLE_NAME")) } }
                        .accessibilityIdentifier("plugins.createExample")
                    Button("AUTO_IMPORT_FILE") { showImporter = true }
                        .accessibilityIdentifier("plugins.importFile")
                    Button("AUTO_ADD_REPOSITORY") { showAddRepository = true }
                        .accessibilityIdentifier("plugins.addRepository")
                } label: {
                    Label("Add", systemImage: "plus")
                }
                .disabled(controller.storeError != nil)
                .accessibilityIdentifier("plugins.add")
            }
        }
        .sheet(isPresented: $showAddRepository) { AddRepositorySheet(controller: controller) }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.json]) { result in
            guard case .success(let url) = result else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            Task { await controller.importFile(at: url); if scoped { url.stopAccessingSecurityScopedResource() } }
        }
        .confirmationDialog("AUTO_DELETE_TITLE", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                            titleVisibility: .visible, presenting: pendingDelete) { item in
            Button("Delete", role: .destructive) {
                Task {
                    switch item {
                    case .script(let r): await controller.deleteScript(id: r.id)
                    case .repository(let r): await controller.deleteRepository(r.url)
                    }
                }
            }
        } message: { item in
            switch item {
            case .script: Text("AUTO_DELETE_SCRIPT_MESSAGE")
            case .repository: Text("AUTO_DELETE_REPOSITORY_MESSAGE")
            }
        }
        .task { await controller.load() }
        .tint(Color("PluginAccent"))
    }
}

struct TrustBadgeLabel: View {
    let badge: AutomationTrustBadge
    var body: some View {
        Label(LocalizedStringKey(badge.titleKey), systemImage: badge.systemImage)
            .foregroundStyle(statusColor)
    }

    private var statusColor: Color {
        switch badge {
        case .publisherKeyVerified: AutomationStatusColor.ok
        case .unsigned, .signedKeyUnverified: AutomationStatusColor.warning
        case .localEdit, .localFile: .secondary
        }
    }
}

/// Read-only, selectable fingerprint text. Character wrapping never inserts visual hyphens.
struct HashText: UIViewRepresentable {
    let value: String

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.isEditable = false
        view.isSelectable = true
        view.isScrollEnabled = false
        view.adjustsFontForContentSizeCategory = true
        view.backgroundColor = .clear
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.textContainer.lineBreakMode = .byCharWrapping
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byCharWrapping
        paragraph.hyphenationFactor = 0
        paragraph.lineBreakStrategy = []
        let baseSize = UIFont.preferredFont(forTextStyle: .footnote,
            compatibleWith: UITraitCollection(preferredContentSizeCategory: .large)).pointSize
        let font = UIFontMetrics(forTextStyle: .footnote).scaledFont(
            for: UIFont.monospacedSystemFont(ofSize: baseSize, weight: .regular),
            compatibleWith: view.traitCollection)
        view.attributedText = NSAttributedString(string: value, attributes: [
            .font: font,
            .foregroundColor: UIColor.label,
            .paragraphStyle: paragraph,
        ])
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width.isFinite, width > 0 else { return nil }
        return uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
    }
}
