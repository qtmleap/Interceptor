## Interceptor

### Automatic TestFlight deployment

Pushes to `develop` (including merged pull requests) run the simulator and release
automation checks. If both succeed, the same commit is archived and uploaded to
TestFlight. Pull requests and `master` pushes run checks only. App Store submission
and external beta review are separate release actions.

Deployments are serialized with GitHub Actions `queue: max`; up to 100 pending
deployments can wait without replacing earlier pending runs. Build numbers start
after the maximum of the project number, the latest TestFlight number for the
marketing version, and the previously uploaded build 31. The job waits for Apple
to finish processing before releasing the deployment queue. A failed processing
step must be investigated before retrying; the upload may already exist on Apple.

Configure these repository secrets (or secrets in the `testflight` environment):

| Secret | Purpose |
| --- | --- |
| `QUANTUMLEAP_READ_TOKEN` | Read the private QuantumLeap Swift package; already used by simulator CI. |
| `APP_STORE_CONNECT_API_KEY_KEY_ID` | App Store Connect API key ID. |
| `APP_STORE_CONNECT_API_KEY_ISSUER_ID` | App Store Connect API issuer ID. |
| `APP_STORE_CONNECT_API_KEY_KEY` | Base64-encoded contents of the API key's `.p8` file. |
| `MATCH_PASSWORD` | Password for encrypted signing assets in `qtmleap/match`. |
| `MATCH_GIT_BASIC_AUTHORIZATION` | Base64-encoded `github-user:read-token`, with access to `qtmleap/match`. |

Use an App Manager API key with access to Interceptor. The upload uses the official
App Store Connect API and does not require an Apple ID browser session or 2FA.
Keep keys, passwords, and tokens outside this repository. Register secrets through
GitHub's secret settings or `gh secret set` using file/stdin input.

The signing repository must contain a valid App Store distribution certificate
and private key, plus App Store profiles for `jp.qleap.intrcptr` and
`jp.qleap.intrcptr.packet-tunnel` with the app's required entitlements. The lane
reads existing assets only; it does not create certificates or profiles.

Build and deployment use `[self-hosted, macos-latest]` in the organization's
`Mac Studio` runner group. Its on-demand macOS 27 profile provides Xcode 27
and Homebrew in a fresh Tart VM for each job, deleted after the job finishes.
The runner group must allow this repository, including public repositories.
The deployment job selects
Homebrew Ruby 3.3 and installs the checked-in Gemfile.lock with Bundler 2.6.9.
Use a dedicated macOS runner account: signing temporarily changes its keychain
search list and `.netrc`. Both are restored by the release wrapper, including on
failure. Its private working directory contains the temporary signing keychain,
Transporter key files, archive output, and package checkouts and is removed on exit.
Other signing jobs must not use that account concurrently. For automatic delivery,
the `testflight` environment must allow `develop` deployments without a required
manual reviewer. Protect `develop` so changes enter through reviewed pull requests.

Validate the release automation locally without Apple credentials:

```sh
ruby fastlane/test/testflight_config_test.rb
python3 -m unittest discover -s scripts/tests -v
bash -n scripts/ci-testflight.sh
```

The actual upload is performed by `bash scripts/ci-testflight.sh`, with the same
credentials supplied via environment variables. This command uploads a build;
the checks above do not contact Apple.

This is an iOS application that uses a self-signed certificate to obtain an access token from Nintendo Switch Online.

### Requirements

- iOS 17 or later
- Xcode 27 with Swift 6.4 or later (required by QuantumLeap 1.0.0)
- fastlane

The simulator build was verified with Xcode 27.0 on 2026-10-04 using
`swift-crypto` 3.15.1 and Runestone 0.5.2. Keep the checked-in `Package.resolved`
to use these compatible dependency versions.

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
QuantumLeap 1.0.0 can resolve Introspect 27.x. Keep the checkout on its development branch when editing Mudmouth;
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

The simulator and TestFlight jobs use `[self-hosted, macos-latest]`; the
`self-hosted` label prevents routing them to GitHub-hosted runners. The
Mac Studio supervisor starts its Xcode 27 VM profile when jobs are queued.
Local validation and the VM's selected Xcode/runtime are recorded separately
in their build logs. Release configuration checks remain on `ubuntu-latest`.

## Contributors

- [zhxie](https://github.com/zhxie)
- [ultemica](https://github.com/ultemica)

## License

Interceptor is licensed under [the MIT License](/LICENSE).
