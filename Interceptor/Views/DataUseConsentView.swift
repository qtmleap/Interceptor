import Mudmouth
import SwiftUI

/// Shared disclosure for the initial gate and Settings; only the contextual action differs.
struct DataUseDetailsView: View {
    @EnvironmentObject private var client: Tuberose
    @State private var confirmWithdrawal = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    var showsWithdrawal = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                introduction
                disclosure("Apple Policy Disclaimer", "CONSENT_APPLE_DISCLAIMER", symbol: "info.circle")
                disclosure("Purpose", "CONSENT_PURPOSE", symbol: "network")
                disclosure("Data Recorded", "CONSENT_DATA", symbol: "doc.text.magnifyingglass", emphasized: true)
                disclosure("Storage and Sharing", "CONSENT_STORAGE", symbol: "internaldrive")
                disclosure("Certificate and VPN", "CONSENT_CERTIFICATE", symbol: "key.horizontal")
                disclosure("Your Choices", "CONSENT_CHOICES", symbol: "slider.horizontal.3")
            }
            .frame(maxWidth: 620, alignment: .leading)
            .padding(.horizontal, 24)
            .padding(.vertical, 20)
            .frame(maxWidth: .infinity)
        }
        .accessibilityIdentifier("consent.disclosure")
        .background {
            Color(uiColor: .systemGroupedBackground).ignoresSafeArea()
        }
        .navigationTitle("Data Use & Consent")
        .navigationBarTitleDisplayMode(.inline)
        .tint(.indigo)
        .toolbar {
            if showsWithdrawal {
                if #available(iOS 26, *) {
                    ToolbarItem(placement: .topBarTrailing) {
                        withdrawalButton
                    }
                    .sharedBackgroundVisibility(.hidden)
                } else {
                    ToolbarItem(placement: .topBarTrailing) {
                        withdrawalButton
                    }
                }
            }
        }
        .alert("Withdraw Consent?", isPresented: $confirmWithdrawal) {
            Button("Withdraw Consent", role: .destructive) {
                client.withdrawCaptureConsent()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("CONSENT_WITHDRAW_CONFIRMATION")
        }
    }

    private var withdrawalButton: some View {
        Button(role: .destructive) {
            confirmWithdrawal = true
        } label: {
            Text("Disagree")
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("consent.withdraw")
    }

    private var introduction: some View {
        VStack(alignment: .leading, spacing: 16) {
            Image(systemName: "network")
                .font(.system(size: 34, weight: .medium))
                .foregroundStyle(.indigo)
                .frame(width: 64, height: 64)
                .background(.indigo.opacity(0.10), in: RoundedRectangle(cornerRadius: 20))
                .accessibilityHidden(true)
            Text("CONSENT_INTRODUCTION")
                .font(.subheadline).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.bottom, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func disclosure(_ title: LocalizedStringKey, _ body: LocalizedStringKey,
                            symbol: String, emphasized: Bool = false) -> some View
    {
        VStack(alignment: .leading, spacing: 14) {
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
            Text(body).font(.body).fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            Color(uiColor: .secondarySystemGroupedBackground)
                .clipShape(RoundedRectangle(cornerRadius: 24))
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
    var onAgree: () -> Void = {}

    var body: some View {
        DataUseDetailsView()
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
