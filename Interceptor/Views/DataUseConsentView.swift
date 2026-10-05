import Mudmouth
import SwiftUI

/// Shared disclosure; the Privacy page also provides an explicit withdrawal action.
struct DataUseDetailsView: View {
    @EnvironmentObject private var client: Tuberose
    @State private var confirmWithdrawal = false
    var showsWithdrawal = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                disclosure("Purpose", "CONSENT_PURPOSE")
                disclosure("Data Recorded", "CONSENT_DATA")
                disclosure("Storage and Sharing", "CONSENT_STORAGE")
                disclosure("Certificate and VPN", "CONSENT_CERTIFICATE")
                disclosure("Your Choices", "CONSENT_CHOICES")
                if showsWithdrawal {
                    Button("Withdraw Consent", role: .destructive) { confirmWithdrawal = true }
                }
            }
            .frame(maxWidth: 640, alignment: .leading)
            .padding()
            .frame(maxWidth: .infinity)
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

    private func disclosure(_ title: LocalizedStringKey, _ body: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            Text(body).font(.body).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Explicit consent flow, presented only for initial or renewed authorization.
struct DataUseConsentView: View {
    @EnvironmentObject private var client: Tuberose
    var onAgree: () -> Void = { }

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
