# App Review Notes — draft

App: Interceptor (6749347474)
Prepared: 2026-10-04
Replacement build/version: not yet selected

Draft updated: 2026-10-06. The mandatory startup consent flow below is proposed for a replacement build and has not been submitted. Uploaded build 30 retains its previous consent flow. Historical testing evidence below does not verify this new flow. The local English and Japanese App Store description drafts have been updated to match; they have not been submitted as part of this update.

This text describes the proposed replacement build. Do not submit it as a statement of completed or verified changes until the release archive and the physical-device flow below have been checked.

## Purpose and network architecture

Interceptor is a local network inspection tool for selected Nintendo-related hosts. Its packet tunnel configures an HTTPS proxy on 127.0.0.1:6836 on the same device; it does not connect to a developer-operated remote VPN server. The proxy inspects selected HTTPS traffic using a certificate authority generated locally. The user must explicitly install the certificate profile and enable trust in iOS Settings.

Captured records may include headers, cookies, authentication tokens, account identifiers, and request/response bodies. These are used to display traffic and supported service tokens to the user. The revised in-app notice explains this before certificate setup or capture and requires explicit consent. The previous statement that the app collects or transmits no data should not be used: the app processes local traffic, and requests continue to their original Nintendo services.

The proposed replacement removes Firebase, Firebase App Check, Firebase Messaging, remote push registration, and tracking permission requests. It disables iCloud Keychain synchronization for new certificates, private keys, and tokens. It does not erase previous cloud copies. Optional notifications are generated locally and contain no captured headers, bodies, cookies, or tokens. Capture results are read from local app storage rather than from notification payloads.

Captured data is not uploaded to developer-operated servers, sold, used for advertising, or automatically shared with third parties by Interceptor. Normal requests to Nintendo, user-initiated copying, older cloud copies, and OS backups are separate flows explained in the policy. Revoking consent stops the VPN, disables automatic reconnection and clears capture notifications, and immediately returns to the required startup consent view. It does not erase saved records, tokens, certificates, or private keys, or uninstall a certificate profile.

## Proposed review steps (confirm exact labels in the archive)

1. Launch the replacement app on a physical iPhone or iPad without consent to the current notice version. A full-screen Data Use and Consent view appears above the main interface. Review the explanation. Confirm swiping or otherwise attempting to dismiss it cannot reveal Home or Settings, and relaunching does not bypass it. The only consent choice is Agree; without agreement the main interface remains unavailable.
2. Choose Agree. Confirm the view closes and the main interface becomes accessible. Agreement must not start capture, install or trust a certificate, install a VPN configuration, or request notification permission. Complete any separate introductory screens shown after agreement.
3. Open Settings → Privacy to read the data-use notice again without changing consent. Confirm Settings no longer contains the former Data Use consent section.
4. Open Settings → Set Up Capture and follow the app's instructions to obtain the locally generated certificate. In iOS Settings, install the downloaded profile and enable full trust for this certificate under General → About → Certificate Trust Settings. Continue setup to Install VPN Configuration and approve the iOS VPN configuration prompt if shown. The configuration must be registered before capture can start.
5. Return to Settings and turn on Connection Status. The VPN indicator represents the local packet tunnel. Open SSL Proxying List to see configured hosts.
6. With an authorized Nintendo account and the relevant Nintendo app/service, perform a supported request. Return to Home, open its host, and inspect the request/response record. Settings → Token List displays supported saved tokens when such traffic was captured. Nintendo credentials are entered in Nintendo's own interface, not submitted to Interceptor's developer.
7. If desired, enable Capture Notifications in Settings and approve the iOS permission prompt. Capture another supported record. Confirm the notification is generic and opening it reads the result from local storage. Denying notifications must not prevent capture or access to locally saved results.
8. Open Settings → Privacy → Withdraw Consent and confirm withdrawal. Confirm the VPN stops, Auto Connect and Capture Notifications are disabled, and the required consent view appears again. Foregrounding, relaunching, and attempts to dismiss the view must not bypass consent or restart capture. Agree again to access the main interface; confirm agreement alone does not re-enable capture or notifications. Existing records, tokens, and certificate/key material remain stored. Clear request history using Home's trash/Clear action after agreement.
9. After testing, disable the VPN configuration and remove the installed certificate profile in iOS Settings → General → VPN & Device Management. Confirm certificate trust is no longer enabled. Consent withdrawal alone does not remove this profile.

The required agreement concerns the app's core traffic-inspection data use. Notification permission, certificate installation/trust, and VPN configuration approval remain separate choices. Apple's guideline 5.1.1(iv) restricts requiring unnecessary data access; this draft does not establish that the proposed startup gate satisfies App Review requirements.

We are awaiting Apple's clarification about whether the proposed certificate/packet-tunnel design is acceptable and whether additional MDM-related permission is required. This draft does not assert that MDM privileges are granted or unnecessary.

## Evidence to add before submission

Historical preparation snapshot (2026-10-04; build upload status in this paragraph is as recorded then):

On 2026-10-04, the physical VPN lifecycle test passed on iPad Air 13-inch (M3), iPadOS 26.3.1: tunnel start, an anonymous HTTPS probe to a configured Nintendo host recorded in local history, stop/restart, consent withdrawal, and an independent Not Connected check in iPadOS Settings. See [the public-request screenshot](evidence/physical-vpn-https-probe.png). On M2 (iPadOS 18.6.2), the user completed fresh certificate installation/trust and Nintendo sign-in; both physical tests passed at 14:30 and 14:33 JST. Nintendo capture checked the bullet-token request in history and the host in Token List, without exposing or comparing raw token values. Profile removal was not exercised. Build 29 was uploaded but has not been selected for review. Build 30 contains the revised consent settings UI and has not been uploaded.

- Replacement build number, version, supported device/OS, and completed archive checks.
- Verify the labels Data Use, Agree, Privacy, Withdraw Consent, Set Up Capture, and Capture Notifications in the replacement archive; add English and Japanese screenshots before capture. Verify that no decline/dismiss action exposes the main interface.
- Physical-device proof of required startup consent, blocked dismissal, current-notice-version handling, revocation, restart prevention, and supported HTTPS capture. Verify notification denial remains independent of capture consent.
- A synthetic/redacted demonstration video or reviewer attachment. Never attach live account cookies, private keys, or authentication tokens.
- A verified reviewer test path and any account/access requirement. No working Nintendo test account or capture fixture is provided by this draft.
- The public app-specific policy and support URL are reachable. App Store Connect now has the app-specific URL in both languages and Data Not Collected for the revised release. The old selected binary still raises an ATT-string warning; select the new binary. Apple's clarification remains pending.
