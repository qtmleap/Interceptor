import Mudmouth
import SwiftUI
import UserNotifications

struct DataUseConsentView: View {
    @EnvironmentObject private var client: Tuberose
    @AppStorage(CaptureAuthorization.key, store: CaptureAuthorization.defaults) private var consentVersion = 0
    var onDecision: (Bool) -> Void = { _ in }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                disclosure("Purpose", "CONSENT_PURPOSE")
                disclosure("Data Recorded", "CONSENT_DATA")
                disclosure("Storage and Sharing", "CONSENT_STORAGE")
                disclosure("Certificate and VPN", "CONSENT_CERTIFICATE")
                disclosure("Your Choices", "CONSENT_CHOICES")
            }.padding()
        }
        .navigationTitle("Data Use and Consent")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 12) {
                if consentVersion == CaptureAuthorization.version {
                    Button("Withdraw Consent", role: .destructive) {
                        CaptureAuthorization.revoke()
                        client.activateOnForeground = false
                        client.stopVPNTunnel()
                        UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
                        UNUserNotificationCenter.current().removeAllDeliveredNotifications()
                        onDecision(false)
                    }.buttonStyle(.bordered)
                } else {
                    Button("Agree and Continue") {
                        client.activateOnForeground = false
                        CaptureAuthorization.grant()
                        onDecision(true)
                    }.buttonStyle(.borderedProminent)
                    Button("Not Now") {
                        CaptureAuthorization.revoke()
                        client.activateOnForeground = false
                        client.stopVPNTunnel()
                        UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
                        UNUserNotificationCenter.current().removeAllDeliveredNotifications()
                        onDecision(false)
                    }.buttonStyle(.bordered)
                }
            }.frame(maxWidth: .infinity).padding().background(.regularMaterial)
        }
    }

    private func disclosure(_ title: LocalizedStringKey, _ body: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            Text(body).font(.body).fixedSize(horizontal: false, vertical: true)
        }
    }
}
