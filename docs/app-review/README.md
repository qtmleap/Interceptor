# App Review preparation — draft, 2026-10-04

These files prepare a replacement submission for App Store app 6749347474. Build 29 has not been uploaded, submitted, or approved. Build 28's rejection and the reply sent on 2026-10-04 do not establish acceptance of the proposed changes.

The description, promotional text, and keywords under `fastlane/metadata/en-US` and `fastlane/metadata/ja` were saved in App Store Connect on 2026-10-04. They have not been released. Their intended behavior must match the final archive. The current Fastfile uploads TestFlight builds, not these metadata files; this directory does not add an automatic publishing step.

`review-notes-draft.md` describes the review flow and evidence still required. `privacy-policy-draft.md` contains the policy source text. The app-specific policy is now public on qleap.jp, with its existing public support page as the contact route. The app links to it; the App Store Connect policy URL and App Privacy answers still need reconciliation before submission.

## Checks before using the drafts

- Verify explicit consent appears before certificate setup and every capture-start route; decline, revoke, automatic restart, relaunch, and existing-install upgrade must respect it.
- Verify Firebase, App Check, Messaging, remote notification registration, and tracking prompts are absent from the shipped archive, not merely unused at runtime.
- Verify new token, certificate, and private-key writes are not synchronizable. Do not promise that existing cloud copies are erased or that OS backups exclude these items without testing their actual accessibility and backup attributes.
- Verify optional local notifications contain no cookies, authentication tokens, captured headers, or bodies, including userInfo. Captured data must be read from local storage, including after relaunch, without relying on a notification tap.
- Confirm capture-domain/path matching and the displayed SSL Proxying List match actual routing. Do not describe this as general-purpose or all-device-traffic capture.
- Verify Home's Clear action deletes stored request history. Token/Keychain deletion is a separate concern; do not imply it is included in Clear or consent withdrawal.
- Verify the certificate profile and VPN configuration can be removed through the documented iOS settings. Do not claim the app removes them automatically.
- Use a physical-device capture test and a review demonstration with synthetic or redacted data. Simulator UI tests alone do not prove real-device VPN and certificate behavior.
- Confirm the App Privacy answers, purpose strings, screenshots, support URL, public policy URL, and archive match the revised behavior. The drafts do not predetermine Apple's privacy classification or approval.

## References checked

- [Apple's platform version information](https://developer.apple.com/help/app-store-connect/reference/app-information/platform-version-information): field formats and limits.
- [Apple's App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/): review requirements. The previously reported rejection identifier is historical; use Apple's exact current response rather than assuming its numbering or that these changes resolve it.

These files do not automatically send reviewer messages or publish externally.

## Verified build preparation (2026-10-04)

Primary physical test device: iPad Air 11-inch (M2), named iPad Air M2, iPadOS 18.6.2. The user selected it because the M3 is shared with other app development. Use M2 for subsequent device operations; the historical M3 results below remain evidence of those completed runs. The initial Xcode unlock gate cleared, and the consent UI test passed on M2 at 13:32 JST (17.672 seconds, zero failures). The existing certificate was trusted, but the setup wizard did not recognize it as the current app certificate; a fresh certificate was downloaded, and native installation reached the device passcode gate. Certificate installation and M2 Nintendo capture verification remain pending. Tailscale was switched off in iPadOS VPN settings at 14:09 JST; the selected Tailscale configuration reported Not Connected with its switch value zero. The user explicitly requested that it remain off after testing. The local diagnostic result is `/tmp/interceptor-m2-tailscale-off.xcresult`; system-settings images contain private account details and are not committed.

Build 29 passes signed Simulator unit/UI tests; a development-signed Release archive and App Store-signed IPA export succeeded. Both the app and packet-tunnel extension contain a privacy manifest declaring local/App Group UserDefaults use (Apple reasons CA92.1 and 1C8F.1). The archive has no Firebase bundles, GoogleService-Info.plist, APNs entitlement, or tracking-purpose string. These checks do not replace physical-device VPN/certificate testing or Apple's review.

Mudmouth CI now builds for iOS Simulator instead of attempting to compile UIKit for macOS. Lint tool versions are fixed, and only 16 existing force-try findings are recorded in its baseline; new findings remain checked. The retired runner and nonexistent package.json release check were replaced with package metadata validation. The unavailable external AI review is manual; an independent code review was performed for these changes.

The consent lifecycle UI test passed on a connected iPad Air 13-inch (M3), iPadOS 26.3.1, on 2026-10-04. It checks decline, consent, withdrawal, disabled capture controls, and relaunch. The test supports iPad's top tab buttons and preserves consent screenshots in the test result.

The physical-device VPN lifecycle test also passed on this device at 13:17 JST (45.539 seconds, zero failures). Initially, the VPN configuration was missing and the app displayed its setup error. After registering it through Set Up Capture, the test started the tunnel, sent an anonymous HTTPS GET with a unique probe path to `api.lp1.av5ja.srv.nintendo.net`, received an HTTP response, and verified that exact path in the captured history. It then stopped and restarted the tunnel, withdrew consent, and independently confirmed iPadOS reported Not Connected. The device is left with consent withdrawn and the VPN stopped; its installed certificate and VPN configuration remain. The existing installed certificate was recognized and trusted; fresh profile installation/removal and Nintendo account/token capture were not exercised.

The reusable `testPhysicalVPNLifecycle` requires a physical device with the matching certificate installed/trusted and the Interceptor VPN configuration registered. It skips on Simulator. The verified device's system Settings UI was English. The captured public-request screenshot is saved in [evidence/physical-vpn-https-probe.png](evidence/physical-vpn-https-probe.png); it contains no account cookies or authentication tokens. The complete local result bundle is `/tmp/interceptor-ipad-vpn-final.xcresult`.

Before switching devices, `testPhysicalNintendoCapture` passed on M3 at 13:27 JST (27.504 seconds, zero failures). It enabled capture, launched the logged-in Nintendo Switch App 3.5.0, opened its SplatNet 3 cell, returned to Interceptor, and verified the Splatoon 3 host appeared in Token List without opening live token details. It withdrew consent afterward. This verifies the visible token-list integration; it does not compare a new token against a previously saved token. Nintendo screenshots containing friends/account information are private local diagnostics and are not included in this repository or review attachments. The local result bundle is `/tmp/interceptor-nintendo-splatnet3.xcresult`.

Published app-specific policy URL: https://qleap.jp/term/interceptor_privacy_policy. Public support: https://qleap.jp/support. Confirm App Store legal developer details, App Privacy answers, review screenshots/video, fresh certificate setup, and the Nintendo account/token test path before submitting.

The physical test switch selector now supports iPadOS 18, which exposes the actual UISwitch beside the labeled row. The Nintendo test also requires the `/api/bullet_tokens` request in captured history; this stronger assertion has not yet passed on M2, whose certificate/VPN setup is pending.

After the test selector changes, the simulator build and consent lifecycle test passed at 14:12 JST (zero failures; the two physical-only tests were skipped as intended). Result: `/tmp/interceptor-m2-test-selector-simulator.xcresult`.
