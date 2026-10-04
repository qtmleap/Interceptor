import Mudmouth
import SwiftUI

/// Shared disclosure text; reading it never changes capture authorization.
struct DataUseDetailsView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                disclosure("Purpose", "CONSENT_PURPOSE")
                disclosure("Data Recorded", "CONSENT_DATA")
                disclosure("Storage and Sharing", "CONSENT_STORAGE")
                disclosure("Certificate and VPN", "CONSENT_CERTIFICATE")
                disclosure("Your Choices", "CONSENT_CHOICES")
            }
            .frame(maxWidth: 640, alignment: .leading)
            .padding()
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Data Use")
        .navigationBarTitleDisplayMode(.inline)
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
    var onDecision: (Bool) -> Void = { _ in }

    var body: some View {
        DataUseDetailsView()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Not Now") {
                        client.withdrawCaptureConsent()
                        onDecision(false)
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Agree") {
                        client.activateOnForeground = false
                        CaptureAuthorization.grant()
                        onDecision(true)
                    }
                }
            }
    }
}
