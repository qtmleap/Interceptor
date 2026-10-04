## Interceptor

This is an iOS application that uses a self-signed certificate to obtain an access token from Nintendo Switch Online.

### Requirements

- iOS 17 or later
- Xcode with Swift 6.1 or later (required by Mudmouth)
- fastlane

The simulator build was verified with Xcode 27.0 on 2026-10-04 using
`swift-crypto` 3.15.1 and Runestone 0.5.2. Keep the checked-in `Package.resolved`
to use these compatible dependency versions.

### Local development

Dependencies are not bundled. Xcode downloads remote Swift packages, and the
project expects a local Mudmouth checkout beside Interceptor:

```text
development-directory/
  Interceptor/
  Mudmouth/
```

From the Interceptor directory, clone Mudmouth if it does not already exist:

```bash
git clone https://github.com/qtmleap/Mudmouth.git ../Mudmouth
git -C ../Mudmouth checkout ddcefe656c0f27289ee4f506f2112b8bbdaa407d
xcodebuild -resolvePackageDependencies -project Interceptor.xcodeproj -scheme Interceptor
open Interceptor.xcodeproj
```

The revision above is the Mudmouth revision selected for the local setup on
2026-10-04. Keep the checkout on its development branch when editing Mudmouth;
record any dependency revision changes alongside the application changes.

To check simulator compilation without signing:

```bash
xcodebuild build -project Interceptor.xcodeproj -scheme Interceptor -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO
```

This is a compile-only check. To run the app in Simulator, keep signing enabled
so the app's App Group entitlement is embedded; the unsigned build crashes when
opening the shared model container. Select a simulator in Xcode and run normally,
or use the following command with its UUID:

```bash
xcodebuild build -project Interceptor.xcodeproj -scheme Interceptor -destination 'platform=iOS Simulator,id=SIMULATOR_UUID' CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=-
```

If another Xcode is selected globally, prefix the command with
`DEVELOPER_DIR=/Applications/Xcode-27.0.0.app/Contents/Developer` to use the
verified installation without changing the system selection. For unattended
public-package downloads that wait on Keychain authorization, add
`-packageAuthorizationProvider netrc` to the xcodebuild command.

On first use, approve the package build plugins in Xcode when prompted. For
unattended builds of these pinned dependencies, CI supplies
`-skipPackagePluginValidation` to avoid the interactive approval step.

The current test targets require an iOS 18.5 or later simulator. Testing the VPN
and traffic capture requires an iOS device and signing configured for the app
and PacketTunnel extension.

### Simulator smoke test

`InterceptorUITests/testSimulatorOnboardingAndNavigation` checks onboarding,
navigation, Auto Connect, history clearing, and relaunch. Run it on a dedicated
simulator because it clears the app's history:

```bash
xcodebuild test -project Interceptor.xcodeproj -scheme Interceptor -destination 'platform=iOS Simulator,id=SIMULATOR_UUID' -parallel-testing-enabled NO -only-testing:InterceptorUITests/InterceptorUITests/testSimulatorOnboardingAndNavigation CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=-
```

Verified on an iPhone 17 Pro simulator with iOS 26.5 and Xcode 27.0 on 2026-10-04.
The test uses English UI labels. VPN traffic capture and real Nintendo tokens
remain device-only checks.

### Continuous integration

GitHub Actions runs the simulator build and the complete unit/UI test suite on
pull requests to `master` and pushes to `master`. It checks out the pinned
Mudmouth revision beside Interceptor, honors `Package.resolved`, and creates a
fresh iPhone simulator for each run. Test results and logs are retained for
seven days in the `simulator-results` artifact.

The workflow uses GitHub's [`xcode-27` preview runner](https://github.com/actions/runner-images/issues/14404).
The local Xcode 27.0 / iOS 26.5 validation and the hosted runner's selected
Xcode/runtime are recorded separately in their build logs.

## Contributors

- [zhxie](https://github.com/zhxie)
- [ultemica](https://github.com/ultemica)

## License

Interceptor is licensed under [the MIT License](/LICENSE).
