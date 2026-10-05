import Mudmouth
import SwiftUI

/// Shared disclosure; the Privacy page also provides an explicit withdrawal action.
struct DataUseDetailsView: View {
    @EnvironmentObject private var client: Tuberose
    @State private var confirmWithdrawal = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    var showsWithdrawal = false
    var usesCards = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if usesCards { introduction }
                disclosure("Purpose", "CONSENT_PURPOSE", symbol: "network")
                disclosure("Data Recorded", "CONSENT_DATA", symbol: "doc.text.magnifyingglass", emphasized: true)
                disclosure("Storage and Sharing", "CONSENT_STORAGE", symbol: "internaldrive")
                disclosure("Certificate and VPN", "CONSENT_CERTIFICATE", symbol: "key.horizontal")
                disclosure("Your Choices", "CONSENT_CHOICES", symbol: "slider.horizontal.3")
                if showsWithdrawal {
                    Button("Withdraw Consent", role: .destructive) { confirmWithdrawal = true }
                }
            }
            .frame(maxWidth: usesCards ? 620 : 640, alignment: .leading)
            .padding(.horizontal, usesCards ? 24 : 16)
            .padding(.vertical, usesCards ? 20 : 16)
            .frame(maxWidth: .infinity)
        }
        .background {
            if usesCards { Color(uiColor: .systemGroupedBackground).ignoresSafeArea() }
        }
        .navigationTitle(showsWithdrawal ? LocalizedStringKey("Privacy") : LocalizedStringKey("Data Use"))
        .navigationBarTitleDisplayMode(.inline)
        .alert("Withdraw Consent?", isPresented: $confirmWithdrawal) {
            Button("Withdraw Consent", role: .destructive) { client.withdrawCaptureConsent() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("CONSENT_WITHDRAW_CONFIRMATION")
        }
    }

    private var introduction: some View {
        VStack(alignment: .leading, spacing: 16) {
            Image(systemName: "network")
                .font(.system(size: 34, weight: .medium))
                .foregroundStyle(.indigo)
                .frame(width: 64, height: 64)
                .background(.indigo.opacity(0.10), in: RoundedRectangle(cornerRadius: 20))
                .accessibilityHidden(true)
            Text("About Data Use")
                .font(.system(.largeTitle, design: .rounded).weight(.bold))
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            Text("CONSENT_INTRODUCTION")
                .font(.subheadline).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.bottom, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func disclosure(_ title: LocalizedStringKey, _ body: LocalizedStringKey,
                            symbol: String, emphasized: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: usesCards ? 14 : 8) {
            if usesCards {
                if dynamicTypeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: 12) {
                        disclosureIcon(symbol, emphasized: emphasized)
                        Text(title).font(.headline).accessibilityAddTraits(.isHeader)
                    }
                } else {
                    HStack(spacing: 12) {
                        disclosureIcon(symbol, emphasized: emphasized)
                        Text(title).font(.headline).accessibilityAddTraits(.isHeader)
                    }
                }
            } else {
                Text(title).font(.headline).accessibilityAddTraits(.isHeader)
            }
            Text(body).font(.body).fixedSize(horizontal: false, vertical: true)
        }
        .padding(usesCards ? 20 : 0)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            if usesCards {
                Color(uiColor: .secondarySystemGroupedBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 24))
            }
        }
    }

    private func disclosureIcon(_ symbol: String, emphasized: Bool) -> some View {
        let tint: Color = emphasized ? .orange : .indigo
        return Image(systemName: symbol)
            .font(.system(size: 20, weight: .medium))
            .foregroundStyle(tint)
            .frame(width: 40, height: 40)
            .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
            .accessibilityHidden(true)
    }
}

/// Explicit consent flow, presented only for initial or renewed authorization.
struct DataUseConsentView: View {
    @EnvironmentObject private var client: Tuberose
    var onAgree: () -> Void = { }

    var body: some View {
        DataUseDetailsView(usesCards: true)
            .tint(.indigo)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Agree") {
                        client.activateOnForeground = false
                        CaptureAuthorization.grant()
                        onAgree()
                    }
                }
            }
    }
}
