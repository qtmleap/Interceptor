import SwiftUI
import UIKit

/// Shared browser colors follow the selected Sileo reference in both appearances.
enum PluginBrowserColor {
    static let accent = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 85 / 255, green: 172 / 255, blue: 185 / 255, alpha: 1)
            : UIColor(red: 47 / 255, green: 143 / 255, blue: 157 / 255, alpha: 1)
    })
}

/// Label content only. The caller supplies NavigationLink, row insets and swipe actions.
struct PluginPackageRow: View {
    let name: String
    let author: String?
    let version: String
    let summary: String
    var systemImage = "shippingbox"
    var iconColor = PluginBrowserColor.accent
    var isInstalled = false
    var accessibilityPrefix = "plugins.package"

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            PluginBrowserIcon(systemImage: systemImage, color: iconColor, isInstalled: isInstalled)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: name)
                    .font(.body.weight(.semibold))
                    .accessibilityIdentifier(accessibilityPrefix + ".name")
                Text(verbatim: metadata)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier(accessibilityPrefix + ".metadata")
                if !summary.isEmpty {
                    Text(verbatim: summary)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier(accessibilityPrefix + ".summary")
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minHeight: 44, alignment: .top)
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityValue(isInstalled ? Text("AUTO_BROWSER_INSTALLED") : Text(""))
    }

    private var metadata: String {
        guard let author, !author.isEmpty else {
            return version
        }
        return author + " · " + version
    }
}

/// Repository label content; its count describes package families, never revisions.
struct PluginRepositoryRow: View {
    let name: String
    let url: String
    let packageCount: Int
    var systemImage = "folder"
    var iconColor = PluginBrowserColor.accent
    var accessibilityPrefix = "plugins.source"

    var body: some View {
        HStack(spacing: 14) {
            PluginBrowserIcon(systemImage: systemImage, color: iconColor)
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: name)
                    .font(.body.weight(.semibold))
                    .accessibilityIdentifier(accessibilityPrefix + ".name")
                Text(verbatim: url)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier(accessibilityPrefix + ".url")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(packageCount, format: .number)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .accessibilityLabel(Text("AUTO_BROWSER_PACKAGE_COUNT \(packageCount)"))
                .accessibilityIdentifier(accessibilityPrefix + ".count")
        }
        .frame(minHeight: 44)
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

/// The caller routes Reinstall through the queue and Delete through its confirmation.
struct PluginPackageModifyActions {
    let onReinstall: () -> Void
    let onDelete: () -> Void
}

/// Hosts must come from every declared match of the fetched package.
/// Loading/error presentation belongs to the caller, before this ready-state hero.
struct PluginPackageHero: View {
    let name: String
    let targetHosts: [String]
    var systemImage = "shippingbox"
    var iconColor = PluginBrowserColor.accent
    var actionTitle: LocalizedStringKey?
    var isActionEnabled = true
    var isWorking = false
    var modifyActions: PluginPackageModifyActions? = nil
    var action: () -> Void = {}
    @State private var showModify = false

    @Environment(\.horizontalSizeClass)
    private var horizontalSizeClass

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 14) {
                PluginBrowserIcon(
                    systemImage: systemImage,
                    color: iconColor,
                    size: horizontalSizeClass == .compact ? 56 : 60,
                )
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: name)
                        .font(.title2.bold())
                        .accessibilityAddTraits(.isHeader)
                        .accessibilityIdentifier("plugins.package.hero.name")
                    if !targetHosts.isEmpty {
                        Text("AUTO_BROWSER_TARGET_HOSTS")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(Array(targetHosts.enumerated()), id: \.offset) { _, host in
                        Text(verbatim: host)
                            .font(.subheadline.weight(.semibold))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("plugins.package.hero")
            if let actionTitle {
                HStack {
                    Spacer(minLength: 0)
                    Button {
                        if modifyActions != nil {
                            showModify = true
                        } else {
                            action()
                        }
                    } label: {
                        HStack(spacing: 8) {
                            if isWorking {
                                ProgressView().tint(.white).accessibilityHidden(true)
                            }
                            Text(actionTitle).font(.subheadline.weight(.semibold))
                        }
                        .padding(.horizontal, 18)
                        .padding(.vertical, 6)
                        .foregroundStyle(.white)
                        .background(PluginBrowserColor.accent, in: Capsule())
                        .opacity(isActionEnabled && !isWorking ? 1 : 0.5)
                    }
                    .buttonStyle(.plain)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                    .disabled(!isActionEnabled || isWorking)
                    .accessibilityIdentifier("plugins.package.hero.action")
                    .confirmationDialog(Text(verbatim: name), isPresented: $showModify, titleVisibility: .hidden) {
                        Button("AUTO_BROWSER_REINSTALL") { modifyActions?.onReinstall() }
                            .disabled(!isActionEnabled || isWorking)
                            .accessibilityIdentifier("plugins.modify.reinstall")
                        Button("AUTO_BROWSER_DELETE", role: .destructive) { modifyActions?.onDelete() }
                            .disabled(!isActionEnabled || isWorking)
                            .accessibilityIdentifier("plugins.modify.delete")
                        Button("AUTO_BROWSER_CANCEL", role: .cancel) {}
                            .accessibilityIdentifier("plugins.modify.cancel")
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .systemBackground))
        .tint(PluginBrowserColor.accent)
    }
}

/// Place in the browser's bottom safe-area inset, above the phone tab bar.
struct PluginInstallQueueBar: View {
    let count: Int
    var isBusy = false
    let action: () -> Void

    var body: some View {
        if count >= 1 {
            Button(action: action) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("AUTO_BROWSER_QUEUED").font(.subheadline).foregroundStyle(.secondary)
                        Text("AUTO_BROWSER_PACKAGE_COUNT \(count)").font(.headline)
                    }
                    Spacer(minLength: 16)
                    if isBusy {
                        ProgressView()
                    } else {
                        Image(systemName: "chevron.up").font(.headline).foregroundStyle(PluginBrowserColor.accent)
                    }
                }
                .padding(.horizontal, 16)
                .frame(minHeight: 64)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isBusy)
            .background(Color(uiColor: .systemBackground))
            .overlay(alignment: .top) { Divider() }
            .accessibilityIdentifier("plugins.queue.open")
        }
    }
}

