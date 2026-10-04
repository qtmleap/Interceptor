# App Review preparation — draft, 2026-10-04

These files prepare a replacement submission for App Store app 6749347474. They have not been uploaded, submitted, or approved. Build 28's rejection and the reply sent on 2026-10-04 do not establish acceptance of the proposed changes.

The locale files under `fastlane/metadata/en-US` and `fastlane/metadata/ja` contain proposed store text. Their intended behavior must match the final archive before they are published. The current Fastfile uploads TestFlight builds, not these metadata files; this directory does not add an automatic publishing step.

`review-notes-draft.md` describes the review flow and evidence still required. `privacy-policy-draft.md` contains app-specific English and Japanese policy text. Resolve its developer contact, public policy URL, and effective date before publication, and connect the app's Privacy Policy entry to that policy. Keep the draft status notice out of final public copy only after the implementation is verified.

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

No new reviewer message or external publication is performed by these files.
