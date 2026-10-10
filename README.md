## Interceptor

### Automatic TestFlight deployment

`.github/workflows/testflight.yaml` uploads only after a genuine same-repository
pull request is merged into `develop` or `master`. A secret-free self-hosted Linux
verifier requires the exact merge SHA, trusted PR checks, first run attempt and
current branch tip. Direct pushes, tags, manual runs, reruns and obsolete merges
cannot upload. The guarded lane repeats source checks immediately before upload.

The deployment job uses `[self-hosted, macOS, ARM64, macos-27]` in a disposable VM.
It uses the protected `testflight` Environment's `TESTFLIGHT_` ASC, match password
and shared GitHub App credentials. The App issues separate Contents-read tokens
limited to `match` and `QuantumLeap`; neither token is stored in the repository.
The app and packet tunnel retain separate provisioning profiles. Signing is
read-only, builds use an immutable copy, and temporary keychain/dependency
credentials are restored after success, failure or interruption.

Both branches share one non-cancelling upload queue. The uploaded build number
exceeds the applicable remote/project/CI floor; successful uploads preserve a
`testflight-shipped-<merge SHA>` record artifact. CI never commits source changes.
See [SETUP.md](SETUP.md) for configuration, checks and upload-record handling.

Simulator PR checks remain in `.github/workflows/ios.yml`; their existing
`QUANTUMLEAP_READ_TOKEN` resolves only the private package before compilation.
Native code uses the latest stable QuantumLeap 1.0.1 at immutable revision
`4070b8707b824c3264f2cd1bb672a81aea8318a3`.

### Local development

Dependencies are not bundled. Xcode downloads remote Swift packages, and the
project expects a local Mudmouth checkout beside Interceptor:

The QuantumLeap package is private. Your GitHub account must have read access;
configure Xcode's GitHub account or a local Git credential before resolving it.

```text
development-directory/
  Interceptor/
  Mudmouth/
```

From the Interceptor directory, clone Mudmouth if it does not already exist:

```bash
git clone https://github.com/qtmleap/Mudmouth.git ../Mudmouth
git -C ../Mudmouth checkout 3c1468aaaea5140835982bc8e38c9d3bfc49d2a0
xcodebuild -resolvePackageDependencies -project Interceptor.xcodeproj -scheme Interceptor
open Interceptor.xcodeproj
```

The revision above is the Mudmouth revision selected for the local setup on
2026-10-06 and matches CI. It removes the unused Introspect 1.x dependency so
QuantumLeap 1.0.1 can resolve Introspect 27.x. Keep the checkout on its development branch when editing Mudmouth;
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

CI requires the repository secret `QUANTUMLEAP_READ_TOKEN`, a GitHub token with
read access to `qtmleap/QuantumLeap`. For a dedicated CI credential, prefer a
fine-grained token limited to that repository with **Contents: read-only**.
Fork pull requests cannot access this secret; the self-hosted simulator job
is skipped for them. A maintainer must review and run the changes on a trusted
repository branch. Deploy keys are disabled for QuantumLeap.

CI uses one signed `xcodebuild test` invocation, which builds the app and test
targets for its selected simulator and runs the full suite. This avoids a
separate unsigned build of both simulator architectures. Build/test output and
periodic process samples are saved to help diagnose waits. Automatic simulator
sysdiagnose collection is disabled (`-collect-test-diagnostics never`) to avoid
the hosted Simulator's post-test collection hang; normal test results and
screenshots remain in the result bundle.

The simulator and TestFlight jobs use `[self-hosted, macOS, ARM64, macos-27]`; the
`self-hosted` label prevents routing them to GitHub-hosted runners. The
Mac Studio supervisor starts its Xcode 27 VM profile when jobs are queued.
Local validation and the VM's selected Xcode/runtime are recorded separately
in their build logs. Release configuration checks remain on `ubuntu-latest`.

## Contributors

- [zhxie](https://github.com/zhxie)
- [ultemica](https://github.com/ultemica)

## License

Interceptor is licensed under [the MIT License](/LICENSE).