/// Presentation values only. Identity, candidate bytes, validation and queue lifetime belong to the controller.
struct PluginInstallQueueDisplayEntry: Identifiable {
    let id: String
    let name: String
    let version: String
    var detail: LocalizedStringKey = "AUTO_BROWSER_QUEUE_WAITING"
    var isValid = true
    var systemImage = "shippingbox"
    var iconColor = PluginBrowserColor.accent
}

/// Sheet content only; the caller presents the sheet and controls its detents.
/// canConfirm reflects controller validation; this view additionally rejects empty or visibly invalid entries.
struct PluginInstallSheetContent: View {
    let entries: [PluginInstallQueueDisplayEntry]
    let isBusy: Bool
    let canConfirm: Bool
    var status: LocalizedStringKey?
    var errorMessage: String?
    let onRemove: (String) -> Void
    let onClear: () -> Void
    let onConfirm: () -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Button(role: .cancel, action: onClose) {
                Image(systemName: "chevron.down")
                    .font(.title3.weight(.heavy))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isBusy)
            .keyboardShortcut(.cancelAction)
            .accessibilityLabel(Text("AUTO_BROWSER_CLOSE"))
            .accessibilityIdentifier("plugins.queue.close")
            Text("AUTO_BROWSER_INSTALL")
                .font(.title2.bold())
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 14)
                .accessibilityAddTraits(.isHeader)
            Divider().padding(.horizontal, 16)
            ScrollView {
                LazyVStack(spacing: 0) {
                    if entries.isEmpty {
                        Text("AUTO_BROWSER_QUEUE_EMPTY")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 20)
                            .accessibilityIdentifier("plugins.queue.empty")
                    }
                    ForEach(entries) { entry in
                        queueRow(entry)
                        if entry.id != entries.last?.id {
                            Divider()
                        }
                    }
                }
                .padding(.horizontal, 16)
            }
            .accessibilityIdentifier("plugins.queue.items")
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { footer }
        .background(Color(uiColor: .systemBackground))
        .tint(PluginBrowserColor.accent)
        .interactiveDismissDisabled(isBusy)
        .presentationDragIndicator(.hidden)
    }

    private var confirmationEnabled: Bool {
        !isBusy && canConfirm && !entries.isEmpty && entries.allSatisfy(\.isValid)
    }

    private func queueRow(_ entry: PluginInstallQueueDisplayEntry) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Button(role: .destructive) { onRemove(entry.id) } label: {
                Image(systemName: "minus.circle.fill")
                    .font(.title2)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(AutomationStatusColor.error)
            .disabled(isBusy)
            .accessibilityLabel(Text("AUTO_BROWSER_QUEUE_REMOVE \(entry.name)"))
            .accessibilityIdentifier("plugins.queue.remove." + entry.id)
            PluginBrowserIcon(systemImage: entry.systemImage, color: entry.iconColor)
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: entry.name).font(.body.weight(.semibold))
                (Text(verbatim: entry.version) + Text(" · ") + Text(isBusy ? LocalizedStringKey("AUTO_BROWSER_INSTALLING") : entry.detail))
                    .font(.subheadline)
                    .foregroundStyle(entry.isValid ? Color.secondary : AutomationStatusColor.error)
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("plugins.queue.entry." + entry.id)
        }
        .padding(.vertical, 12)
    }

    private var footer: some View {
        VStack(spacing: 10) {
            if let errorMessage, !errorMessage.isEmpty {
                Text(verbatim: errorMessage)
                    .font(.subheadline)
                    .foregroundStyle(AutomationStatusColor.error)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("plugins.queue.error")
            } else if let status {
                Text(status)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("plugins.queue.status")
            }
            Button(action: onConfirm) {
                HStack(spacing: 8) {
                    if isBusy {
                        ProgressView().accessibilityHidden(true)
                    }
                    Text(isBusy ? LocalizedStringKey("AUTO_BROWSER_INSTALLING") : LocalizedStringKey("AUTO_BROWSER_CONFIRM"))
                }
                .font(.headline)
                .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!confirmationEnabled)
            .accessibilityIdentifier("plugins.queue.confirm")
            if !entries.isEmpty {
                Button(action: onClear) {
                    Text("AUTO_BROWSER_QUEUE_CLEAR")
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .font(.headline)
                .disabled(isBusy)
                .accessibilityIdentifier("plugins.queue.clear")
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .background(Color(uiColor: .systemBackground))
    }
}

private struct PluginBrowserIcon: View {
    let systemImage: String
    let color: Color
    var size: CGFloat = 40
    var isInstalled = false

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: size * 0.58, weight: .regular))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(color, in: RoundedRectangle(cornerRadius: size * 0.225))
            .overlay(alignment: .bottomTrailing) {
                if isInstalled {
                    Image(systemName: "checkmark")
                        .font(.system(size: 9, weight: .heavy))
                        .foregroundStyle(.white)
                        .frame(width: 14, height: 14)
                        .background(AutomationStatusColor.ok, in: Circle())
                        .offset(x: 4, y: 4)
                }
            }
            .accessibilityHidden(true)
    }
}
